//
//  DjVuStructure.swift
//  EBookQLKit
//
//  What a DjVu file says about itself: the IFF chunk tree, the multi-page
//  directory, the outline and the document metadata.
//
//  DjVu is a container (FORM:DJVM holding one FORM:DJVU per page, or a bare
//  FORM:DJVU for a single page). Everything a reader needs is in small chunks near
//  the front of the file; the page *images* are the rest of it, and they are never
//  decoded here - the preview hands each page's bytes to the vendored JavaScript
//  decoder and lets it rasterise them in the web view.
//
//  Only the parts that are text are compressed (DIRM, NAVM, ANTz); see DjVuBZZ.
//

import Foundation

/// One chunk of the IFF tree. `payload` is the chunk's data; for a container it
/// includes the four-byte type that follows `FORM`.
struct DjVuChunk {
    let id: String
    let formType: String?
    /// Offset of the chunk header in the file, so a page can be handed out as a
    /// stand-alone DjVu file of its own.
    let headerOffset: Int
    let payload: Range<Int>
    var children: [DjVuChunk] = []

    var name: String { formType.map { "\(id):\($0)" } ?? id }

    func child(_ id: String) -> DjVuChunk? { children.first { $0.id == id } }
    func children(_ id: String) -> [DjVuChunk] { children.filter { $0.id == id } }
}

/// One page of the document.
struct DjVuPage {
    let index: Int
    /// The directory's own names for the page, when it has a directory.
    let directoryID: String?
    let directoryName: String?
    let directoryTitle: String?
    /// The whole `FORM:DJVU` chunk, header included: a page served on its own is
    /// this, wrapped in a fresh container header.
    let chunk: Range<Int>
    let width: Int
    let height: Int
    let dpi: Int
    /// A page whose shapes live in a dictionary in another component of the
    /// document (`INCL`): its own bytes cannot be decoded on their own.
    let hasSharedDictionary: Bool

    /// The label the sidebar uses for this page: the file's own title when it has
    /// one that is not just the component's file name, otherwise the page number.
    var label: String {
        if let title = directoryTitle, !title.isEmpty, !DjVuFileNames.looksLikeFileName(title),
           title != directoryName, title != directoryID {
            return title
        }
        return String(index + 1)
    }
}

/// A node of the outline (`NAVM`). The URL is kept as the file wrote it; the
/// fragment is resolved against the directory when the book is built.
struct DjVuOutlineNode {
    let title: String
    let fragment: String?
    var children: [DjVuOutlineNode] = []
}

/// Everything the backend needs, read once.
struct DjVuStructure {
    /// The `FORM` payload: what a stand-alone copy of the whole document is.
    let documentRange: Range<Int>
    /// False for the multi-file ("indirect") flavour, whose pages live in sibling
    /// files.
    let bundled: Bool
    let pages: [DjVuPage]
    let outline: [DjVuOutlineNode]
    let title: String?
    let author: String?

    var isMultiPage: Bool { pages.count > 1 }
}

enum DjVuParseError: Error, LocalizedError {
    case notDjVu
    case indirectDocument
    case noPages

    /// Shown verbatim as the detail line of the notice page (only `BookParseError` cases
    /// get a summary of their own), so it says what is actually wrong with this file.
    var errorDescription: String? {
        switch self {
        case .notDjVu: return "This file does not start with a DjVu container (AT&T FORM)."
        case .indirectDocument:
            return "This DjVu is a multi-file document: its pages live in separate files, which a preview cannot follow."
        case .noPages: return "The DjVu container holds no pages."
        }
    }
}

enum DjVuFileNames {
    private static let imageExtensions: Set<String> = [
        "djvu", "djv", "tif", "tiff", "jpg", "jpeg", "png", "gif", "bmp", "pdf", "pbm", "pgm", "ppm",
    ]

    /// Whether a directory title is really just the component's file name - what a
    /// conversion leaves behind ("00000001.djvu"), and not worth showing as a label.
    static func looksLikeFileName(_ value: String) -> Bool {
        let ext = (value as NSString).pathExtension.lowercased()
        return !ext.isEmpty && imageExtensions.contains(ext)
    }
}

// MARK: - Reading

enum DjVuStructureReader {

    /// Number of bytes that have to be read to know the document's shape: the
    /// directory, the outline and the annotations all live in front of the first
    /// page's image. Used by the thumbnail path so a folder of scans does not pull
    /// every page through the volume.
    static let headerBytes = 256 * 1024

    /// Parses the file. A truncated buffer (the thumbnail path reads only the
    /// front) still yields the page *count* and the metadata, because both come
    /// from the directory; only the page sizes are then unknown.
    static func read(_ data: Data) throws -> DjVuStructure {
        guard data.count >= 16, data.djVuAscii(0..<4) == "AT&T" else { throw DjVuParseError.notDjVu }
        let top = parseChunks(data, from: 4, to: data.count)
        guard let form = top.first, form.id == "FORM", let type = form.formType else {
            throw DjVuParseError.notDjVu
        }
        let end = min(form.payload.upperBound, data.count)

        switch type {
        case "DJVU":
            return try singlePageDocument(data, form: form, end: end)
        case "DJVM":
            break
        default:
            throw DjVuParseError.notDjVu
        }

        // The directory is what makes a DJVM readable: it names the pages, marks
        // which components are pages at all, and holds the outline's target names.
        let directory = form.child("DIRM").flatMap { parseDirectory(data, $0) }
        if let directory, !directory.bundled { throw DjVuParseError.indirectDocument }

        // Components appear in the same order as the directory's entries, so a
        // directory entry and a `FORM` child line up by index. Without a directory -
        // or with one that disagrees with the tree - believe the tree, which is what
        // actually holds the images.
        let components = form.children.filter {
            guard let type = $0.formType else { return false }
            return type == "DJVU" || type == "DJVI" || type == "THUM"
        }

        var pages: [DjVuPage] = []
        if let directory, !directory.files.isEmpty {
            for (index, file) in directory.files.enumerated() where file.isPage {
                let component = index < components.count ? components[index] : nil
                pages.append(page(at: pages.count, form: component, file: file, data: data))
            }
        }
        if pages.isEmpty {
            for component in components where component.formType == "DJVU" {
                pages.append(page(at: pages.count, form: component, file: nil, data: data))
            }
        }
        guard !pages.isEmpty else { throw DjVuParseError.noPages }

        let metadata = documentMetadata(data, form: form, components: components)
        return DjVuStructure(
            documentRange: 0..<end,
            bundled: true,
            pages: pages,
            outline: form.child("NAVM").flatMap { parseOutline(data, $0) } ?? [],
            title: metadata.title,
            author: metadata.author
        )
    }

    private static func singlePageDocument(_ data: Data, form: DjVuChunk, end: Int) throws -> DjVuStructure {
        let info = parseInfo(data, form)
        guard info.width > 0, info.height > 0 else { throw DjVuParseError.noPages }
        let page = DjVuPage(
            index: 0,
            directoryID: nil,
            directoryName: nil,
            directoryTitle: nil,
            chunk: form.headerOffset..<end,
            width: info.width, height: info.height, dpi: info.dpi,
            hasSharedDictionary: !form.children("INCL").isEmpty
        )
        let metadata = documentMetadata(data, form: form, components: [form])
        return DjVuStructure(
            documentRange: 0..<end,
            bundled: true,
            pages: [page],
            outline: [],
            title: metadata.title,
            author: metadata.author
        )
    }

    /// One page, from its component when the walk reached it (a truncated read
    /// cannot) and from the directory entry otherwise.
    private static func page(
        at index: Int,
        form: DjVuChunk?,
        file: DjVuDirectoryFile?,
        data: Data
    ) -> DjVuPage {
        let info = form.map { parseInfo(data, $0) } ?? (width: 0, height: 0, dpi: 0)
        return DjVuPage(
            index: index,
            directoryID: file?.id,
            directoryName: file?.name,
            directoryTitle: file?.title,
            chunk: form.map { $0.headerOffset..<$0.payload.upperBound } ?? 0..<0,
            width: info.width,
            height: info.height,
            dpi: info.dpi,
            hasSharedDictionary: !(form?.children("INCL").isEmpty ?? true)
        )
    }

    // MARK: - Chunk tree

    static func parseChunks(_ data: Data, from start: Int, to end: Int) -> [DjVuChunk] {
        var chunks: [DjVuChunk] = []
        var offset = start
        while offset + 8 <= end {
            let id = data.djVuAscii(offset..<(offset + 4))
            guard let size = data.djVuUInt32(offset + 4) else { break }
            let payloadStart = offset + 8
            let payloadEnd = min(payloadStart + size, end)
            if id == "FORM" {
                let type = data.djVuAscii(payloadStart..<min(payloadStart + 4, end))
                var chunk = DjVuChunk(
                    id: id, formType: type, headerOffset: offset,
                    payload: payloadStart..<payloadEnd
                )
                chunk.children = parseChunks(data, from: payloadStart + 4, to: payloadEnd)
                chunks.append(chunk)
            } else {
                chunks.append(DjVuChunk(id: id, formType: nil, headerOffset: offset,
                                        payload: payloadStart..<payloadEnd))
            }
            offset = payloadEnd
            if size % 2 == 1 { offset += 1 }
        }
        return chunks
    }

    // MARK: - INFO

    /// The ten-byte page description: size, resolution, gamma, rotation.
    static func parseInfo(_ data: Data, _ form: DjVuChunk) -> (width: Int, height: Int, dpi: Int) {
        guard let info = form.child("INFO"), let width = data.djVuUInt16(info.payload.lowerBound),
              let height = data.djVuUInt16(info.payload.lowerBound + 2) else {
            return (0, 0, 0)
        }
        let bytes = info.payload
        // dpi is little-endian, and 0xff in the low byte means "not set".
        var dpi = 300
        if bytes.count >= 8, let low = data.djVuUInt8(bytes.lowerBound + 6),
           let high = data.djVuUInt8(bytes.lowerBound + 7), low != 0xff {
            let value = (high << 8) | low
            dpi = (value < 25 || value > 6000) ? 300 : value
        }
        return (width, height, dpi)
    }

    // MARK: - Directory

    struct DjVuDirectoryFile {
        let id: String
        let name: String
        let title: String
        let isPage: Bool
    }

    struct DjVuDirectory {
        let bundled: Bool
        let files: [DjVuDirectoryFile]
    }

    static func parseDirectory(_ data: Data, _ chunk: DjVuChunk) -> DjVuDirectory? {
        var cursor = DjVuCursor(data, at: chunk.payload.lowerBound, end: chunk.payload.upperBound)
        guard var version = cursor.u8(), let count = cursor.u16() else { return nil }
        let bundled = version & 0x80 != 0
        version &= 0x7f

        // Bundled documents list an offset per file up front; the rest of the
        // directory (sizes, flags, names) is BZZ-compressed.
        for _ in 0..<count where bundled {
            guard cursor.u32() != nil else { return nil }
        }
        guard let compressed = cursor.rest(), let decoded = DjVuBZZ.decompress(compressed) else {
            return nil
        }

        var reader = DjVuRawCursor(decoded)
        if version > 0 {
            for _ in 0..<count where reader.u24() == nil { return nil }
        }
        var flags: [Int] = []
        for _ in 0..<count {
            guard let flag = reader.u8() else { return nil }
            flags.append(flag)
        }

        var files: [DjVuDirectoryFile] = []
        for flag in flags {
            guard let id = reader.cString() else { return nil }
            let name = flag & 0x80 != 0 ? (reader.cString() ?? id) : id
            let title = flag & 0x40 != 0 ? (reader.cString() ?? id) : id
            files.append(DjVuDirectoryFile(id: id, name: name, title: title,
                                           isPage: flag & 0x3f == 1))
        }
        return DjVuDirectory(bundled: bundled, files: files)
    }

    // MARK: - Outline (NAVM)

    /// The outline is a flat list in pre-order: each entry says how many of the
    /// entries after it are its children.
    static func parseOutline(_ data: Data, _ chunk: DjVuChunk) -> [DjVuOutlineNode]? {
        guard let payload = data.djVuBytes(chunk.payload),
              let decoded = DjVuBZZ.decompress(payload) else { return nil }
        var reader = DjVuRawCursor(decoded)
        guard let count = reader.u16(), count > 0, count < 100_000 else { return nil }

        var flat: [(title: String, url: String, children: Int)] = []
        for _ in 0..<count {
            guard let low = reader.u8(), let high = reader.u8(),
                  let nameSize = reader.u16() else { return nil }
            let children = (high << 8) | low
            guard let title = reader.utf8(nameSize) else { return nil }
            guard let urlSize = reader.u24(), let url = reader.utf8(urlSize) else { return nil }
            flat.append((title: title, url: url, children: children))
        }

        var position = 0
        func nodes(limit: Int) -> [DjVuOutlineNode] {
            var out: [DjVuOutlineNode] = []
            while position < flat.count && out.count < limit {
                let entry = flat[position]
                position += 1
                let children = nodes(limit: entry.children)
                out.append(DjVuOutlineNode(title: entry.title, fragment: fragment(of: entry.url),
                                           children: children))
            }
            return out
        }
        return nodes(limit: flat.count)
    }

    /// A bookmark's URL: the page it points at, either by number (`#3`) or by the
    /// name the directory gave the component (`#page003.djvu`). Anything else - a
    /// remote URL, a page of another document - is kept as an unresolvable label.
    static func fragment(of url: String) -> String? {
        guard let hash = url.lastIndex(of: "#"), hash < url.index(before: url.endIndex) else { return nil }
        let value = String(url[url.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: - Metadata

    /// A DjVu keeps its Dublin-Core-ish metadata in an annotation chunk, either the
    /// document's shared one or the first page's. The payload is an S-expression.
    static func documentMetadata(
        _ data: Data,
        form: DjVuChunk,
        components: [DjVuChunk]
    ) -> (title: String?, author: String?) {
        // Shared annotations first (that is where a writer puts document metadata),
        // then the components in page order.
        var owners: [DjVuChunk] = []
        if let shared = form.children.first(where: { $0.formType == "DJVI" }) { owners.append(shared) }
        owners.append(contentsOf: components)
        owners.append(form)

        for owner in owners {
            for id in ["ANTz", "ANTa"] {
                guard let chunk = owner.child(id) else { continue }
                var payload = data.djVuBytes(chunk.payload) ?? []
                if id == "ANTz" {
                    guard let decoded = DjVuBZZ.decompress(payload) else { continue }
                    payload = decoded
                }
                let text = String(decoding: payload, as: UTF8.self)
                guard text.contains("metadata") else { continue }
                let title = sExpressionValue("Title", in: text)
                let author = sExpressionValue("Author", in: text)
                if title != nil || author != nil { return (title, author) }
            }
        }
        return (nil, nil)
    }

    /// Pulls `(Key "value")` out of a metadata S-expression, tolerating the nesting
    /// the various writers produce.
    private static func sExpressionValue(_ key: String, in text: String) -> String? {
        let pattern = "\\(\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
              match.numberOfRanges > 1 else { return nil }
        let value = source.substring(with: match.range(at: 1))
            .replacingOccurrences(of: "\\\"", with: "\"")
        return value.isEmpty ? nil : value
    }
}

// MARK: - Byte cursors

/// Reads the mapped file. Every accessor is bounds-checked and returns nil past the
/// end, so a truncated download is a parse failure and not a crash.
extension Data {
    func djVuUInt8(_ offset: Int) -> Int? { offset < count ? Int(self[startIndex + offset]) : nil }

    func djVuUInt16(_ offset: Int) -> Int? {
        guard let high = djVuUInt8(offset), let low = djVuUInt8(offset + 1) else { return nil }
        return (high << 8) | low
    }

    func djVuUInt32(_ offset: Int) -> Int? {
        guard let a = djVuUInt8(offset), let b = djVuUInt8(offset + 1),
              let c = djVuUInt8(offset + 2), let d = djVuUInt8(offset + 3) else { return nil }
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    func djVuAscii(_ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= count else { return "" }
        return String(decoding: self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)],
                      as: UTF8.self)
    }

    func djVuBytes(_ range: Range<Int>) -> [UInt8]? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return Array(self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)])
    }
}

/// Sequential reader over the mapped file.
struct DjVuCursor {
    private let data: Data
    private var position: Int
    private let end: Int

    init(_ data: Data, at start: Int, end: Int) {
        self.data = data
        self.position = start
        self.end = end
    }

    mutating func u8() -> Int? {
        defer { position += 1 }
        return position < end ? data.djVuUInt8(position) : nil
    }

    mutating func u16() -> Int? {
        guard position + 1 < end, let high = u8(), let low = u8() else { return nil }
        return (high << 8) | low
    }

    mutating func u32() -> Int? {
        guard let a = u8(), let b = u8(), let c = u8(), let d = u8() else { return nil }
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    /// Everything left, for handing to the BZZ decoder.
    mutating func rest() -> [UInt8]? {
        defer { position = end }
        return data.djVuBytes(position..<end)
    }
}

/// Sequential reader over decoded bytes.
struct DjVuRawCursor {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() -> Int? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return Int(bytes[position])
    }

    mutating func u16() -> Int? {
        guard let high = u8(), let low = u8() else { return nil }
        return (high << 8) | low
    }

    mutating func u24() -> Int? {
        guard let a = u8(), let b = u8(), let c = u8() else { return nil }
        return (a << 16) | (b << 8) | c
    }

    /// A NUL-terminated string (the directory's names are Latin-1 in practice, but
    /// they are written as UTF-8 and decoded as such).
    mutating func cString() -> String? {
        let start = position
        while position < bytes.count && bytes[position] != 0 { position += 1 }
        guard position < bytes.count else { return nil }
        let value = String(decoding: bytes[start..<position], as: UTF8.self)
        position += 1
        return value
    }

    mutating func utf8(_ length: Int) -> String? {
        guard length >= 0, position + length <= bytes.count else { return nil }
        let value = String(decoding: bytes[position..<(position + length)], as: UTF8.self)
        position += length
        return value
    }
}
