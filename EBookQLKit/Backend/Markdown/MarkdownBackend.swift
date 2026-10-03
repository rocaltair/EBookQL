//
//  MarkdownBackend.swift
//  EBookQLKit
//
//  Markdown (.md / .markdown / .mdx) -> Book.
//
//  The other backends parse containers; this one parses prose. The whole file is
//  one section, and the table of contents is left empty on purpose: the renderer
//  derives it from the headings, which marked has already given GitHub-style ids
//  so markdown `[x](#slug)` links survive the reader's anchor prefixing.
//
//  The file is read as text and converted with `MarkdownRenderer`; nothing is
//  unpacked to disk. YAML front matter, when present, only feeds the metadata -
//  the body is rendered without it.
//

import Foundation

public final class MarkdownBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["md", "markdown", "mdx"]

    /// One section: the whole document.
    private static let sectionID = "md"

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        try open(url, workDirectory: workDirectory, markdownRendering: true)
    }

    /// With `markdownRendering == false` the parse and the metadata are unchanged,
    /// but the one section carries the document's raw source in a
    /// `<pre class="markdown-source">` block instead of the JavaScript-rendered
    /// HTML - the JavaScriptCore call is skipped entirely.
    public static func open(_ url: URL, workDirectory: URL, markdownRendering: Bool) throws -> Book {
        _ = workDirectory

        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw BookParseError.io }
        // Markdown is overwhelmingly UTF-8; Latin-1 keeps a stray legacy file
        // readable rather than failing the whole preview.
        guard let markdown = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw BookParseError.io
        }

        let frontMatter = parseFrontMatter(markdown)

        let html: String
        if markdownRendering {
            do { html = try MarkdownRenderer.html(from: frontMatter.body) }
            catch { throw BookParseError.malformed }
        } else {
            html = "<pre class=\"markdown-source\">"
                + HTMLNormalizer.escapeHTML(frontMatter.body)
                + "</pre>"
        }

        // Front matter's title wins, then the document's own first <h1>, then the
        // file name - the card has to say something.
        let title = frontMatter.title
            ?? firstHeadingText(in: html)
            ?? url.deletingPathExtension().lastPathComponent

        let section = BookSection(
            id: sectionID,
            html: html,
            basePath: "",
            sourcePath: url.lastPathComponent,
            bodyID: nil,
            title: title
        )

        return Book(
            url: url,
            format: .markdown,
            metadata: BookMetadata(title: title, author: frontMatter.author),
            sections: [section],
            toc: [],
            tocBasePath: nil,
            // Relative images are siblings of the .md file; the provider serves them
            // from its folder over ekbres://.
            resources: MarkdownResourceSource(baseDirectory: url.deletingLastPathComponent()),
            truncatedAt: nil,
            contentBytes: markdown.utf8.count,
            // No declared list, but not a fallback either: the renderer derives the
            // sidebar from the headings marked emitted, which are always clickable.
            tocIsFallback: false
        )
    }

    // MARK: - Front matter

    private struct FrontMatter {
        let body: String
        let title: String?
        let author: String?
    }

    /// Splits an optional leading `---\n…\n---` YAML block off the document and
    /// reads `title` / `author` out of it. Anything richer than `key: value` lines
    /// is ignored rather than parsed; when the block never closes, the document is
    /// left whole so a stray `---` is not mistaken for front matter.
    private static func parseFrontMatter(_ markdown: String) -> FrontMatter {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return FrontMatter(body: markdown, title: nil, author: nil)
        }

        var title: String?
        var author: String?
        var closing: Int?
        var index = 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closing = index
                break
            }
            if let colon = lines[index].firstIndex(of: ":") {
                let key = lines[index][lines[index].startIndex..<colon]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = unquoted(String(lines[index][lines[index].index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces))
                if key == "title", !value.isEmpty { title = value }
                if key == "author", !value.isEmpty { author = value }
            }
            index += 1
        }

        guard let closing else { return FrontMatter(body: markdown, title: nil, author: nil) }
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return FrontMatter(body: body, title: title, author: author)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Title

    /// The rendered document's first `<h1>` as plain text. Matching the rendered
    /// HTML (rather than the markdown) is what makes headings written as setext or
    /// wrapped in emphasis resolve to the same words the reader shows.
    private static func firstHeadingText(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<h1\\b[^>]*>(.*?)</h1\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: html)
        else { return nil }

        let text = HTMLNormalizer.collapsedText(String(html[range]))
        return text.isEmpty ? nil : text
    }
}
