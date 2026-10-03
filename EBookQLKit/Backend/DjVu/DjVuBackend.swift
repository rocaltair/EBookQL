//
//  DjVuBackend.swift
//  EBookQLKit
//
//  DjVu (.djvu/.djv) -> Book.
//
//  DjVu is a scanned-page format: a document is a list of page *images*, not text. So
//  the shape of the Book is unlike every other backend's - one section per page, each
//  section a frame the reader's page fills in - and the page images are never decoded
//  here at all. This backend reads the container (DjVuStructure), which is what gives
//  the page list, the outline and the metadata, and hands each page's own bytes to the
//  preview over `ekbres://` for the vendored JavaScript decoder to rasterise.
//
//  Why not decode in Swift: JB2 (bilevel) and IW44 (wavelet) are the whole of DjVu's
//  image coding, and there is no system decoder for either. The JavaScript decoder the
//  reader vendors does both, and a `WKWebView` runs it with a real JIT - measured at
//  ~50-120 ms for a 3492x5587 scan of this library's own books.
//
//  Two document flavours are refused rather than half-rendered: the multi-file
//  ("indirect") flavour, whose pages live in sibling files the extension is not
//  sandboxed to read, and a page whose shapes live in a shared dictionary (`INCL`),
//  which cannot be decoded on its own - that one falls back to handing the whole
//  document over, so the JavaScript side can resolve the dictionary itself.
//

import Foundation
import os.log

public final class DjVuBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["djvu", "djv"]

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "DjVu")

    /// Resource paths on the `ekbres://djvu` host.
    static let resourcePrefix = "/page/"
    static let documentPath = "/document"

    // MARK: - Open

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let started = Date()
        let data = try read(url)
        let structure = try DjVuStructureReader.read(data)
        let pages = structure.pages
        // A page the chunk walk never reached is a page whose bytes are not in the
        // file: a truncated or damaged document. Say so once, instead of showing a
        // book of empty pages.
        guard !pages.contains(where: { $0.chunk.isEmpty }) else { throw BookParseError.corrupt }
        // A page that inherits its shapes (`INCL`) cannot be decoded from its own
        // bytes: hand the reader the whole document instead and let it resolve the
        // dictionary, which is the one thing the per-page route exists to avoid.
        let shared = pages.contains { $0.hasSharedDictionary }
        let resource: (Int) -> String = { index in
            shared ? Self.documentPath : Self.resourcePrefix + String(index)
        }

        let models = pages.map { page in
            PageImageBook.Page(
                key: Self.pageKey(page),
                label: page.label,
                width: page.width,
                height: page.height,
                resource: resource(page.index)
            )
        }
        let outline = structure.outline
        let contents = PageImageBook.contents(
            models,
            declared: self.tocEntries(outline, pages: pages, models: models)
        )

        os_log("djvubook %{public}@ %{public}d pages, outline %{public}d, %{public}@ in %.2fs",
               log: log, type: .info, url.lastPathComponent, pages.count, outline.count,
               shared ? "whole-document" : "per-page", Date().timeIntervalSince(started))

        return Book(
            url: url,
            format: .djvu,
            metadata: metadata(url: url, structure: structure),
            sections: PageImageBook.sections(models, host: Self.host,
                                              headings: models.count > 1),
            toc: contents.toc,
            resources: DjVuResourceProvider(data: data, structure: structure),
            tocIsFallback: contents.isFallback,
            tocNote: contents.note
        )
    }

    /// Cheap open for the Finder card: the directory, the outline and the metadata all
    /// sit in front of the first page's image, so a folder of scans never pulls every
    /// page through the volume. One section, no frames - the card wants the title.
    public static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let head = try readHead(url, limit: DjVuStructureReader.headerBytes)
        let structure = try DjVuStructureReader.read(head)
        return Book(
            url: url,
            format: .djvu,
            metadata: metadata(url: url, structure: structure),
            sections: [BookSection(id: "p1", html: "")]
        )
    }

    // MARK: - Pieces

    /// Scheme host the page bytes are served on: `ekbres://djvu/page/<index>`.
    static let host = "djvu"

    /// The section key doubles as the outline's target: a bookmark naming a component
    /// (`#00000002.djvu`) resolves against the same string.
    private static func pageKey(_ page: DjVuPage) -> String {
        page.directoryID ?? "page-\(page.index + 1)"
    }

    private static func metadata(url: URL, structure: DjVuStructure) -> BookMetadata {
        let fallback = url.deletingPathExtension().lastPathComponent
        return BookMetadata(
            title: structure.title ?? (fallback.isEmpty ? nil : fallback),
            author: structure.author
        )
    }

    /// The file's own outline, in the reader's terms. A bookmark with no page to point at
    /// stays as a plain label rather than becoming a dead link.
    private static func tocEntries(
        _ nodes: [DjVuOutlineNode],
        pages: [DjVuPage],
        models: [PageImageBook.Page]
    ) -> [TOCEntry] {
        nodes.map { node in
            TOCEntry(
                title: node.title,
                target: pageIndex(for: node.fragment, pages: pages)
                    .map { PageImageBook.target(models[$0]) },
                children: tocEntries(node.children, pages: pages, models: models)
            )
        }
    }

    /// Resolves a bookmark URL's fragment: a page number (`#3`, one-based) or the
    /// directory's own name for a component (`#page003.djvu`).
    private static func pageIndex(for fragment: String?, pages: [DjVuPage]) -> Int? {
        guard let fragment, !fragment.isEmpty else { return nil }
        let value = (fragment.removingPercentEncoding ?? fragment).trimmingCharacters(in: .whitespaces)
        if let number = Int(value), number >= 1, number <= pages.count { return number - 1 }
        return pages.firstIndex { $0.directoryID == value || $0.directoryName == value }
            ?? pages.firstIndex { $0.directoryTitle == value }
    }

    /// Shown above a page list that stands in for a file with no outline at all.
    static var pageListNote: String { PageImageBook.pageListNote }

    // MARK: - Files

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BookParseError.io
        }
    }

    private static func readHead(_ url: URL, limit: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw BookParseError.io }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: limit), !head.isEmpty else {
            throw BookParseError.io
        }
        return head
    }
}

// MARK: - Page bytes

/// Serves the page images the reader's script asks for. Nothing is decoded here: a
/// page is handed over as the stand-alone DjVu file it already is, which is what lets
/// the script decode one page at a time instead of holding a whole scanned book in the
/// web view's memory.
public final class DjVuResourceProvider: ResourceProvider {

    private static let mimeType = "image/vnd.djvu"

    private let data: Data
    private let structure: DjVuStructure

    init(data: Data, structure: DjVuStructure) {
        self.data = data
        self.structure = structure
    }

    /// DjVu pages reference no sibling resources - everything they need is inside the
    /// page's own bytes - so the renderer has nothing to resolve.
    public func url(for path: String, relativeTo base: String?) -> String? { nil }

    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        if path == DjVuBackend.documentPath {
            guard let bytes = data.djVuBytes(structure.documentRange) else { return nil }
            return (Data(bytes), Self.mimeType)
        }
        guard path.hasPrefix(DjVuBackend.resourcePrefix),
              let index = Int(path.dropFirst(DjVuBackend.resourcePrefix.count)),
              structure.pages.indices.contains(index) else { return nil }
        guard let page = standalonePage(index) else { return nil }
        return (page, Self.mimeType)
    }

    /// A page's `FORM:DJVU` chunk, wrapped in the four magic bytes a DjVu file starts
    /// with, so the script can parse it with the same code it uses for a whole
    /// document. The chunk already carries its own length, so re-deriving it here
    /// would be one more thing to get wrong - the IFF form is `FORM`, length, subtype.
    private func standalonePage(_ index: Int) -> Data? {
        let range = structure.pages[index].chunk
        guard !range.isEmpty, range.upperBound <= data.count,
              let chunk = data.djVuBytes(range) else { return nil }
        var out = Data("AT&T".utf8)
        out.append(contentsOf: chunk)
        // IFF chunks are padded to an even length.
        if (chunk.count - 8) % 2 == 1 { out.append(0) }
        return out
    }
}
