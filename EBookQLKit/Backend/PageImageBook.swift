//
//  PageImageBook.swift
//  EBookQLKit
//
//  What the two page-image formats (DjVu and CBZ) share: a book whose content is a list
//  of page images and nothing else.
//
//  Both formats answer the same questions the same way, so the answers live here rather
//  than twice:
//
//  * one section per page, each opening with a heading that is present but invisible - the
//    reader's reading position and sidebar highlight are built from real headings, and a
//    scan has no text to give them one;
//  * the page box: an aspect ratio, so the box has its final height before the image is
//    there (nothing shifts when a page arrives, and a restored position is exact), plus a
//    label and the resource the format serves that page from;
//  * the contents rule - the file's own outline when it declares one, a page list that
//    says what it is when it does not, and no sidebar at all for a single page.
//
//  What is NOT shared is how a page becomes pixels: DjVu's pages are fetched and decoded
//  by the reader page's own script, CBZ's are plain images and the web view loads them.
//

import Foundation

public enum PageImageBook {

    /// One page, as the reader page needs it.
    public struct Page: Sendable {
        /// Section id, and what a declared outline's targets resolve to.
        public let key: String
        /// What the sidebar shows for this page.
        public let label: String
        /// Pixel size, for the page box's aspect ratio. Zero when the file did not say.
        public let width: Int
        public let height: Int
        /// Scheme-relative resource path on the format's host, e.g. `/page/3`.
        public let resource: String

        public init(key: String, label: String, width: Int, height: Int, resource: String) {
            self.key = key
            self.label = label
            self.width = width
            self.height = height
            self.resource = resource
        }
    }

    /// One section per page. `inner` builds the markup inside the page box - the DjVu
    /// script fills an empty box, a CBZ box holds the `<img>` - and receives the page's
    /// absolute resource URL.
    public static func sections(
        _ pages: [Page],
        host: String,
        headings: Bool,
        inner: (Page, String) -> String = { _, _ in "" }
    ) -> [BookSection] {
        pages.enumerated().map { index, page in
            var attributes = " data-page=\"\(index)\" data-label=\"\(index + 1)\""
            if !page.resource.isEmpty { attributes += " data-source=\"\(page.resource)\"" }
            if page.width > 0, page.height > 0 {
                attributes += " style=\"aspect-ratio: \(page.width) / \(page.height)\""
            }
            let url = resourceURL(host: host, resource: page.resource)
            let heading = headings
                ? "<h1 class=\"page-no\" id=\"page-\(index + 1)\">"
                    + "\(HTMLNormalizer.escapeHTML(page.label))</h1>\n"
                : ""
            return BookSection(
                id: page.key,
                html: heading + "<div class=\"page-frame\"\(attributes)>\(inner(page, url))</div>",
                sourcePath: page.key,
                title: page.label
            )
        }
    }

    /// The contents rule: a declared outline (the file's own) wins, otherwise the pages are
    /// listed and the sidebar says so, and a single page gets no sidebar at all.
    ///
    /// `pageList` is what to show when there is nothing declared - the flat list of pages
    /// unless the format found a better way to present the same pagination (a CBZ whose pages
    /// sit in chapter folders nests them).
    public static func contents(
        _ pages: [Page],
        declared: [TOCEntry],
        pageList: [TOCEntry]? = nil
    ) -> (toc: [TOCEntry], isFallback: Bool, note: String?) {
        if !declared.isEmpty { return (declared, false, nil) }
        guard pages.count > 1 else { return ([], false, nil) }
        let listed = pageList
            ?? pages.map { TOCEntry(title: $0.label, target: BookTarget(sectionPath: $0.key)) }
        return (listed, true, pageListNote)
    }

    /// Shown above a page list that stands in for a file with no contents of its own. The
    /// list is page numbering, not a table of contents, and the sidebar must not imply
    /// otherwise (the same rule the FB2 backend follows for guessed contents).
    public static var pageListNote: String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh")
            ? "这个文件里没有目录，下面列出的是页面。"
            : "This file declares no contents; the pages are listed instead."
    }

    /// Leaf `BookTarget` for a page, for a format that found its own outline.
    public static func target(_ page: Page) -> BookTarget {
        BookTarget(sectionPath: page.key)
    }

    public static func resourceURL(host: String, resource: String) -> String {
        "\(BookResourceScheme.name)://\(host)\(resource)"
    }
}
