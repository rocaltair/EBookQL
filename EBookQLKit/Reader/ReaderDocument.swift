//
//  ReaderDocument.swift
//  EBookQLKit
//
//  Book -> the single page the preview loads. This is where every format becomes
//  the same thing: chapters merged into one scrollable page with per-chapter
//  anchor prefixes, one table-of-contents sidebar, one stylesheet, one script.
//

import Foundation

public struct ReaderDocument {

    public struct Options: Sendable {
        public var readingPosition: ReadingPosition?
        public var sidebarWidth: Int?
        /// Whether the contents sidebar folds itself back as the highlight moves on:
        /// the branches the entry just left closes, the new entry's open. Off keeps
        /// the highlight following (and still opens the branch it landed in, or the
        /// highlight would sit inside a folded branch and never be seen) and only
        /// stops the closing. The sidebar's own switch flips it; `window.__ql`
        /// carries it into the page.
        public var autoFoldTOC: Bool
        public var zoom: Double
        /// Whether a markdown book may fetch its remote (http/https) images. Off
        /// unless the reader turned it on in the host window; only Markdown is given
        /// the choice, and every other format's page never loads one.
        public var allowNetworkImages: Bool
        /// Whether an FB2 file with no `<title>` elements may have its contents guessed
        /// from the text - the host window's FB2 tab, on by default. Only FB2 does
        /// anything with it; a book that has titles keeps them.
        public var fb2ContentsFromText: Bool
        /// "Contents" in the user's language.
        public var tocTitle: String
        /// Colour scheme, honoured only by markdown books. Every other format keeps
        /// following `prefers-color-scheme`; see `build`.
        public var theme: MarkdownTheme
        /// Whether a markdown book renders its markup (math + diagrams). Passed
        /// through to the page as `window.__ql.jsParse` and gates the vendored assets.
        public var markdownRendering: Bool
        /// Whether markdown code blocks show line numbers. Passed through to the
        /// page as `window.__ql.lineNumbers`; ignored by every other format.
        public var showLineNumbers: Bool

        public init(
            readingPosition: ReadingPosition? = nil,
            sidebarWidth: Int? = nil,
            autoFoldTOC: Bool = true,
            zoom: Double = 1.0,
            allowNetworkImages: Bool = false,
            fb2ContentsFromText: Bool = true,
            tocTitle: String = ReaderDocument.localizedTOCTitle(),
            theme: MarkdownTheme = .system,
            markdownRendering: Bool = true,
            showLineNumbers: Bool = false
        ) {
            self.readingPosition = readingPosition
            self.sidebarWidth = sidebarWidth
            self.autoFoldTOC = autoFoldTOC
            self.zoom = zoom
            self.allowNetworkImages = allowNetworkImages
            self.fb2ContentsFromText = fb2ContentsFromText
            self.tocTitle = tocTitle
            self.theme = theme
            self.markdownRendering = markdownRendering
            self.showLineNumbers = showLineNumbers
        }
    }

    /// The sidebar label in the user's language; the extension is not localised
    /// itself, so this is the one place the choice is made.
    public static func localizedTOCTitle() -> String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh") ? "目录" : "Contents"
    }

    /// Cap on how many sidebar rows a book may produce: a 27-volume bundle must not
    /// build a thousand-item list.
    private static let tocEntryLimit = 800

    // MARK: - Build

    public static func build(_ book: Book, options: Options = Options()) throws -> (html: String, baseURL: URL?) {
        // Root-relative document path -> section index, for turning cross-file links
        // and TOC references into in-page anchors.
        var sectionIndexByPath: [String: Int] = [:]
        for (index, section) in book.sections.enumerated() {
            if let path = section.sourcePath, sectionIndexByPath[path] == nil {
                sectionIndexByPath[path] = index
            }
        }

        var sectionsHTML = ""
        var headings: [HTMLNormalizer.HeadingEntry] = []
        var headingIndex = 0

        for (index, section) in book.sections.enumerated() {
            // Order matters: ids are namespaced first, then headings get ids, then
            // references are rewritten against the final markup.
            var body = HTMLNormalizer.prefixAnchors(in: section.html, chapter: index)

            let injected = HTMLNormalizer.injectHeadingAnchors(
                in: body,
                chapter: index,
                startingIndex: headingIndex,
                limit: max(0, tocEntryLimit - headings.count)
            )
            body = injected.html
            headings.append(contentsOf: injected.entries)
            headingIndex = injected.nextIndex

            body = HTMLNormalizer.rewriteLinks(
                in: body,
                section: section,
                sectionIndexByPath: sectionIndexByPath,
                resources: book.resources,
                // Only Markdown has the switch; an EPUB/MOBI page never fetches a
                // remote image, whatever the reader allowed for Markdown.
                allowRemoteImages: book.format == .markdown && options.allowNetworkImages
            )

            // Split books (Calibre/Sigil) target the chapter file's `<body id="…">`;
            // keep that anchor alive in the merged page.
            var bodyAnchor = ""
            if let bodyID = section.bodyID, !bodyID.isEmpty {
                bodyAnchor = "<span class=\"anchor-target\" id=\"ch\(index)--\(HTMLNormalizer.escapeHTML(bodyID))\"></span>"
            }
            sectionsHTML += "\n<section class=\"chapter\" id=\"ch\(index)\">\n\(bodyAnchor)\(body)\n</section>\n"
        }

        // The declared TOC is the publisher's own list, but it is not always the more useful
        // one - a book can declare twelve files while marking hundreds of headings inside
        // them - so a backend that marks its list as a fallback lets the heading derivation
        // take over when that yields more. Measured both ways: 267 entries from headings
        // against 28 declared, and 383 against 12; and the other way round, 314 declared
        // against a single heading for a book whose only heading is its "Contents" title,
        // where the declaration must win.
        let derived = tocTree(from: headings)
        let entries: [TOCEntry]
        if book.tocIsFallback && count(derived) > count(book.toc) {
            entries = derived
        } else if book.toc.isEmpty {
            entries = derived
        } else {
            entries = book.toc
        }

        let sidebar = renderSidebar(
            entries: entries,
            sectionIndexByPath: sectionIndexByPath,
            title: options.tocTitle,
            truncated: book.truncatedAt,
            totalBytes: book.contentBytes,
            tocNote: book.tocNote,
            autoFold: options.autoFoldTOC
        )

        // Only a markdown book resolves a concrete scheme and tags the root with it. An
        // EPUB/MOBI page gets no attribute at all, so its stylesheet keeps following
        // `prefers-color-scheme` exactly as before (see `resolvedTheme`).
        //
        // `data-format` is the other half: every format-specific content rule in
        // ReaderAssets.css is scoped under it, so a rule written for one format cannot touch
        // another. Markdown carries it beside `data-theme`; an FB2 page carries `data-format`
        // only, because it has no theme of its own to force.
        let formatAttribute: String
        switch book.format {
        case .markdown: formatAttribute = " data-format=\"markdown\""
        case .fb2: formatAttribute = " data-format=\"fb2\""
        default: formatAttribute = ""
        }
        let themeAttribute = book.format == .markdown
            ? " data-theme=\"\(resolvedTheme(options.theme))\"\(formatAttribute)"
            : formatAttribute

        let html = """
        <!doctype html>
        <html\(themeAttribute)>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>\(HTMLNormalizer.escapeHTML(book.metadata.title ?? book.url.lastPathComponent))</title>
            <style>\(ReaderAssets.css)</style>
        </head>
        <body class="\(sidebar == nil ? "no-toc" : "")">
            \(sidebar ?? "")
            <div id="content">\(sectionsHTML)</div>
            <script>window.__ql = \(injectedState(options));</script>
            <script>\(ReaderAssets.js)</script>
        </body>
        </html>
        """
        return (html: html, baseURL: nil)
    }

    // MARK: - Sidebar

    /// The fixed sidebar, or nil when the book has neither a table of contents nor
    /// anything else to say. A book without a sidebar must not be pushed right by
    /// one - that is what the `no-toc` body class is for.
    private static func renderSidebar(
        entries: [TOCEntry],
        sectionIndexByPath: [String: Int],
        title: String,
        truncated: Int?,
        totalBytes: Int?,
        tocNote: String?,
        autoFold: Bool
    ) -> String? {
        let list = renderList(entries, sectionIndexByPath: sectionIndexByPath)

        var note = ""
        if let truncated {
            let shown = Double(truncated) / 1_048_576.0
            let total = Double(totalBytes ?? truncated) / 1_048_576.0
            note = "<div class=\"toc-note\">Truncated preview: showing the first "
                + String(format: "%.0f", shown) + " MB of " + String(format: "%.0f", total) + " MB.</div>"
        }
        // Whatever the reader has to be told about the entries themselves - that they were
        // guessed from the text, for instance. Never silently: a derived list that looks like
        // the book's own structure is the one thing this must not be.
        if let tocNote, !tocNote.isEmpty {
            note += "<div class=\"toc-note\">\(HTMLNormalizer.escapeHTML(tocNote))</div>"
        }
        guard !list.isEmpty || !note.isEmpty else { return nil }

        let heading = HTMLNormalizer.escapeHTML(title)
        return """
        <nav id="toc" aria-label="Contents">
            <div id="toc-head">
                <span>\(heading)</span>
                <span id="toc-zoom">
                    <button id="zoom-out" type="button" title="Smaller text">A−</button>
                    <button id="zoom-level" type="button" title="Back to 100%">100%</button>
                    <button id="zoom-in" type="button" title="Larger text">A+</button>
                </span>
                <button id="toc-fold-toggle" type="button" title="Fold all">▸▸</button>
                <button id="toc-fold-follow" type="button" aria-pressed="\(autoFold)"
                        title="Auto-fold contents: \(autoFold ? "on" : "off")"></button>
                <button id="toc-hide" type="button" title="Hide">‹</button>
            </div>
            <div id="toc-scroll">
                \(note)
                <ul class="toc-list">\(list)</ul>
            </div>
        </nav>
        <div id="toc-resizer" role="separator" aria-orientation="vertical" title="Drag to resize"></div>
        <button id="toc-show" type="button" title="Show">\(heading)</button>
        """
    }

    private static func renderList(_ entries: [TOCEntry], sectionIndexByPath: [String: Int]) -> String {
        var out = ""
        for entry in entries {
            let children = renderList(entry.children, sectionIndexByPath: sectionIndexByPath)
            let label = HTMLNormalizer.escapeHTML(entry.title)

            let title: String
            if let href = resolve(entry.target, sectionIndexByPath: sectionIndexByPath) {
                title = "<a href=\"\(href)\">\(label)</a>"
            } else {
                title = "<span class=\"toc-label\">\(label)</span>"
            }

            let cssClass = children.isEmpty ? "toc-item" : "toc-item has-children"
            let toggle = children.isEmpty
                ? ""
                : "<button class=\"toc-toggle\" type=\"button\" title=\"Fold / unfold\"></button>"
            out += "<li class=\"\(cssClass)\">\(toggle)\(title)"
                + (children.isEmpty ? "" : "<ul class=\"toc-list\">\(children)</ul>") + "</li>"
        }
        return out
    }

    /// Maps a TOC target onto an in-page anchor.
    private static func resolve(_ target: BookTarget?, sectionIndexByPath: [String: Int]) -> String? {
        guard let target else { return nil }
        let fragment = target.fragment

        // No document: a heading-derived entry, whose anchor is already namespaced.
        guard let path = target.sectionPath else {
            guard let fragment, !fragment.isEmpty else { return nil }
            return "#\(fragment)"
        }
        guard let index = sectionIndexByPath[path] else { return nil }
        if let fragment, !fragment.isEmpty { return "#ch\(index)--\(fragment)" }
        return "#ch\(index)"
    }

    // MARK: - Headings -> tree

    /// Every entry in the tree, children included - so two tables of contents can be
    /// compared by how much they actually offer.
    private static func count(_ entries: [TOCEntry]) -> Int {
        entries.reduce(0) { $0 + 1 + count($1.children) }
    }

    /// Turns document-ordered headings into a nested table of contents by level.
    private static func tocTree(from headings: [HTMLNormalizer.HeadingEntry]) -> [TOCEntry] {
        var index = 0
        return buildEntries(headings, &index, level: 1)
    }

    private static func buildEntries(
        _ headings: [HTMLNormalizer.HeadingEntry],
        _ index: inout Int,
        level: Int
    ) -> [TOCEntry] {
        var out: [TOCEntry] = []
        while index < headings.count {
            let heading = headings[index]
            if heading.level < level { break }
            index += 1
            let children = buildEntries(headings, &index, level: heading.level + 1)
            out.append(TOCEntry(
                title: heading.title,
                target: BookTarget(sectionPath: nil, fragment: heading.anchor),
                children: children
            ))
        }
        return out
    }

    // MARK: - Fallback pages

    /// Self-contained page for a file no backend could open.
    public static func placeholderHTML(fileName: String, options: Options = Options()) -> String {
        page(title: fileName, body: """
        <div class="notice">
            <h1>No reader for this file yet</h1>
            <p>EBookQL does not have a preview backend for this file type yet.</p>
            <p class="file">\(HTMLNormalizer.escapeHTML(fileName))</p>
        </div>
        """, options: options)
    }

    /// A page explaining why a book could not be previewed.
    public static func noticeHTML(
        summary: String,
        detail: String,
        fileName: String,
        options: Options = Options()
    ) -> String {
        page(title: summary, body: """
        <div class="notice">
            <h1>\(HTMLNormalizer.escapeHTML(summary))</h1>
            <p>\(HTMLNormalizer.escapeHTML(detail))</p>
            <p class="file">\(HTMLNormalizer.escapeHTML(fileName))</p>
        </div>
        """, options: options)
    }

    private static func page(title: String, body: String, options: Options) -> String {
        """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>\(HTMLNormalizer.escapeHTML(title))</title>
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; }
            body { font: -apple-system-body; line-height: 1.6; background: #f7f7f8; color: #1c1c1e; }
            @media (prefers-color-scheme: dark) { body { background: #202022; color: #e8e8ea; } }
            main { padding: 48px 40px; }
            .stub { margin-top: 2em; opacity: .5; font-size: .85em; }
            .notice { max-width: 34em; margin: 0 auto; padding: 22px 26px;
                      border: 1px solid rgba(128,128,128,.35); border-radius: 10px;
                      background: rgba(128,128,128,.07); }
            .notice h1 { font-size: 17px; margin: 0 0 10px; }
            .notice p { margin: 0 0 8px; opacity: .85; }
            .notice .file { font-size: 12.5px; opacity: .6; word-break: break-all; }
            </style>
        </head>
        <body>
            <main>\(body)</main>
            <script>window.__ql = \(injectedState(options));</script>
        </body>
        </html>
        """
    }

    // MARK: - Internals

    /// A `.system` choice has to leave here as one concrete scheme, because the page
    /// decides dark/light itself from the attribute and the media query. The preview
    /// resolves it against its own appearance and passes the result down; the kit has
    /// no AppKit, so an unresolved `.system` falls back to light.
    private static func resolvedTheme(_ theme: MarkdownTheme) -> String {
        switch theme {
        case .light: return "light"
        case .dark: return "dark"
        case .system: return "light"
        }
    }

    private static func injectedState(_ options: Options) -> String {
        var dict: [String: Any] = [
            "zoom": options.zoom,
            "theme": resolvedTheme(options.theme),
            "jsParse": options.markdownRendering,
            "lineNumbers": options.showLineNumbers,
            "autoFoldTOC": options.autoFoldTOC,
        ]
        if let width = options.sidebarWidth { dict["sidebarWidth"] = width }
        if let position = options.readingPosition {
            var payload: [String: Any] = [
                "sectionOffset": position.sectionOffset,
                "fraction": position.fraction,
                "scrollY": position.scrollY,
            ]
            if let anchor = position.anchor { payload["anchor"] = anchor }
            dict["position"] = payload
        } else {
            dict["position"] = NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
