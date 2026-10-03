//
//  CBZBackend.swift
//  EBookQLKit
//
//  CBZ -> Book.
//
//  A CBZ is a ZIP archive of page images, so this is the second of the two page-image formats
//  (DjVu is the other) and shares `PageImageBook` with it: one section per page, a page box
//  with the page's own aspect ratio, and the same contents rule. What differs is that nothing
//  has to be decoded - a page is a JPEG or a PNG, and the web view loads it.
//
//  Hence no script of its own: each page box holds an `<img loading="lazy">` pointed at
//  `ekbres://cbz/page/<n>`, and the archive is decompressed one page at a time, on demand, for
//  exactly the images the reader is looking at. The archive is opened read-only on the file
//  the preview already holds a security scope for, so a 400 MB comic costs its central
//  directory and whatever it shows.
//

import Foundation
import UniformTypeIdentifiers
import ZIPFoundation
import os.log

public final class CBZBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["cbz"]

    /// Resource host and path shape: `ekbres://cbz/page/<index>`. Only `.cbz` is claimed -
    /// `.cbr` is RAR and `.cbt` is TAR, neither of which is a ZIP.
    static let host = "cbz"
    static let resourcePrefix = "/page/"

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "CBZ")

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let started = Date()
        let document = try CBZDocument(url: url)
        let pages = pageModels(document)
        let contents = PageImageBook.contents(pages, declared: declaredTOC(document, pages: pages),
                                              pageList: pageList(document, pages: pages))

        os_log("cbzbook %{public}@ %{public}d pages, %{public}@ contents in %.2fs",
               log: log, type: .info, url.lastPathComponent, pages.count,
               contents.isFallback ? "listed" : "declared", Date().timeIntervalSince(started))

        return Book(
            url: url,
            format: .cbz,
            metadata: BookMetadata(
                title: document.displayTitle
                    ?? url.deletingPathExtension().lastPathComponent,
                author: document.writer
            ),
            sections: PageImageBook.sections(pages, host: host, headings: pages.count > 1) { _, url in
                // The page image itself. Nothing decodes it: an `<img>` in a box of the
                // page's own shape is the whole renderer for this format.
                "<img src=\"\(url)\" loading=\"lazy\" decoding=\"async\" alt=\"\">"
            },
            toc: contents.toc,
            resources: CBZResourceProvider(url: url, entryPaths: document.pages.map(\.path)),
            tocIsFallback: contents.isFallback,
            tocNote: contents.note
        )
    }

    /// Cheap open for the Finder card: the archive's central directory, and its manifest if
    /// it has one. No page image and no image header is touched.
    public static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let document = try CBZDocument(url: url, geometries: false)
        return Book(
            url: url,
            format: .cbz,
            metadata: BookMetadata(
                title: document.displayTitle
                    ?? url.deletingPathExtension().lastPathComponent,
                author: document.writer
            ),
            sections: [BookSection(id: "p1", html: "")]
        )
    }

    // MARK: - Pieces

    private static func pageModels(_ document: CBZDocument) -> [PageImageBook.Page] {
        document.pages.enumerated().map { index, page in
            PageImageBook.Page(
                key: page.path,
                label: page.label,
                width: page.width,
                height: page.height,
                resource: "\(resourcePrefix)\(index)"
            )
        }
    }

    /// The manifest's bookmarks, when the archive has a `ComicInfo.xml` that names pages.
    private static func declaredTOC(
        _ document: CBZDocument,
        pages: [PageImageBook.Page]
    ) -> [TOCEntry] {
        document.bookmarks.map { bookmark in
            TOCEntry(title: bookmark.title, target: PageImageBook.target(pages[bookmark.index]))
        }
    }

    /// A comic with no manifest: the pages are listed, and a comic whose pages sit in folders
    /// (what a multi-chapter scan looks like) is listed one level deeper, because a flat list
    /// of 600 pages named `001` to `050` sixteen times over is not navigation. The folders are
    /// the archive's own, so this is the file's structure, not a guess about its contents.
    private static func pageList(
        _ document: CBZDocument,
        pages: [PageImageBook.Page]
    ) -> [TOCEntry] {
        guard document.pages.contains(where: { $0.folder != nil }) else {
            return pages.map { TOCEntry(title: $0.label, target: PageImageBook.target($0)) }
        }
        var out: [TOCEntry] = []
        var currentFolder: String?
        var children: [TOCEntry] = []
        func flush() {
            guard !children.isEmpty else { return }
            if let folder = currentFolder {
                out.append(TOCEntry(
                    title: (folder as NSString).lastPathComponent,
                    target: nil,
                    children: children
                ))
            } else {
                // Pages at the archive's root: no folder to name them by, so they stand on
                // their own rather than under a heading that would have to be invented.
                out.append(contentsOf: children)
            }
            children = []
        }
        for (index, page) in document.pages.enumerated() {
            if page.folder != currentFolder {
                flush()
                currentFolder = page.folder
            }
            children.append(TOCEntry(title: pages[index].label,
                                     target: PageImageBook.target(pages[index])))
        }
        flush()
        return out
    }
}

// MARK: - Page bytes

/// Serves page images straight out of the archive, one requested image at a time. The archive
/// is opened on first use, off the scheme handler's serial queue, exactly like the EPUB one.
public final class CBZResourceProvider: ResourceProvider {

    private let url: URL
    private let entryPaths: [String]
    private var archive: Archive?

    init(url: URL, entryPaths: [String]) {
        self.url = url
        self.entryPaths = entryPaths
    }

    /// A CBZ page references nothing - no CSS, no fonts, no sibling images - so the renderer
    /// has nothing to resolve.
    public func url(for path: String, relativeTo base: String?) -> String? { nil }

    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        guard path.hasPrefix(CBZBackend.resourcePrefix),
              let index = Int(path.dropFirst(CBZBackend.resourcePrefix.count)),
              entryPaths.indices.contains(index) else { return nil }
        let entryPath = entryPaths[index]
        guard let archive = openArchive(), let entry = archive[entryPath] else { return nil }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        guard (try? archive.extract(entry) { data.append($0) }) != nil else { return nil }
        return (data, mimeType(for: entryPath))
    }

    private func openArchive() -> Archive? {
        if let archive { return archive }
        let opened = try? Archive(url: url, accessMode: .read)
        archive = opened
        return opened
    }

    private func mimeType(for entryPath: String) -> String? {
        UTType(filenameExtension: (entryPath as NSString).pathExtension)?.preferredMIMEType
    }
}
