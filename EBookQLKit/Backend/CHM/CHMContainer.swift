//
//  CHMContainer.swift
//  EBookQLKit
//
//  The ITSF container: the directory that lists a .chm's files, the two sections a
//  file can live in (an uncompressed one read straight out of the file, and the
//  LZX-compressed one), and the metadata Microsoft's compiler leaves behind.
//
//  Layout, all verified against real files and cross-checked with 7-Zip's CHM
//  reader (`7zz l` / `7zz x`):
//
//      [ITSF header 0x60] [ITSP directory: header 0x54 + N x block] [sections]
//
//  The section order varies: `dataOffset` (0 for files whose uncompressed section
//  precedes the directory) is where the uncompressed section starts, and a file in
//  that section is `dataOffset + start`. A file in the compressed section has
//  `start` as an offset into the *decompressed* stream, which the reset table maps
//  back onto compressed bytes.
//
//  Directory entries are the one detail that trips a first implementation: the
//  fields are 7-bit continuation integers ("compressed words"), not fixed widths -
//  see `compressedWord`.
//

import Foundation

/// One file inside a .chm.
public struct CHMEntry {
    public let path: String        // leading "/", as the directory stores it
    public let space: Int          // 0 = uncompressed section, 1 = MSCompressed
    public let start: Int
    public let length: Int
}

/// The metadata CHM's compiler writes into `/#SYSTEM`.
public struct CHMSystemInfo {
    public var title: String?
    public var defaultTopic: String?
    public var contentsFile: String?
    public var indexFile: String?
    public var compiler: String?
}

public final class CHMContainer {

    public let entries: [CHMEntry]
    private let bytes: [UInt8]
    private let dataOffset: Int
    private let byPath: [String: CHMEntry]
    private var compressed: CompressedSection?

    public static let extensions: Set<String> = ["chm"]

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(bytes: [UInt8](data))
    }

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count > 0x60, CHMContainer.magic(bytes, 0) == "ITSF" else { throw CHMError.notCHM }

        let version = CHMContainer.u32(bytes, 4)
        guard version == 2 || version == 3 else { throw CHMError.corrupt("ITSF version \(version)") }

        let dirOffset = CHMContainer.u64(bytes, 0x48)
        let dirLength = CHMContainer.u64(bytes, 0x50)
        // V3 stores it; V2's section starts right after the directory.
        dataOffset = version == 3 ? CHMContainer.u64(bytes, 0x58) : dirOffset + dirLength

        guard dirOffset + 0x54 <= bytes.count, CHMContainer.magic(bytes, dirOffset) == "ITSP" else {
            throw CHMError.corrupt("no ITSP directory")
        }
        let itspHeaderLength = Int(CHMContainer.u32(bytes, dirOffset + 0x08))
        let blockLength = Int(CHMContainer.u32(bytes, dirOffset + 0x10))
        let indexRoot = Int32(bitPattern: CHMContainer.u32(bytes, dirOffset + 0x1C))
        let indexHead = Int32(bitPattern: CHMContainer.u32(bytes, dirOffset + 0x20))
        let indexTail = Int32(bitPattern: CHMContainer.u32(bytes, dirOffset + 0x24))
        // No PMGI index chunk (a small archive): the first listing chunk is the root.
        _ = indexRoot
        guard blockLength > 0, indexHead >= 0, indexTail >= indexHead else {
            throw CHMError.corrupt("bad ITSP chunk range")
        }

        var found = [CHMEntry]()
        let chunkBase = dirOffset + itspHeaderLength
        for chunk in Int(indexHead)...Int(indexTail) {
            let offset = chunkBase + chunk * blockLength
            guard offset + 0x14 <= bytes.count, CHMContainer.magic(bytes, offset) == "PMGL" else { continue }
            let freeSpace = Int(CHMContainer.u32(bytes, offset + 0x04))
            let end = offset + blockLength - freeSpace
            var cursor = offset + 0x14
            while cursor < end, cursor < bytes.count {
                let nameLength = try CHMContainer.compressedWord(bytes, &cursor)
                guard nameLength > 0, cursor + nameLength <= bytes.count else { break }
                let name = String(decoding: bytes[cursor..<(cursor + nameLength)], as: UTF8.self)
                cursor += nameLength
                let space = try CHMContainer.compressedWord(bytes, &cursor)
                let start = try CHMContainer.compressedWord(bytes, &cursor)
                let length = try CHMContainer.compressedWord(bytes, &cursor)
                found.append(CHMEntry(path: name, space: space, start: start, length: length))
            }
        }
        entries = found
        var map = [String: CHMEntry]()
        for entry in found {
            let key = CHMContainer.canonicalPath(entry.path)
            if map[key] == nil { map[key] = entry }
        }
        byPath = map
    }

    /// Directory paths are stored inconsistently: most files carry a leading "/",
    /// while the container's own `::DataSpace/...` files do not.
    static func canonicalPath(_ path: String) -> String {
        path.hasPrefix("/") || path.hasPrefix("::") ? path : "/" + path
    }

    // MARK: - Lookup

    public func entry(_ path: String) -> CHMEntry? {
        byPath[CHMContainer.canonicalPath(path)]
    }

    public func entries(endingWith suffix: String) -> [CHMEntry] {
        entries.filter { $0.path.lowercased().hasSuffix(suffix) }
    }

    public var systemInfo: CHMSystemInfo? {
        guard let entry = entry("/#SYSTEM"), let raw = try? data(of: entry) else { return nil }
        var info = CHMSystemInfo()
        var cursor = 4
        while cursor + 4 <= raw.count {
            let code = Int(raw[cursor]) | (Int(raw[cursor + 1]) << 8)
            let length = Int(raw[cursor + 2]) | (Int(raw[cursor + 3]) << 8)
            cursor += 4
            guard cursor + length <= raw.count else { break }
            let value = raw[cursor..<(cursor + length)]
            cursor += length
            let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            switch code {
            case 2: info.defaultTopic = text
            case 3: info.title = text
            case 5: info.contentsFile = text
            case 6: info.indexFile = text
            case 9: info.compiler = text
            default: break
            }
        }
        return info
    }

    // MARK: - Reading a file

    public func data(of entry: CHMEntry) throws -> [UInt8] {
        if entry.space == 0 {
            let offset = dataOffset + entry.start
            guard offset >= 0, offset + entry.length <= bytes.count else { throw CHMError.truncated }
            return Array(bytes[offset..<(offset + entry.length)])
        }
        let section = try compressedSection()
        return try section.data(at: entry.start, length: entry.length)
    }

    // MARK: - The compressed section

    private func compressedSection() throws -> CompressedSection {
        if let compressed { return compressed }

        let controlPath = "::DataSpace/Storage/MSCompressed/ControlData"
        guard let controlEntry = entry(controlPath) else { throw CHMError.corrupt("no LZXC control data") }
        let control = try data(of: controlEntry)
        guard control.count >= 0x1C, CHMContainer.magic(control, 4) == "LZXC" else {
            throw CHMError.corrupt("bad LZXC signature")
        }
        let controlVersion = CHMContainer.u32(control, 8)
        let resetIntervalRaw = Int(CHMContainer.u32(control, 0x0C))
        let windowRaw = Int(CHMContainer.u32(control, 0x10))
        // Version 2 and later count in 0x8000-byte blocks; earlier ones are bytes.
        let unit = controlVersion >= 2 ? LZXDecoder.frameSize : 1
        let resetIntervalBytes = resetIntervalRaw * unit
        let windowBytes = windowRaw * unit

        let windowBits: Int
        switch windowBytes {
        case 0x008000: windowBits = 15
        case 0x010000: windowBits = 16
        case 0x020000: windowBits = 17
        case 0x040000: windowBits = 18
        case 0x080000: windowBits = 19
        case 0x100000: windowBits = 20
        case 0x200000: windowBits = 21
        default: throw CHMError.corrupt("LZXC window size \(windowBytes)")
        }

        guard let resetEntry = entries.last(where: { $0.path.hasSuffix("/InstanceData/ResetTable") }) else {
            throw CHMError.corrupt("no LZXC reset table")
        }
        let reset = try data(of: resetEntry)
        guard reset.count >= 0x28 else { throw CHMError.corrupt("short reset table") }
        let blockCount = Int(CHMContainer.u32(reset, 4))
        let entrySize = Int(CHMContainer.u32(reset, 8))
        let uncompressedLength = Int(CHMContainer.u64(reset, 0x10))
        let blockLength = Int(CHMContainer.u64(reset, 0x20))
        var addresses = [Int]()
        addresses.reserveCapacity(blockCount)
        var cursor = 0x28
        for _ in 0..<blockCount {
            guard cursor + entrySize <= reset.count else { break }
            addresses.append(entrySize >= 8 ? Int(CHMContainer.u64(reset, cursor))
                                            : Int(CHMContainer.u32(reset, cursor)))
            cursor += max(entrySize, 8)
        }

        guard let contentEntry = entry("::DataSpace/Storage/MSCompressed/Content") else {
            throw CHMError.corrupt("no compressed content")
        }
        let content = try data(of: contentEntry)

        let section = CompressedSection(content: content,
                                        addresses: addresses,
                                        blockLength: blockLength,
                                        uncompressedLength: uncompressedLength,
                                        windowBits: windowBits,
                                        resetIntervalBytes: max(resetIntervalBytes, LZXDecoder.frameSize))
        compressed = section
        return section
    }

    // MARK: - Byte helpers

    static func magic(_ bytes: [UInt8], _ offset: Int) -> String? {
        guard offset + 4 <= bytes.count else { return nil }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    static func u64(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(u32(bytes, offset)) | (Int(u32(bytes, offset + 4)) << 32)
    }

    /// chmlib calls this a "compressed word": 7 bits per byte, high bit set = more.
    static func compressedWord(_ bytes: [UInt8], _ cursor: inout Int) throws -> Int {
        var value = 0
        while cursor < bytes.count {
            let byte = Int(bytes[cursor])
            cursor += 1
            if byte >= 0x80 {
                value = (value << 7) + (byte & 0x7F)
            } else {
                return (value << 7) + byte
            }
        }
        throw CHMError.truncated
    }
}

/// The MSCompressed section: files are addressed by their offset in the
/// *decompressed* stream, and the reset table maps that onto the compressed bytes
/// so only the frames around the wanted file are ever decoded.
final class CompressedSection {

    private let content: [UInt8]
    private let addresses: [Int]
    private let blockLength: Int
    private let windowBits: Int
    private let framesPerReset: Int
    private let uncompressedLength: Int
    private var decoder: LZXDecoder
    private var cachedStartFrame = -1
    private var cachedBytes = [UInt8]()

    init(content: [UInt8], addresses: [Int], blockLength: Int, uncompressedLength: Int,
         windowBits: Int, resetIntervalBytes: Int) {
        self.content = content
        self.addresses = addresses
        self.blockLength = blockLength > 0 ? blockLength : LZXDecoder.frameSize
        self.windowBits = windowBits
        self.uncompressedLength = uncompressedLength
        let frames = max(1, resetIntervalBytes / LZXDecoder.frameSize)
        self.framesPerReset = frames
        self.decoder = LZXDecoder(windowBits: windowBits, resetInterval: frames,
                                  totalLength: uncompressedLength)
    }

    /// Reads `length` bytes of the decompressed stream starting at `offset`.
    func data(at offset: Int, length: Int) throws -> [UInt8] {
        guard length >= 0, offset >= 0 else { throw CHMError.corrupt("negative range") }
        if length == 0 { return [] }

        // Only frames on a reset boundary can be decoded on their own, so start there
        // and throw the leading bytes away (libmspack's rule in chmd.c). Whole frames
        // are decoded, so the frame-boundary alignment stays valid.
        let targetFrame = offset / blockLength
        let startFrame = (targetFrame / framesPerReset) * framesPerReset
        let skip = offset - startFrame * blockLength
        let needed = skip + length

        if cachedStartFrame != startFrame || cachedBytes.count < needed {
            guard startFrame >= 0, startFrame < addresses.count else {
                throw CHMError.corrupt("reset table too short")
            }
            guard offset + length <= uncompressedLength else { throw CHMError.truncated }
            decoder = LZXDecoder(windowBits: windowBits, resetInterval: framesPerReset,
                                 totalLength: uncompressedLength, startFrame: startFrame)
            cachedBytes = try decoder.decode(content, from: addresses[startFrame], count: needed)
            cachedStartFrame = startFrame
        }
        guard cachedBytes.count >= needed else { throw CHMError.truncated }
        return Array(cachedBytes[skip..<(skip + length)])
    }
}
