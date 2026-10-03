//
//  FB2Backend.swift
//  EBookQLKit
//
//  FictionBook 2.x (.fb2) -> Book.
//
//  FB2 is XML: one document holding the metadata, the text and every image (base64, in
//  <binary> elements). There is nothing to unzip and nothing to unlink, so this backend is
//  a single streaming pass with `XMLParser` that writes HTML as it goes.
//
//  Like a MOBI, the whole book becomes ONE section: a note link inside the text has to land
//  in the same section for its anchor to survive the renderer's `chN--` namespacing (see
//  BookSection), and FB2 puts the notes in a second <body> at the end of the same file.
//
//  The table of contents is not declared by the format in any list we can read - it IS the
//  section nesting - so `<title>` elements are emitted as `<h1>`-`<h3>` and the renderer
//  derives the sidebar from them, exactly as it does for a MOBI. That is also what gives
//  every chapter a real anchor for the reading position.
//

import Foundation
import os.log

public final class FB2Backend: BookBackend {

    public static let supportedExtensions: Set<String> = ["fb2"]

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "FB2")

    /// One section, so the renderer namespaces every id in the document with this index:
    /// an anchor called `n1` in the file becomes `ch0--n1` in the page.
    private static let sectionID = "ch0"

    /// The renderer's sidebar derivation reads `<h1>`-`<h3>` only (`headingRegex`), so a
    /// section title is capped there. FB2 nests deeper and a fourth level would silently
    /// disappear from the contents - the deeper sections keep their text and flatten into
    /// h3, which is visible in the page even where the sidebar is one level short.
    static let titleLevelLimit = 3

    /// Point at which the markup is cut, at a section boundary - the same ceiling the other
    /// formats use, for the same reason: WebKit laying out an unbounded page.
    static let markupLimit = 8 * 1024 * 1024

    /// Base64 image data kept for the page. A book past this keeps all of its text and loses
    /// the images beyond the cut, rather than taking the preview down with it.
    static let binaryLimit = 64 * 1024 * 1024

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let started = Date()

        let data = try read(url)
        let text = try decode(data)
        let document = try FB2Document.parse(text, markupLimit: markupLimit, binaryLimit: binaryLimit)

        guard !document.html.isEmpty else { throw BookParseError.malformed }

        var metadata = document.metadata
        if let cover = document.coverID { metadata.coverPath = FB2ResourceProvider.prefix + cover }

        // What the sidebar says when the book was cut: "the first X MB of Y MB". Only the
        // text is cut, so the total excludes the base64 images - otherwise a 40 MB file with
        // 30 MB of pictures would claim to have lost far more text than it has.
        let shown = document.html.utf8.count
        let total = document.truncated ? max(shown, data.count - document.binaryBytes) : shown

        os_log("parsed in %.2fs | %{public}d chars of markup | %{public}d images (%.1f MB) | %{public}d sections%s",
               log: log, type: .info,
               Date().timeIntervalSince(started), shown,
               document.binaries.count, Double(document.binaryBytes) / 1_048_576.0,
               document.sections, document.truncated ? " | TRUNCATED" : "")

        return Book(
            url: url,
            format: .fb2,
            metadata: metadata,
            sections: [BookSection(id: sectionID, html: document.html)],
            // Nothing is declared, so the heading derivation is the table of contents (the
            // same contract a Markdown file has). See the file header.
            toc: [],
            tocBasePath: nil,
            resources: FB2ResourceProvider(binaries: document.binaries),
            truncatedAt: document.truncated ? shown : nil,
            contentBytes: total,
            tocIsFallback: false
        )
    }

    /// Finder asks for a folder's worth of thumbnails at once, so the parse stops at the end
    /// of the first section: a card needs the title, the author and some opening text.
    public static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let data = try read(url)
        let text = try decode(data)
        let document = try FB2Document.parse(
            text, markupLimit: 256 * 1024, binaryLimit: 0, stopAfterFirstSection: true
        )

        return Book(
            url: url,
            format: .fb2,
            metadata: document.metadata,
            sections: [BookSection(id: sectionID, html: document.html)],
            toc: [],
            resources: nil,
            contentBytes: document.html.utf8.count,
            tocIsFallback: false
        )
    }

    // MARK: - Reading the file

    private static func read(_ url: URL) throws -> Data {
        // The whole file is read because the images live inside it and the page fetches them
        // long after this call. Measured on the sample corpus: 268 KB of XML, 132 KB of which
        // is one base64 cover; the largest real-world file seen is 12 MB.
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw BookParseError.io
        }
    }

    /// FB2 files in the wild are not always UTF-8: the format's own tooling wrote
    /// `windows-1251` and `koi8-r` for years, and a file whose declaration says one thing and
    /// whose bytes are another is not rare either. So: trust the declaration, then UTF-8,
    /// then windows-1251, and let the first one that decodes win.
    static func decode(_ data: Data) throws -> String {
        for encoding in candidateEncodings(for: data) {
            if let text = String(data: data, encoding: encoding), !text.isEmpty { return text }
        }
        throw BookParseError.malformed
    }

    private static func candidateEncodings(for data: Data) -> [String.Encoding] {
        var encodings: [String.Encoding] = []
        if let declared = declaredEncoding(in: data) { encodings.append(declared) }
        encodings.append(.utf8)
        encodings.append(.windowsCP1251)
        encodings.append(.isoLatin1)
        return encodings
    }

    /// The `encoding="…"` of the XML declaration, resolved through CoreFoundation's IANA
    /// table so the long tail (`cp866`, `koi8-u`, `iso-8859-5`, …) works without a hand-kept
    /// list. The declaration is ASCII by definition, so it is read from the first 200 bytes.
    static func declaredEncoding(in data: Data) -> String.Encoding? {
        let window = data.prefix(200)
        guard let ascii = String(data: window, encoding: .isoLatin1),
              let range = ascii.range(of: "encoding", options: [.caseInsensitive]) else { return nil }
        let rest = ascii[range.upperBound...]
        guard let quote = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let name = rest[rest.index(after: quote)...].prefix { $0 != "\"" && $0 != "'" }
        guard !name.isEmpty else { return nil }

        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

/// An image the page can ask for later: the base64 payload as it was written, decoded on
/// first request (most books have images no one scrolls to).
struct FB2Image {
    let mimeType: String?
    let base64: String
}

/// Serves a FB2 document's embedded images.
///
/// Decoding happens per request and is cached, because a 12 MB book can hold 8 MB of base64
/// and the preview usually shows a handful of them.
public final class FB2ResourceProvider: ResourceProvider {

    /// Scheme-relative prefix of every image path: `/fb2/<id>`.
    static let prefix = "/fb2/"

    private let binaries: [String: FB2Image]
    private var decoded: [String: (data: Data, mimeType: String?)] = [:]
    private let lock = NSLock()

    init(binaries: [String: FB2Image]) {
        self.binaries = binaries
    }

    /// References are rewritten while the markup is built (`FB2Document`), so there is
    /// nothing left for the renderer to resolve; a provider still has to answer, though.
    public func url(for path: String, relativeTo base: String?) -> String? {
        let id = path.hasPrefix("#") ? String(path.dropFirst()) : path
        return binaries[id] == nil ? nil : "\(BookResourceScheme.name)://\(Self.prefix)\(id)"
    }

    /// Paths look like `/fb2/<id>`, where the id is the one the document gave the `<binary>`.
    /// Ids are free-form (`img_0`, `cover.jpg`, `картинка`), so the spelling is percent-decoded
    /// back before the lookup, and both spellings are tried.
    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        guard path.hasPrefix(Self.prefix) else { return nil }
        let encoded = String(path.dropFirst(Self.prefix.count))
        guard !encoded.isEmpty else { return nil }
        let id = encoded.removingPercentEncoding ?? encoded
        guard let image = binaries[id] ?? binaries[encoded] else { return nil }
        if let ready = lock.withLock({ decoded[id] }) { return ready }

        guard let data = Data(base64Encoded: image.base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        let ready = (data: data, mimeType: image.mimeType)
        lock.withLock { decoded[id] = ready }
        return ready
    }
}
