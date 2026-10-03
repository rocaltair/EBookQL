//
//  HTMLNormalizer.swift
//  EBookQLKit
//
//  Turns one chapter's HTML into something that survives being merged into a
//  single page: anchors get a per-chapter prefix, cross-file links become in-page
//  jumps, and resources become URLs the preview can actually load.
//
//  Ported from the EPUB Quick Look extension, keeping the fixes that were needed
//  on real books: percent-decoded hrefs, the `<body id="…">` target kept alive,
//  and capture-group ranges rebased before use.
//

import Foundation

public enum HTMLNormalizer {

    // MARK: - Body

    /// The content between `<body …>` and `</body>`, plus the body element's own id
    /// (split books link to it).
    public static func extractBody(_ html: String) -> (content: String, bodyID: String?) {
        guard let start = html.range(of: "<body", options: [.caseInsensitive]),
              let gt = html[start.lowerBound...].firstIndex(of: ">"),
              let end = html.range(of: "</body>", options: [.caseInsensitive]),
              gt < end.lowerBound
        else { return (html, nil) }

        let tag = String(html[start.lowerBound...gt])
        var bodyID: String?
        if let regex = try? NSRegularExpression(pattern: "id\\s*=\\s*[\"']([^\"']+)[\"']") {
            let ns = tag as NSString
            if let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                bodyID = ns.substring(with: match.range(at: 1))
            }
        }
        return (String(html[html.index(after: gt)..<end.lowerBound]), bodyID)
    }

    // MARK: - Anchors

    /// Prefixes ids, legacy `<a name>` anchors and same-document fragments with the
    /// chapter index, so a merged page keeps unique ids and `#foo` links keep working.
    public static func prefixAnchors(in html: String, chapter: Int) -> String {
        var out = html

        out = out.replacingOccurrences(of: "([\\s\"'])id=\"([^\"]+)\"") { match, matched in
            let ns = matched as NSString
            let capture = rangeWithinMatch(match.range(at: 2), match.range)
            guard capture.length > 0 else { return matched }
            return ns.replacingCharacters(in: capture, with: "ch\(chapter)--\(ns.substring(with: capture))")
        }

        out = out.replacingOccurrences(of: "([\\s\"'])id='([^']+)'") { match, matched in
            let ns = matched as NSString
            let capture = rangeWithinMatch(match.range(at: 2), match.range)
            guard capture.length > 0 else { return matched }
            return ns.replacingCharacters(in: capture, with: "ch\(chapter)--\(ns.substring(with: capture))")
        }

        // <a name="x"> is a legacy anchor target; carry a prefixed id alongside it.
        out = out.replacingOccurrences(of: "<a\\s[^>]*name\\s*=\\s*([\"'])([^\"']+)\\1[^>]*>") { match, matched in
            let ns = matched as NSString
            guard match.numberOfRanges > 2 else { return matched }
            let valueRange = rangeWithinMatch(match.range(at: 2), match.range)
            guard valueRange.length > 0 else { return matched }
            let prefixed = "ch\(chapter)--\(ns.substring(with: valueRange))"
            var tag = ns.replacingCharacters(in: valueRange, with: prefixed)
            if !tag.lowercased().contains("id=") {
                tag = "<a id=\"\(prefixed)\"" + tag.dropFirst(2)
            }
            return tag
        }

        for quote in ["\"", "'"] {
            out = out.replacingOccurrences(of: "href=\(quote)#([^\(quote)]*)\(quote)") { match, matched in
                let ns = matched as NSString
                let capture = rangeWithinMatch(match.range(at: 1), match.range)
                guard capture.length > 0 else { return matched }
                return ns.replacingCharacters(in: capture, with: "ch\(chapter)--\(ns.substring(with: capture))")
            }
        }

        return out
    }

    // MARK: - Links and resources

    /// Rewrites `src` / `href`: a link to another spine document becomes an in-page
    /// anchor, and every other local reference becomes the URL its resource provider
    /// hands back (a file URL, or the archive scheme). A remote image is replaced by
    /// a placeholder unless `allowRemoteImages` says the reader asked for it.
    public static func rewriteLinks(
        in html: String,
        section: BookSection,
        sectionIndexByPath: [String: Int],
        resources: ResourceProvider?,
        allowRemoteImages: Bool = false
    ) -> String {
        var out = html
        for attribute in ["src", "href", "poster"] {
            // One pattern for the three attributes: a raw string keeps it free of
            // escapes, and the attribute name is spliced in.
            let pattern = #"ATTRIBUTE="([^"]+)""#
                .replacingOccurrences(of: "ATTRIBUTE", with: attribute)
            out = out.replacingOccurrences(of: pattern) { match, matched in
                let ns = matched as NSString
                let capture = rangeWithinMatch(match.range(at: 1), match.range)
                guard capture.length > 0 else { return matched }
                let raw = ns.substring(with: capture).replacingOccurrences(of: "&amp;", with: "&")
                guard let replacement = resolveReference(
                    raw, attribute: attribute, section: section,
                    sectionIndexByPath: sectionIndexByPath, resources: resources,
                    allowRemoteImages: allowRemoteImages
                ) else { return matched }
                return ns.replacingCharacters(in: capture, with: replacement)
            }
        }
        return out
    }

    private static func resolveReference(
        _ value: String,
        attribute: String,
        section: BookSection,
        sectionIndexByPath: [String: Int],
        resources: ResourceProvider?,
        allowRemoteImages: Bool
    ) -> String? {
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        let lower = value.lowercased()
        // A remote image is never fetched unless the reader asked for it: a preview
        // that quietly opens a network connection is not a default anyone opted into
        // (and a plain-http one is refused by App Transport Security besides). A
        // remote `href` is left alone - clicking a link is an explicit act, and the
        // reader's browser is what opens it, not the preview.
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || value.hasPrefix("//") {
            guard attribute != "href" else { return nil }
            return allowRemoteImages ? nil : blockedImage(imageAt: value)
        }
        let external = ["file:", "data:", "mailto:", "tel:", "javascript:", "blob:"]
        guard !external.contains(where: { lower.hasPrefix($0) }) else { return nil }
        // A bare fragment is handled by prefixAnchors.
        let (path, fragment) = BookPath.splitFragment(value)
        guard !path.isEmpty else { return nil }

        let normalized = BookPath.normalize(path, relativeTo: section.basePath)
        if attribute == "href", let index = sectionIndexByPath[normalized] {
            let suffix = BookPath.decodedFragment(fragment).map { "--\($0)" } ?? ""
            return "#ch\(index)\(suffix)"
        }
        guard let url = resources?.url(for: value, relativeTo: section.basePath) else { return nil }
        if let fragment, !fragment.isEmpty, !url.hasPrefix("data:") {
            return "\(url)#\(fragment)"
        }
        return url
    }

    /// Stands in for a remote image that was not fetched. Clearing the `src` would
    /// leave nothing at all, and WebKit's broken-image glyph reads as "this preview
    /// is broken" - so the block says what it is, and which host was not contacted.
    /// Single quotes inside the SVG, a plain concatenation outside it: no escape has
    /// to survive two layers of string literals.
    static func blockedImage(imageAt value: String) -> String {
        let parsable = value.hasPrefix("//") ? "https:" + value : value
        let host = URL(string: parsable)?.host ?? ""
        let label = host.isEmpty ? "Network image blocked" : "Network image blocked: " + escapeHTML(host)
        let note = "Turn network images on in EBookQL settings"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='360' height='76'>"
            + "<rect width='360' height='76' rx='8' fill='rgba(128,128,128,.12)'/>"
            + "<rect x='6.5' y='6.5' width='347' height='63' rx='6' fill='none'"
            + " stroke='rgba(128,128,128,.5)' stroke-dasharray='6 4'/>"
            + "<text x='180' y='38' text-anchor='middle' font-family='-apple-system,Helvetica,sans-serif'"
            + " font-size='13' fill='#88888c'>" + label + "</text>"
            + "<text x='180' y='56' text-anchor='middle' font-family='-apple-system,Helvetica,sans-serif'"
            + " font-size='11' fill='#9a9a9e'>" + note + "</text>"
            + "</svg>"
        let encoded = svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "data:image/svg+xml;charset=utf-8," + encoded
    }

    // MARK: - Headings -> TOC

    public struct HeadingEntry: Sendable {
        public let level: Int
        public let title: String
        public let anchor: String
    }

    /// Walks the headings of one chapter, gives each an id (unless it already has
    /// one) and returns them in document order. This is what gives MOBI books - and
    /// EPUBs without a nav or NCX - a sidebar.
    public static func injectHeadingAnchors(
        in html: String,
        chapter: Int,
        startingIndex: Int,
        limit: Int
    ) -> (html: String, entries: [HeadingEntry], nextIndex: Int) {
        let ns = html as NSString
        let matches = headingRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var entries: [HeadingEntry] = []
        var insertions: [(location: Int, text: String)] = []
        var index = startingIndex

        for match in matches {
            if entries.count >= limit { break }
            guard match.numberOfRanges >= 4 else { continue }

            let levelText = ns.substring(with: match.range(at: 1))
            guard let level = Int(levelText) else { continue }
            let title = collapsedText(ns.substring(with: match.range(at: 3)))
            guard !title.isEmpty else { continue }

            let attributes = ns.substring(with: match.range(at: 2))
            let existing = idAttributeRegex.firstMatch(
                in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))

            // Ids are already namespaced by prefixAnchors (which runs first), so an
            // existing id is used as-is; otherwise mint one for this chapter.
            let local: String
            if let existing, existing.numberOfRanges > 1 {
                local = (attributes as NSString).substring(with: existing.range(at: 1))
            } else {
                local = "ch\(chapter)--h\(index)"
                let openTagLength = 3 + (ns.substring(with: match.range(at: 2)) as NSString).length + 1
                let insertAt = match.range(at: 0).location + openTagLength - 1
                insertions.append((location: insertAt, text: " id=\"\(local)\""))
            }
            entries.append(HeadingEntry(level: level, title: title, anchor: local))
            index += 1
        }

        var out = html
        for insertion in insertions.sorted(by: { $0.location > $1.location }) {
            guard insertion.location <= (out as NSString).length else { continue }
            out = (out as NSString).replacingCharacters(
                in: NSRange(location: insertion.location, length: 0), with: insertion.text)
        }
        return (out, entries, index)
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: "<h([1-3])([^>]{0,400})>(.{0,600}?)</h\\1\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let idAttributeRegex = try! NSRegularExpression(
        pattern: "\\bid\\s*=\\s*[\"']([^\"'<>]{1,200})[\"']",
        options: [.caseInsensitive]
    )

    // MARK: - Text

    /// Single-line, tag-free, entity-decoded text (heading labels, thumbnails).
    public static func collapsedText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let text = NSMutableString(string: html)
        replace(text, pattern: "<[^>]+>", template: " ")
        decodeCommonEntities(in: text)
        replace(text, pattern: "[\\u00AD\\u200B-\\u200F\\uFEFF]", template: "")
        replace(text, pattern: "\\s+", template: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func decodeCommonEntities(in text: NSMutableString) {
        let entities: [String: String] = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&mdash;": "\u{2014}",
            "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&rsquo;": "\u{2019}",
            "&lsquo;": "\u{2018}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        ]
        for (entity, replacement) in entities {
            text.replaceOccurrences(of: entity, with: replacement, options: [.caseInsensitive],
                                    range: NSRange(location: 0, length: text.length))
        }
        replace(text, pattern: "&[a-zA-Z]+;|&#[0-9]+;", template: "")
    }

    private static func replace(_ text: NSMutableString, pattern: String, template: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        regex.replaceMatches(in: text, range: NSRange(location: 0, length: text.length), withTemplate: template)
    }

    // MARK: - Regex plumbing

    /// The replacement closures receive the *matched substring*, but a capture
    /// group's range is expressed in the coordinates of the whole document - rebase
    /// it, or `replacingCharacters(in:)` throws on every match past offset 0.
    static func rangeWithinMatch(_ capture: NSRange, _ match: NSRange) -> NSRange {
        guard capture.location != NSNotFound, match.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: capture.location - match.location, length: capture.length)
    }
}

/// Compiled-pattern cache: the same handful of patterns is applied to every
/// chapter (hundreds of them in big books), so compiling per call is pure overhead.
enum RegexCache {
    private static var storage: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[pattern] { return cached }
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        storage[pattern] = regex
        return regex
    }
}

extension String {
    /// Single-pass regex replace with a closure. Builds the result once, so it is
    /// O(n) and - unlike an in-place replace with a running UTF-16 delta - cannot
    /// drift out of bounds on multi-byte text.
    func replacingOccurrences(of pattern: String, with transform: (_ match: NSTextCheckingResult, _ matched: String) -> String) -> String {
        let regex = RegexCache.regex(pattern)
        let source = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return self }

        var parts: [String] = []
        parts.reserveCapacity(matches.count * 2 + 1)
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                parts.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            parts.append(transform(match, source.substring(with: match.range)))
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            parts.append(source.substring(from: cursor))
        }
        return parts.joined()
    }
}
