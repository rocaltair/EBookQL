//
//  ComicArchive.swift
//  EBookQLKit
//
//  The container a comic archive puts its pages in: CBZ is a ZIP, CBT is a TAR. Both are
//  uncompressed page lists to the reader, and the one format question the rest of the code
//  does not want to ask is which of the two it is looking at - so it is asked exactly here,
//  and answered from the file's own bytes rather than from its extension. A `.cbt` holding a
//  ZIP and a `.cbz` holding a TAR are both real, and both then read correctly.
//
//  Only a prefix of an entry is ever read for a page's image header, so a 400 MB comic costs
//  its directory and whatever it shows.
//

import Foundation
import ZIPFoundation

protocol ComicArchive: AnyObject {
    /// Every regular file, with the uncompressed size, in the archive's own order.
    var entries: [(path: String, size: Int)] { get }
    /// One entry whole - what the page images themselves are read with.
    func data(of path: String) -> Data?
    /// The first `limit` bytes of an entry, which is all an image header needs.
    func prefix(of path: String, limit: Int) -> Data?
}

enum ComicArchiveFactory {

    /// Opens whichever container the bytes say this is. A RAR (`.cbr`) is recognised on
    /// purpose: it is the one comic container this preview does not read, and saying so beats
    /// claiming the file is damaged.
    static func open(_ url: URL) throws -> ComicArchive {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 512),
              head.count >= 8 else { throw CBZParseError.notAnArchive }
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4b, 0x05, 0x06]) {
            guard let zip = try? ZIPComicArchive(url: url) else { throw CBZParseError.notAnArchive }
            return zip
        }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21]) { throw CBZParseError.rarArchive }
        if bytes.count >= 512, TarComicArchive.looksLikeTar(bytes) {
            return TarComicArchive(url: url, firstBlock: Data(bytes))
        }
        throw CBZParseError.notAnArchive
    }
}

/// A ZIP, read through ZIPFoundation - the container EPUB and CBZ already shared.
final class ZIPComicArchive: ComicArchive {

    private let archive: Archive
    private var byPath: [String: Entry] = [:]

    var entries: [(path: String, size: Int)] {
        byPath.values.map { ($0.path, Int($0.uncompressedSize)) }
    }

    init(url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.type == .file {
            byPath[entry.path] = entry
        }
    }

    func data(of path: String) -> Data? {
        guard let entry = byPath[path] else { return nil }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        guard (try? archive.extract(entry) { data.append($0) }) != nil else { return nil }
        return data
    }

    func prefix(of path: String, limit: Int) -> Data? {
        guard limit > 0, let entry = byPath[path] else { return nil }
        struct Enough: Error {}
        var data = Data()
        data.reserveCapacity(min(limit, 256 * 1024))
        do {
            try archive.extract(entry, bufferSize: 32 * 1024, skipCRC32: true) { chunk in
                data.append(chunk)
                if data.count >= limit { throw Enough() }
            }
        } catch is Enough {
            return data
        } catch {
            return nil
        }
        return data
    }
}

/// A TAR, read here. The format is a sequence of 512-byte blocks: a header naming a file and
/// its length, then the file's bytes padded out to a whole number of blocks. There is no
/// compression and no index, so the directory is the walk itself.
///
/// Long names come two ways and both are handled: the GNU `L` header, whose own payload is the
/// name of the *next* entry, and the POSIX pax `x` header, whose payload holds `path=…` lines.
final class TarComicArchive: ComicArchive {

    /// Offsets and sizes, so page bytes are read on demand: `path -> (offset, size)`.
    private let index: [(path: String, offset: Int, size: Int)]
    private let url: URL
    private var handle: FileHandle?

    var entries: [(path: String, size: Int)] {
        index.map { ($0.path, $0.size) }
    }

    init(url: URL, firstBlock: Data) {
        self.url = url
        var found: [(path: String, offset: Int, size: Int)] = []
        var offset = 0
        var pendingName: String?
        var pendingPax: String?
        // The caller has already read the first block; re-read it from the file so this walk
        // has one source of truth. `firstBlock` exists so the sniffing is not done twice.
        _ = firstBlock
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            index = []
            return
        }
        var zeroBlocks = 0
        while true {
            guard let block = try? handle.read(upToCount: 512), block.count == 512 else { break }
            let header = [UInt8](block)
            if header.allSatisfy({ $0 == 0 }) {
                // Two zero blocks end a tar; one is tolerated (some writers pad only once).
                zeroBlocks += 1
                if zeroBlocks >= 2 { break }
                offset += 512
                continue
            }
            zeroBlocks = 0
            let type = header[156]
            let size = Self.size(header)
            let body = offset + 512
            switch type {
            case 0x4c:                                  // 'L': the name of the next entry
                pendingName = Self.string(from: (try? handle.read(upToCount: size)) ?? nil)
            case 0x78, 0x58:                            // 'x'/'X': pax extended header
                let payload = Self.string(from: (try? handle.read(upToCount: size)) ?? nil)
                pendingPax = payload?.split(separator: "\n")
                    .first { $0.hasPrefix("path=") }
                    .map { String($0.dropFirst(5)) }
            case 0x30, 0x00, 0x37:                      // '0' / '\0' / '7': a regular file
                let name = pendingPax ?? pendingName ?? Self.string(header[0..<100] )
                if !name.isEmpty {
                    found.append((path: name, offset: body, size: size))
                }
                pendingName = nil
                pendingPax = nil
            default:
                // Directories, links and other extensions: skipped, but their names are not
                // carried into the entry that follows them.
                if type != 0x35 { pendingName = nil; pendingPax = nil }
            }
            let padded = (size + 511) / 512 * 512
            offset = body + padded
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { break }
        }
        index = found
    }

    /// A tar header has no magic in its oldest form, so the field that makes it a header is
    /// the checksum at 148: the sum of all 512 bytes with that field read as spaces.
    static func looksLikeTar(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 512 else { return false }
        let magic = String(decoding: bytes[257..<262], as: UTF8.self)
        if magic == "ustar" { return true }
        guard let stored = number(bytes[148..<156]) else { return false }
        var sum = 0
        for (index, byte) in bytes[0..<512].enumerated() {
            sum += (148..<156).contains(index) ? 32 : Int(byte)
        }
        return sum == stored
    }

    func data(of path: String) -> Data? {
        guard let entry = index.first(where: { $0.path == path }), entry.size >= 0,
              let handle = fileHandle() else { return nil }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil else { return nil }
        return try? handle.read(upToCount: entry.size) ?? Data()
    }

    func prefix(of path: String, limit: Int) -> Data? {
        guard limit > 0, let entry = index.first(where: { $0.path == path }),
              let handle = fileHandle() else { return nil }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil else { return nil }
        return try? handle.read(upToCount: min(limit, entry.size)) ?? Data()
    }

    private func fileHandle() -> FileHandle? {
        if let handle { return handle }
        let opened = try? FileHandle(forReadingFrom: url)
        handle = opened
        return opened
    }

    private static func string(from data: Data?) -> String? {
        guard let data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func string(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A tar number is octal in ASCII, padded with spaces or NULs - except when the top bit of
    /// the first byte is set, which is the base-256 form GNU tar uses for large sizes.
    private static func size(_ header: [UInt8]) -> Int { number(header[124..<136]) ?? 0 }

    private static func number(_ field: ArraySlice<UInt8>) -> Int? {
        let bytes = Array(field)
        if let first = bytes.first, first & 0x80 != 0 {
            var value = Int(first & 0x7f)
            for byte in bytes.dropFirst() { value = value << 8 | Int(byte) }
            return value
        }
        let text = String(decoding: bytes.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Int(text, radix: 8)
    }
}
