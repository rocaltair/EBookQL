//
//  CHMLZX.swift
//  EBookQLKit
//
//  LZX decompression for a CHM's compressed (MSCompressed) section.
//
//  Ported to Swift from the published format and from reference decoders:
//
//    * `lzxd` (Rust) by Lonami Exo - MIT OR Apache-2.0 - the 16-bit word bit order,
//      the canonical-Huffman decode table, the pretree path-length deltas, the
//      verbatim/aligned/uncompressed block bodies and the R0/R1/R2 LRU queue;
//    * Apache Tika's `org.apache.tika.parser.microsoft.chm` - Apache-2.0 - and
//      libmspack's `lzxd.c`/`chmd.c` for the CHM framing: LZXC window/reset units,
//      the reset table, and the per-frame E8 translation.
//
//  Frame model (this is what makes CHM decoding cheap): a *frame* is 0x8000 bytes
//  of decompressed output. The compressor restarts the Huffman state and re-sends
//  the E8 ("Intel call") header at every frame whose index is a multiple of
//  `resetInterval` frames. The reset table stores one compressed offset per frame,
//  so a decoder can start at the nearest reset boundary and decode only the frames
//  around the file it needs - no full decompression, no scratch files.
//
//  Two alignment rules, and they are not the same one:
//    * at the end of a frame: drop the leftover bits of a partially read word;
//    * before an uncompressed block's raw bytes: if the current word is exhausted,
//      consume the next word (Microsoft's writers pad to a word there).
//

import Foundation

public enum CHMError: Error {
    case notCHM
    case truncated
    case corrupt(String)
}

// MARK: - Bitstream

/// LZX's bit order: a stream of aligned little-endian 16-bit words, bits taken
/// most-significant first inside each word. `word` is rotated left as bits are
/// consumed, so the unread bits stay at the top.
struct LZXBitstream {
    private let data: [UInt8]
    private var pos: Int
    private var word: UInt16 = 0
    private var bitsLeft: Int = 0

    init(_ data: [UInt8], from offset: Int) {
        self.data = data
        self.pos = offset
    }

    private static func rotl(_ value: UInt16, _ bits: Int) -> UInt16 {
        guard bits > 0, bits < 16 else { return value }
        return (value << UInt16(bits)) | (value >> UInt16(16 - bits))
    }

    private mutating func advance() throws {
        guard pos + 2 <= data.count else { throw CHMError.truncated }
        word = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
        pos += 2
        bitsLeft = 16
    }

    mutating func readBit() throws -> Int {
        if bitsLeft == 0 { try advance() }
        bitsLeft -= 1
        word = Self.rotl(word, 1)
        return Int(word & 1)
    }

    mutating func readBits(_ bits: Int) throws -> UInt32 {
        guard bits > 0 else { return 0 }
        if bits <= 16 {
            if bits <= bitsLeft {
                bitsLeft -= bits
                word = Self.rotl(word, bits)
                return UInt32(word) & ((UInt32(1) << UInt32(bits)) - 1)
            }
            let hi = UInt32(Self.rotl(word, bitsLeft) & ((1 << UInt16(bitsLeft)) - 1))
            let rest = bits - bitsLeft
            try advance()
            bitsLeft -= rest
            word = Self.rotl(word, rest)
            let lo = UInt32(word) & ((UInt32(1) << UInt32(rest)) - 1)
            return (hi << UInt32(rest)) | lo
        }
        let high = try readBits(16)
        let low = try readBits(bits - 16)
        return (high << UInt32(bits - 16)) | low
    }

    mutating func peekBits(_ bits: Int) throws -> UInt32 {
        if bits <= 16 {
            if bits <= bitsLeft {
                return UInt32(Self.rotl(word, bits)) & ((UInt32(1) << UInt32(bits)) - 1)
            }
            let hi = UInt32(Self.rotl(word, bitsLeft) & ((1 << UInt16(bitsLeft)) - 1))
            let rest = bits - bitsLeft
            // Peeking may look one word past the end of the data; zeros are fine.
            let next: UInt16 = pos + 2 <= data.count
                ? UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
                : 0
            let lo = UInt32(Self.rotl(next, rest)) & ((UInt32(1) << UInt32(rest)) - 1)
            return (hi << UInt32(rest)) | lo
        }
        var copy = self
        let high = try copy.readBits(16)
        let low = try copy.peekBits(bits - 16)
        return (high << UInt32(bits - 16)) | low
    }

    /// Before an uncompressed block's raw bytes: a partially read word loses its
    /// leftovers; an exhausted word means the next word is padding and is consumed.
    mutating func alignForRawBytes() throws {
        if bitsLeft == 0 {
            _ = try readBits(16)
        } else {
            bitsLeft = 0
        }
    }

    /// At a frame boundary: only a partially read word is dropped. An exhausted word
    /// is left alone - the next word is real data, not padding.
    mutating func alignForFrameEnd() {
        bitsLeft = 0
    }

    /// Raw bytes, ignoring bit alignment (used by uncompressed block bodies, which
    /// always follow `alignForRawBytes`).
    mutating func readRaw(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw CHMError.corrupt("negative raw read") }
        guard pos + count <= data.count else { throw CHMError.truncated }
        let out = Array(data[pos..<(pos + count)])
        pos += count
        return out
    }

    /// An uncompressed block of odd length leaves the stream one byte off the word
    /// grid; the writer pads it, so skip that byte before the next block header.
    mutating func skipPaddingByte() throws {
        guard bitsLeft == 0, pos < data.count else { throw CHMError.corrupt("lzx padding byte") }
        pos += 1
    }

    var bytesRemaining: Int { data.count - pos }

    /// A little-endian u32 read as two words (the uncompressed block's R0/R1/R2).
    mutating func readUInt32LE() throws -> UInt32 {
        let low = try readBits(16)
        let high = try readBits(16)
        return low | (high << 16)
    }

    /// A 24-bit big-endian value: 16 bits, then 8 (the block size).
    mutating func readUInt24BE() throws -> UInt32 {
        let high = try readBits(16)
        let low = try readBits(8)
        return (high << 8) | low
    }
}

// MARK: - Huffman trees

/// A canonical Huffman tree held as the path lengths it can be rebuilt from: LZX
/// sends tree definitions as deltas against the previous tree, so the lengths must
/// outlive a single block.
struct LZXCanonicalTree {
    var pathLengths: [UInt8]

    init(count: Int) { pathLengths = [UInt8](repeating: 0, count: count) }

    /// Reads the path lengths of `range` through the pretree that precedes them:
    /// 20 four-bit pretree lengths, then elements coded as (previous - value) mod 17,
    /// with 17/18 as zero runs and 19 as a same-value run.
    mutating func update(range: Range<Int>, from bits: inout LZXBitstream) throws {
        var pretreeLengths = [UInt8]()
        pretreeLengths.reserveCapacity(20)
        for _ in 0..<20 { pretreeLengths.append(UInt8(try bits.readBits(4))) }
        guard let pretree = try LZXTree(pathLengths: pretreeLengths) else {
            throw CHMError.corrupt("empty lzx pretree")
        }

        var index = range.lowerBound
        while index < range.upperBound {
            let code = try pretree.decode(&bits)
            switch code {
            case 0...16:
                pathLengths[index] = UInt8((17 + Int(pathLengths[index]) - code) % 17)
                index += 1
            case 17:
                let run = Int(try bits.readBits(4)) + 4
                try fill(index, count: run, with: 0, limit: range.upperBound)
                index += run
            case 18:
                let run = Int(try bits.readBits(5)) + 20
                try fill(index, count: run, with: 0, limit: range.upperBound)
                index += run
            case 19:
                let run = Int(try bits.readBits(1)) + 4
                let delta = try pretree.decode(&bits)
                guard delta <= 16 else { throw CHMError.corrupt("lzx pretree element \(delta)") }
                let value = UInt8((17 + Int(pathLengths[index]) - delta) % 17)
                try fill(index, count: run, with: value, limit: range.upperBound)
                index += run
            default:
                throw CHMError.corrupt("lzx pretree element \(code)")
            }
        }
    }

    private mutating func fill(_ start: Int, count: Int, with value: UInt8, limit: Int) throws {
        guard start >= 0, count >= 0, start + count <= limit else {
            throw CHMError.corrupt("lzx path-length run out of range")
        }
        for index in start..<(start + count) { pathLengths[index] = value }
    }

    /// The decodable form, or nil when every path length is zero (an allowed, empty
    /// tree - the length tree of a block with no long matches is one).
    func makeTree() throws -> LZXTree? {
        try LZXTree(pathLengths: pathLengths)
    }
}

/// A decodable canonical Huffman tree: a flat table indexed by the next
/// `largestLength` bits, plus the path lengths needed to know how many bits the
/// decoded element actually consumed.
struct LZXTree {
    let pathLengths: [UInt8]
    let largestLength: Int
    let table: [UInt16]

    init?(pathLengths: [UInt8]) throws {
        guard let largest = pathLengths.max(), largest > 0 else { return nil }
        let size = 1 << Int(largest)
        var table = [UInt16](repeating: 0, count: size)
        var position = 0
        for length in 1...Int(largest) {
            let run = 1 << (Int(largest) - length)
            for code in 0..<pathLengths.count where pathLengths[code] == UInt8(length) {
                guard position + run <= size else { throw CHMError.corrupt("lzx path lengths") }
                for index in position..<(position + run) { table[index] = UInt16(code) }
                position += run
            }
        }
        guard position == size else { throw CHMError.corrupt("lzx path lengths") }
        self.pathLengths = pathLengths
        self.largestLength = Int(largest)
        self.table = table
    }

    func decode(_ bits: inout LZXBitstream) throws -> Int {
        let code = Int(table[Int(try bits.peekBits(largestLength))])
        _ = try bits.readBits(Int(pathLengths[code]))
        return code
    }
}

// MARK: - Decoder

/// LZX state for one MSCompressed section, driven frame by frame.
final class LZXDecoder {

    static let frameSize = 0x8000
    private static let numSecondaryLengths = 249

    /// Extra bits by position slot, and the offset each slot starts from. Standard
    /// LZX tables (`lzxd` carries the same two, as `FOOTER_BITS`/`BASE_POSITION`).
    private static let footerBits: [UInt8] = {
        // Slots 0-3 need no extra bits (they are the repeated offsets and the first
        // real ones), slots 4-35 take 1,1,2,2,...16,16 bits, and every slot from 36
        // up takes 17. Losing the four leading zeros is a silent disaster: the table
        // is only ever used through basePosition, which then starts 131072 too high.
        var table = [UInt8](repeating: 17, count: 290)
        table[0] = 0
        table[1] = 0
        table[2] = 0
        table[3] = 0
        var index = 4
        for extra in 1...16 {
            table[index] = UInt8(extra)
            table[index + 1] = UInt8(extra)
            index += 2
        }
        return table
    }()

    private static let basePosition: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 290)
        for slot in 1..<290 {
            let bits = Int(footerBits[slot - 1])
            table[slot] = table[slot - 1] + (bits == 0 ? 1 : (UInt32(1) << UInt32(bits)))
        }
        return table
    }()

    /// Position slots per window size, from the LZX specification.
    static func positionSlots(windowBits: Int) -> Int {
        switch windowBits {
        case 15: return 30
        case 16: return 32
        case 17: return 34
        case 18: return 36
        case 19: return 38
        case 20: return 42
        default: return 50
        }
    }

    private let windowSize: Int
    private let windowMask: Int
    private let resetInterval: Int          // in frames; 0 = never
    private let totalLength: Int            // decompressed length of the whole stream
    private var frameIndex: Int             // GLOBAL frame number, not per-call
    private var window: [UInt8]
    private var windowPos = 0
    private var mainTree: LZXCanonicalTree
    private var lengthTree: LZXCanonicalTree
    private var alignedTree: LZXTree?
    private var mainDecode: LZXTree?
    private var lengthDecode: LZXTree?
    private var r: [UInt32] = [1, 1, 1]
    private var blockType = -1
    private var blockSize = 0
    private var blockRemaining = 0
    private var intelFilesize: UInt32 = 0
    private var intelStarted = false
    private var headerRead = false

    /// `startFrame` is the frame number the source offset corresponds to: frames are
    /// numbered from the beginning of the decompressed stream, and the last one is
    /// short (the stream's length is not a multiple of the frame size), so the
    /// decoder has to know where in the stream it is.
    init(windowBits: Int, resetInterval: Int, totalLength: Int, startFrame: Int = 0) {
        windowSize = 1 << windowBits
        windowMask = windowSize - 1
        self.resetInterval = max(0, resetInterval)
        self.totalLength = totalLength
        self.frameIndex = startFrame
        window = [UInt8](repeating: 0, count: windowSize)
        mainTree = LZXCanonicalTree(count: 256 + 8 * Self.positionSlots(windowBits: windowBits))
        lengthTree = LZXCanonicalTree(count: Self.numSecondaryLengths)
    }

    /// Decodes `count` bytes of decompressed output starting at frame `frame`. The
    /// caller must pass a reset-boundary frame (a multiple of the reset interval),
    /// which is what the reset table's addresses are good for; the returned bytes
    /// start at that frame's first byte and the caller drops the leading part it
    /// does not want. Whole frames are decoded even when `count` ends mid-frame, so
    /// the frame-boundary alignment rules stay valid.
    func decode(_ source: [UInt8], from sourceOffset: Int, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bits = LZXBitstream(source, from: sourceOffset)
        var output = [UInt8]()
        output.reserveCapacity(count + Self.frameSize)

        var produced = 0
        var framesDecoded = 0
        while produced < count {
            if resetInterval == 0 || frameIndex % resetInterval == 0 {
                resetState(&bits)
            }
            // The stream's last frame is short: its length is whatever is left.
            let remaining = totalLength - frameIndex * Self.frameSize
            guard remaining > 0 else { break }
            let frame = try decodeFrame(&bits, size: min(Self.frameSize, remaining))
            let want = min(frame.count, count - produced)
            output.append(contentsOf: frame[0..<want])
            produced += want
            frameIndex += 1
            framesDecoded += 1
            if framesDecoded > 8192 { throw CHMError.corrupt("lzx frame runaway") }
        }
        return output
    }

    // MARK: State

    private func resetState(_ bits: inout LZXBitstream) {
        for index in 0..<mainTree.pathLengths.count { mainTree.pathLengths[index] = 0 }
        for index in 0..<lengthTree.pathLengths.count { lengthTree.pathLengths[index] = 0 }
        mainDecode = nil
        lengthDecode = nil
        alignedTree = nil
        r = [1, 1, 1]
        blockType = -1
        blockSize = 0
        blockRemaining = 0
        intelStarted = false
        intelFilesize = 0
        headerRead = false
    }

    /// The E8 header: one presence bit, then a 32-bit translation size when set.
    private func readIntelHeader(_ bits: inout LZXBitstream) throws {
        intelStarted = false
        intelFilesize = 0
        if try bits.readBit() != 0 {
            intelFilesize = try bits.readBits(32)
        }
        headerRead = true
    }

    private func readBlock(_ bits: inout LZXBitstream) throws {
        if blockType == 3 && blockSize % 2 != 0 { try bits.skipPaddingByte() }
        let type = Int(try bits.readBits(3))
        let size = Int(try bits.readUInt24BE())
        guard size > 0 else { throw CHMError.corrupt("lzx block size 0") }
        blockType = type
        blockSize = size
        blockRemaining = size

        switch type {
        case 1, 2:
            if type == 2 {
                var lengths = [UInt8]()
                lengths.reserveCapacity(8)
                for _ in 0..<8 { lengths.append(UInt8(try bits.readBits(3))) }
                alignedTree = try LZXTree(pathLengths: lengths)
            }
            try mainTree.update(range: 0..<256, from: &bits)
            try mainTree.update(range: 256..<mainTree.pathLengths.count, from: &bits)
            try lengthTree.update(range: 0..<Self.numSecondaryLengths, from: &bits)
            mainDecode = try mainTree.makeTree()
            lengthDecode = try lengthTree.makeTree()
            // A literal 0xE8 anywhere in the block means E8 translation may apply.
            if mainTree.pathLengths[0xE8] != 0 { intelStarted = true }
        case 3:
            try bits.alignForRawBytes()
            r = [try bits.readUInt32LE(), try bits.readUInt32LE(), try bits.readUInt32LE()]
            intelStarted = true
        default:
            throw CHMError.corrupt("lzx block type \(type)")
        }
    }

    // MARK: One frame

    private func decodeFrame(_ bits: inout LZXBitstream, size: Int) throws -> [UInt8] {
        if !headerRead { try readIntelHeader(&bits) }

        let frameStart = windowPos
        var written = 0
        while written < size {
            if blockRemaining == 0 { try readBlock(&bits) }
            let budget = min(blockRemaining, size - written)
            let produced = try decodeElements(&bits, budget: budget)
            guard produced >= budget else { throw CHMError.corrupt("lzx block underran its budget") }
            // A match may overshoot the budget; the overshoot belongs to both the
            // block and the frame (libmspack accounts for it the same way) and a
            // match that runs past the frame end is a corrupt stream.
            blockRemaining -= min(produced, blockRemaining)
            written += produced
            // A match may run past the frame's end by a few bytes; the extra bytes are
            // still correct stream output (they stay in the window) and the caller only
            // ever wants a slice, so tolerating it beats failing the whole read.
        }

        var frame = readWindow(from: frameStart, count: size)
        bits.alignForFrameEnd()
        if intelStarted, intelFilesize != 0 {
            let offset = UInt32(truncatingIfNeeded: frameIndex * Self.frameSize)
            Self.translateE8(&frame, filesize: intelFilesize, outputOffset: offset)
        }
        return frame
    }

    /// Decodes at least `budget` bytes, letting the final match overshoot - a match
    /// is never cut in half.
    private func decodeElements(_ bits: inout LZXBitstream, budget: Int) throws -> Int {
        if blockType == 3 {
            let raw = try bits.readRaw(budget)
            for byte in raw { push(byte) }
            return raw.count
        }
        guard let main = mainDecode else { throw CHMError.corrupt("lzx block without a main tree") }

        var written = 0
        while written < budget {
            let element = try main.decode(&bits)
            if element < 256 {
                push(UInt8(element))
                written += 1
                continue
            }

            var length = element & 7
            if length == 7 {
                guard let lengths = lengthDecode else { throw CHMError.corrupt("lzx missing length tree") }
                length += try lengths.decode(&bits)
            }
            length += 2

            let slot = (element - 256) >> 3
            let offset: Int
            if slot == 0 {
                offset = Int(r[0])
            } else if slot == 1 {
                offset = Int(r[1])
                r[1] = r[0]
                r[0] = UInt32(offset)
            } else if slot == 2 {
                offset = Int(r[2])
                r[2] = r[0]
                r[0] = UInt32(offset)
            } else {
                let extra = Int(Self.footerBits[slot])
                var formatted = Self.basePosition[slot]
                if let aligned = alignedTree {
                    if extra >= 3 {
                        formatted += try bits.readBits(extra - 3) << 3
                        formatted += UInt32(try aligned.decode(&bits))
                    } else {
                        formatted += try bits.readBits(extra)
                    }
                } else {
                    formatted += try bits.readBits(extra)
                }
                offset = Int(formatted) - 2
                r[2] = r[1]
                r[1] = r[0]
                r[0] = UInt32(bitPattern: Int32(offset))
            }

            guard offset > 0, offset <= windowSize else {
                throw CHMError.corrupt("lzx match offset \(offset)")
            }
            for _ in 0..<length { push(window[(windowPos - offset) & windowMask]) }
            written += length
        }
        return written
    }

    /// E8 ("Intel call") translation, ported from libmspack: a 0xE8 byte followed by
    /// a 32-bit absolute address is rewritten as a relative one, and never within 10
    /// bytes of the end of a frame.
    private static func translateE8(_ frame: inout [UInt8], filesize: UInt32, outputOffset: UInt32) {
        guard frame.count > 10 else { return }
        var position = 0
        var current = Int32(bitPattern: outputOffset)
        let size = Int32(bitPattern: filesize)
        while position < frame.count - 10 {
            if frame[position] != 0xE8 { position += 1; current += 1; continue }
            let absolute = Int32(bitPattern: UInt32(frame[position + 1])
                | (UInt32(frame[position + 2]) << 8)
                | (UInt32(frame[position + 3]) << 16)
                | (UInt32(frame[position + 4]) << 24))
            if absolute >= -current && absolute < size {
                let relative = absolute >= 0 ? absolute - current : absolute + size
                let value = UInt32(bitPattern: relative)
                frame[position + 1] = UInt8(value & 0xFF)
                frame[position + 2] = UInt8((value >> 8) & 0xFF)
                frame[position + 3] = UInt8((value >> 16) & 0xFF)
                frame[position + 4] = UInt8((value >> 24) & 0xFF)
            }
            position += 5
            current += 5
        }
    }

    private func push(_ byte: UInt8) {
        window[windowPos] = byte
        windowPos = (windowPos + 1) & windowMask
    }

    /// The window is a ring buffer, so a frame can straddle its end.
    private func readWindow(from start: Int, count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        for index in 0..<count { out.append(window[(start + index) & windowMask]) }
        return out
    }
}
