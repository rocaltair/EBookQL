//
//  DjVuBZZ.swift
//  EBookQLKit
//
//  The ZP arithmetic decoder and BZZ (BSByteStream) decompressor.
//
//  BZZ is the general-purpose compressor DjVu uses for exactly the parts of a
//  document that are text: `DIRM` (the multi-page directory, so page names and
//  titles), `NAVM` (the outline), `TXTz` (the hidden text layer) and `ANTz`
//  (annotations, which is where a DjVu keeps its metadata). All four are *always*
//  compressed - DjVuLibre's own writer does not offer an uncompressed form for
//  NAVM - so a reader that wants contents and page labels at all has to decode it.
//
//  BZZ is Burrows-Wheeler over a quasi-MTF code, driven by the ZP binary
//  arithmetic coder. Nothing here is compressed by us, so only the decode half is
//  implemented. Ported from the JavaScript decoder the preview already vendors
//  (DjVuAssets/), which was written against the published format: the ZP state
//  table is the format's own (DjVu spec App. 3, Table 9), BZZ is Appendix 4.
//

import Foundation

/// The ZP binary arithmetic decoder: adaptive, context-driven, one context byte
/// per modelled decision. Faithful to the reference algorithm, including its
/// `0xff` fill past the end of the data and the `delay` counter that gives up
/// after 25 invented bytes - a truncated stream fails instead of looping.
final class DjVuZPCoder {

    /// Number of leading 1-bits in each byte, the table the renormalisation shift
    /// is read from.
    private static let leadingOnes: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for value in 0..<256 {
            var bits = 0
            var shifted = value
            while shifted & 0x80 != 0 {
                bits += 1
                shifted = (shifted << 1) & 0xff
            }
            table[value] = UInt8(bits)
        }
        return table
    }()

    private let input: [UInt8]
    private var position = 0
    private var a = 0
    private var code = 0
    private var fence = 0
    private var buffer: UInt32 = 0
    private var scount = 0
    private var delay = 25

    /// Set when the stream ran out while still inventing fill bytes: the caller
    /// must stop and treat the data as damaged rather than use what it decoded.
    private(set) var failed = false

    init(_ input: [UInt8]) {
        self.input = input
        restart()
    }

    private func nextByte() -> Int {
        guard position < input.count else { return -1 }
        position += 1
        return Int(input[position - 1])
    }

    private func restart() {
        a = 0
        var byte = nextByte()
        code = (byte < 0 ? 0xff : byte) << 8
        byte = nextByte()
        code |= (byte < 0 ? 0xff : byte)
        delay = 25
        scount = 0
        buffer = 0
        preload()
        fence = code >= 0x8000 ? 0x7fff : code
    }

    private func preload() {
        while scount <= 24 {
            var byte = nextByte()
            if byte < 0 {
                byte = 0xff
                delay -= 1
                if delay < 1 {
                    failed = true
                    return
                }
            }
            buffer = (buffer << 8) | UInt32(byte)
            scount += 8
        }
    }

    /// Leading zero-bit count of a 16-bit interval size.
    private func shiftFor(_ value: Int) -> Int {
        value >= 0xff00
            ? Int(Self.leadingOnes[value & 0xff]) + 8
            : Int(Self.leadingOnes[(value >> 8) & 0xff])
    }

    /// Decode one bit through the context at `contexts[index]`, adapting it in place.
    func decode(_ contexts: inout [UInt8], _ index: Int) -> Int {
        guard !failed else { return 0 }
        let state = Int(contexts[index])
        let z = a + Int(DjVuZPTable.p[state])
        if z <= fence {
            a = z
            return state & 1
        }
        return decodeSub(&contexts, index, state, z)
    }

    /// Equiprobable bit, no context (the interval split of Figure 2 in the spec).
    func decodePassThrough() -> Int {
        decodeUnmodelled(mps: 0, split: 0x8000 + (a >> 1))
    }

    private func decodeSub(_ contexts: inout [UInt8], _ index: Int, _ state: Int, _ split: Int) -> Int {
        let bit = state & 1
        var z = split
        // Keep the interval from reverting: the split may not exceed this bound.
        let limit = 0x6000 + ((z + a) >> 2)
        if z > limit { z = limit }

        if z > code {
            // Less probable symbol.
            z = 0x10000 - z
            a += z
            code += z
            contexts[index] = DjVuZPTable.down[state]
            let shift = shiftFor(a)
            scount -= shift
            a = (a << shift) & 0xffff
            code = ((code << shift) & 0xffff)
                | Int((buffer >> UInt32(scount & 31)) & UInt32((1 << shift) - 1))
            if scount < 16 { preload() }
            fence = code >= 0x8000 ? 0x7fff : code
            return bit ^ 1
        }

        // More probable symbol.
        if a >= Int(DjVuZPTable.m[state]) { contexts[index] = DjVuZPTable.up[state] }
        scount -= 1
        a = (z << 1) & 0xffff
        code = ((code << 1) & 0xffff) | Int((buffer >> UInt32(scount & 31)) & 1)
        if scount < 16 { preload() }
        fence = code >= 0x8000 ? 0x7fff : code
        return bit
    }

    private func decodeUnmodelled(mps: Int, split: Int) -> Int {
        var z = split
        if z > code {
            z = 0x10000 - z
            a += z
            code += z
            let shift = shiftFor(a)
            scount -= shift
            a = (a << shift) & 0xffff
            code = ((code << shift) & 0xffff)
                | Int((buffer >> UInt32(scount & 31)) & UInt32((1 << shift) - 1))
            if scount < 16 { preload() }
            fence = code >= 0x8000 ? 0x7fff : code
            return mps ^ 1
        }
        scount -= 1
        a = (z << 1) & 0xffff
        code = ((code << 1) & 0xffff) | Int((buffer >> UInt32(scount & 31)) & 1)
        if scount < 16 { preload() }
        fence = code >= 0x8000 ? 0x7fff : code
        return mps
    }
}

/// The BZZ block codec: decode a whole stream into one buffer.
enum DjVuBZZ {

    private static let maxBlockKB = 4096
    private static let frequencySlots = 4
    private static let contextIds = 3

    /// Decodes `input` (one BSByteStream: the payload of a `DIRM`/`NAVM`/`TXTz`/
    /// `ANTz` chunk, from its first byte) into the bytes it stands for.
    /// Returns nil when the stream is damaged - callers fall back to "no contents"
    /// rather than presenting half a table of contents.
    static func decompress(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let coder = DjVuZPCoder(input)
        var contexts = [UInt8](repeating: 0, count: 300)
        var output: [UInt8] = []
        while true {
            guard let block = decodeBlock(coder, &contexts) else { break }
            output.append(contentsOf: block)
            if coder.failed { return nil }
        }
        return coder.failed ? nil : output
    }

    /// A plain binary value: the tree of equiprobable bits the reference decoder
    /// reads for lengths and the like.
    private static func decodeRaw(_ coder: DjVuZPCoder, bits: Int) -> Int {
        var n = 1
        let limit = 1 << bits
        while n < limit { n = (n << 1) | coder.decodePassThrough() }
        return n - limit
    }

    /// A modelled binary value: `bits` decisions through contexts `pointer..`.
    private static func decodeBinary(_ coder: DjVuZPCoder, _ contexts: inout [UInt8], pointer: Int, bits: Int) -> Int {
        var n = 1
        let limit = 1 << bits
        let base = pointer - 1
        while n < limit {
            n = (n << 1) | coder.decode(&contexts, base + n)
        }
        return n - limit
    }

    /// One Burrows-Wheeler block; nil for the terminator block (size 0).
    private static func decodeBlock(_ coder: DjVuZPCoder, _ contexts: inout [UInt8]) -> [UInt8]? {
        let size = decodeRaw(coder, bits: 24)
        if size == 0 { return nil }
        guard size <= maxBlockKB * 1024 else { return nil }

        var data = [UInt8](repeating: 0, count: size)

        // How fast the frequency estimates follow the data.
        var shift = 0
        if coder.decodePassThrough() == 1 {
            shift += 1
            if coder.decodePassThrough() == 1 { shift += 1 }
        }

        // The quasi move-to-front list, ordered by how recently each byte was seen.
        var mtf = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 { mtf[index] = UInt8(index) }
        var frequencies = [UInt32](repeating: 0, count: frequencySlots)
        var addition: UInt32 = 4

        var mtfNumber = 3
        var markerPosition = -1

        for index in 0..<size {
            var contextId = contextIds - 1
            if contextId > mtfNumber { contextId = mtfNumber }
            var base = 0
            var decoded = true

            if coder.decode(&contexts, base + contextId) == 1 {
                mtfNumber = 0
                data[index] = mtf[0]
            } else {
                base += contextIds
                if coder.decode(&contexts, base + contextId) == 1 {
                    mtfNumber = 1
                    data[index] = mtf[1]
                } else {
                    base += contextIds
                    if coder.decode(&contexts, base) == 1 {
                        mtfNumber = 2 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 1)
                        data[index] = mtf[mtfNumber]
                    } else {
                        base += 2
                        if coder.decode(&contexts, base) == 1 {
                            mtfNumber = 4 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 2)
                            data[index] = mtf[mtfNumber]
                        } else {
                            base += 4
                            if coder.decode(&contexts, base) == 1 {
                                mtfNumber = 8 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 3)
                                data[index] = mtf[mtfNumber]
                            } else {
                                base += 8
                                if coder.decode(&contexts, base) == 1 {
                                    mtfNumber = 16 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 4)
                                    data[index] = mtf[mtfNumber]
                                } else {
                                    base += 16
                                    if coder.decode(&contexts, base) == 1 {
                                        mtfNumber = 32 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 5)
                                        data[index] = mtf[mtfNumber]
                                    } else {
                                        base += 32
                                        if coder.decode(&contexts, base) == 1 {
                                            mtfNumber = 64 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 6)
                                            data[index] = mtf[mtfNumber]
                                        } else {
                                            base += 64
                                            if coder.decode(&contexts, base) == 1 {
                                                mtfNumber = 128 + decodeBinary(coder, &contexts, pointer: base + 1, bits: 7)
                                                data[index] = mtf[mtfNumber]
                                            } else {
                                                mtfNumber = 256
                                                data[index] = 0
                                                markerPosition = index
                                                decoded = false
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !decoded { continue }

            // Re-order the list by empirical frequency: the slot an entry belongs in
            // moves with how often it has been seen.
            addition = addition &+ (addition >> UInt32(shift))
            if addition > 0x1000_0000 {
                addition >>= 24
                for slot in 0..<frequencySlots { frequencies[slot] >>= 24 }
            }
            var count = addition
            if mtfNumber < frequencySlots { count = count &+ frequencies[mtfNumber] }
            var slot = mtfNumber
            while slot >= frequencySlots {
                mtf[slot] = mtf[slot - 1]
                slot -= 1
            }
            while slot > 0 && count >= frequencies[slot - 1] {
                mtf[slot] = mtf[slot - 1]
                frequencies[slot] = frequencies[slot - 1]
                slot -= 1
            }
            mtf[slot] = data[index]
            frequencies[slot] = count
        }

        guard markerPosition >= 1, markerPosition < size else { return nil }

        // Inverse Burrows-Wheeler: the first byte of each entry doubles as the byte
        // value, the rest as the rank within its own bucket.
        var positions = [UInt32](repeating: 0, count: size)
        var counts = [Int32](repeating: 0, count: 256)
        for index in 0..<size where index != markerPosition {
            let value = data[index]
            positions[index] = (UInt32(value) << 24) | UInt32(truncatingIfNeeded: counts[Int(value)] & 0xff_ffff)
            counts[Int(value)] += 1
        }
        var offset: Int32 = 1
        for value in 0..<256 {
            let count = counts[value]
            counts[value] = offset
            offset += count
        }
        var index = 0
        var last = size - 1
        while last > 0 {
            let entry = positions[index]
            let value = Int(entry >> 24)
            data[last - 1] = UInt8(value)
            last -= 1
            index = Int(counts[value] + Int32(truncatingIfNeeded: entry & 0xff_ffff))
        }
        guard index == markerPosition else { return nil }

        // The last byte is the marker slot the reconstruction consumed.
        return Array(data[0..<(size - 1)])
    }
}
