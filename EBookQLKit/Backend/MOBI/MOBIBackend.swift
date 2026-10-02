//
//  MOBIBackend.swift
//  EBookQLKit
//
//  MOBI / AZW / AZW3 (Kindle) -> Book.
//
//  The parsing engine is libmobi (C, vendored under Vendor/libmobi) - there is no
//  realistic pure-Swift replacement for it. Everything above that - what counts as a
//  chapter, how the table of contents is built, how the page is rendered - is the
//  same shared code the EPUB backend feeds, which is what makes the two formats look
//  identical in the preview.
//
//  A MOBI book arrives as one long XHTML flow rather than a set of spine documents,
//  so it becomes a single section and the renderer derives the table of contents from
//  the headings (`Book.toc` is left empty on purpose).
//

import Foundation
import MobiLib
import os.log

public final class MOBIBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["mobi", "azw", "azw3"]

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "MOBI")

    /// Keep a generous prefix of the text and say so in the sidebar rather than
    /// looking broken: a 27-volume bundle is 35 MB of reconstructed markup and would
    /// take the renderer seconds and gigabytes.
    private static let contentLimit = 8 * 1024 * 1024

    /// Same ceiling the renderer puts on a heading-derived list, so one pathological
    /// container cannot hand the sidebar tens of thousands of rows.
    private static let tocEntryLimit = 800

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory

        let started = Date()

        // The shim owns the libmobi lifetime; nothing libmobi-shaped escapes it.
        var status: Int32 = 0
        let handle: OpaquePointer? = url.withUnsafeFileSystemRepresentation { path -> OpaquePointer? in
            guard let path else { return nil }
            return MobiBookOpen(path, &status)
        }
        guard let handle else { throw error(for: status) }
        // The handle outlives this call: the page asks for images long after the preview
        // is built. The resource provider takes ownership of it, and the Book holds the
        // provider, so the container is released when the preview goes away.
        var handedOver = false
        defer { if !handedOver { MobiBookClose(handle) } }

        let title = string(MobiBookTitle(handle))
        let author = string(MobiBookAuthor(handle))
        let entries = tableOfContents(handle)
        // Anchors go in before the markup is cleaned up: the positions are byte offsets
        // into this very text. The container's own links are resolved in the same pass.
        let text = prepareMarkup(try content(handle), entries: entries, handle: handle)
        let body = stripScaffolding(text)
        let (content, shownBytes) = truncate(body)
        // A long book is cut short, and an entry pointing past the cut has no anchor left.
        // When nothing was cut, every anchor is known to be in there.
        let live = shownBytes == nil ? nil : anchorsPresent(in: content)
        let provider = MOBIResourceProvider(handle: handle)
        handedOver = true
        let toc = tree(entries, live: live)

        os_log("parsed in %.2fs | %{public}d chars of markup | %{public}d resources | toc %{public}d entries, %{public}d with a position",
               log: log, type: .info,
               Date().timeIntervalSince(started), text.count,
               MobiBookResourceCount(handle), entries.count,
               entries.filter { $0.offset != nil }.count)
        if let live {
            os_log("truncated at %{public}d bytes: %{public}d of %{public}d toc anchors survived",
                   log: log, type: .info, shownBytes ?? 0,
                   live.filter { $0.hasPrefix("toc") }.count, entries.count)
        }

        return Book(
            url: url,
            format: format(for: url),
            metadata: BookMetadata(title: title, author: author),
            sections: [BookSection(id: sectionID, html: content)],
            toc: toc,
            tocBasePath: nil,
            resources: provider,
            truncatedAt: shownBytes,
            contentBytes: text.utf8.count,
            tocIsFallback: true
        )
    }

    // MARK: - Table of contents

    /// MOBI books are a single section, and the renderer namespaces every id in a section
    /// with that section's index - so an anchor called `toc3` in the markup becomes
    /// `ch0--toc3` in the page.
    private static let sectionID = "ch0"
    private static let chapterPrefix = "ch0--"

    /// One NCX entry, still flat (the NCX lists them in order, each with a rank and a link
    /// to its parent).
    private struct FlatTOCEntry {
        let title: String
        /// The container's rank for this entry - a category, not a depth (see `tree`).
        let rank: Int
        /// Byte offset into the book's markup this entry points at, when it names one.
        let offset: Int?
        /// Index of this entry's parent in the same list, when it has one.
        let parent: Int?
    }

    /// The container's own NCX table of contents.
    ///
    /// An entry carries a position, not an anchor, so one is planted in the markup for
    /// each (`prepareMarkup`) and the entry points at it. This stays a fallback: the
    /// heading derivation reads the text itself and yields finer entries, so it wins
    /// wherever a book has headings at all.
    private static func tableOfContents(_ handle: OpaquePointer) -> [FlatTOCEntry] {
        let count = Int(MobiBookTocCount(handle))
        guard count > 0 else { return [] }

        var flat: [FlatTOCEntry] = []
        flat.reserveCapacity(min(count, tocEntryLimit))
        for index in 0..<min(count, tocEntryLimit) {
            var title: UnsafeMutablePointer<CChar>?
            var rank: UInt32 = 0
            var offset: Int = -1
            var parent: Int32 = -1
            let ok = MobiBookTocEntry(handle, UInt32(index), &title, &rank, &offset, &parent)
            defer { if let title { MobiBookFreeString(title) } }

            // Every index is kept, even a useless one: `parent` refers to this list, so
            // dropping an entry would re-point every entry below it.
            guard ok != 0 else {
                flat.append(FlatTOCEntry(title: "", rank: 0, offset: nil, parent: nil))
                continue
            }
            let text = title.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            flat.append(FlatTOCEntry(title: text, rank: Int(rank),
                                     offset: offset >= 0 ? offset : nil,
                                     parent: parent >= 0 ? Int(parent) : nil))
        }
        return flat
    }

    /// Plants an invisible anchor at each byte offset given.
    ///
    /// Built in one pass over the bytes: the offsets are byte positions in this same
    /// markup, so slicing bytes (rather than converting each one to a String index) both
    /// keeps them valid and cannot split a multi-byte character.
    private static func injectAnchors(at anchors: [Int: String], into text: String) -> String {
        guard !anchors.isEmpty else { return text }

        let bytes = Array(text.utf8)
        // Grouped, because two targets can settle on the same byte - and each still needs
        // an anchor of its own or it would be a dead link.
        var byPosition: [Int: [String]] = [:]
        for (offset, name) in anchors {
            byPosition[anchorPosition(for: offset, in: bytes), default: []].append(name)
        }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count + anchors.count * 40)
        var cursor = 0
        for position in byPosition.keys.sorted() {
            let offset = min(max(position, cursor), bytes.count)
            out.append(contentsOf: bytes[cursor..<offset])
            for name in (byPosition[position] ?? []).sorted() {
                out.append(contentsOf: Array("<a id=\"\(name)\" class=\"anchor-target\"></a>".utf8))
            }
            cursor = offset
        }
        out.append(contentsOf: bytes[cursor...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Where to plant the anchor for a target at `offset`.
    ///
    /// The container's offsets point into element contents, so a byte can land inside a
    /// tag - and an `<a>` spliced into the middle of `class="calibre_4"` is read as part of
    /// the attribute value and swallowed by the parser, leaving a dead entry (measured:
    /// only 48 of 291 survived that way). Snapping back to just after the previous `>`
    /// puts the anchor in front of the element the target sits in, which is also the
    /// position worth scrolling to. A KF7 offset already lands on a `<`, so it is left
    /// alone.
    private static func anchorPosition(for offset: Int, in bytes: [UInt8]) -> Int {
        let clamped = min(max(offset, 0), bytes.count)
        guard clamped < bytes.count, bytes[clamped] != UInt8(ascii: "<") else { return clamped }
        var index = clamped
        let limit = max(0, clamped - 512)
        while index > limit {
            index -= 1
            if bytes[index] == UInt8(ascii: ">") { return index + 1 }
        }
        return clamped
    }

    // MARK: - The container's own links

    /// Plants an anchor wherever the sidebar or the container's own links point, and points
    /// those links at the anchors.
    ///
    /// One function, because both refer to byte positions in this same markup - and because
    /// the anchors have to be in before the markup is cleaned up.
    private static func prepareMarkup(_ raw: String, entries: [FlatTOCEntry],
                                      handle: OpaquePointer) -> String {
        // Offset -> anchor name. The table of contents goes first, so its names win where an
        // in-book link points at the same place.
        var anchors: [Int: String] = [:]
        for (position, entry) in entries.enumerated() {
            guard let offset = entry.offset else { continue }
            anchors[offset] = anchorName(position)
        }
        for offset in inBookLinks(in: raw, handle: handle) where anchors[offset] == nil {
            anchors[offset] = "link\(anchors.count)"
        }

        var markup = injectAnchors(at: anchors, into: raw)

        // The links themselves. Safe to rewrite after the anchors are in, because an anchor
        // is planted between tags (see anchorPosition) and so cannot split a reference.
        //
        // These are written as bare `#name`: the renderer prefixes every id and every
        // same-document fragment in a chapter with that chapter's index (prefixAnchors), so
        // spelling the namespace here too would produce `ch0--ch0--name`. The sidebar's own
        // targets are not part of the chapter markup, so those carry the prefix already.
        markup = markup.replacingOccurrences(
            of: "kindle:pos:fid:[0-9A-Za-z]{4}:off:[0-9A-Za-z]{10}"
        ) { _, matched in
            guard let offset = resolvePosfid(matched, handle: handle),
                  let name = anchors[offset] else { return matched }
            return "#\(name)"
        }
        markup = markup.replacingOccurrences(of: "filepos=(\\d{1,12})") { _, matched in
            guard let value = Int(matched.drop { $0 != "=" }.dropFirst()),
                  let name = anchors[value] else { return matched }
            // KF7 writes the position as an attribute on a link, so it becomes the href.
            return "href=\"#\(name)\""
        }
        return markup
    }

    /// Every position the container's own in-book links point at, as byte offsets.
    ///
    /// KF8 writes `kindle:pos:fid:XXXX:off:YYYYYYYYYY`; KF7 writes an unquoted
    /// `filepos=NNNNNNNNNN`. Both resolve through the same mapping the sidebar uses.
    private static func inBookLinks(in text: String, handle: OpaquePointer) -> [Int] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var offsets: [Int] = []

        for match in RegexCache.regex("kindle:pos:fid:[0-9A-Za-z]{4}:off:[0-9A-Za-z]{10}")
            .matches(in: text, range: whole) {
            if let offset = resolvePosfid(source.substring(with: match.range), handle: handle) {
                offsets.append(offset)
            }
        }
        for match in RegexCache.regex("filepos=(\\d{1,12})").matches(in: text, range: whole) {
            if let value = Int(source.substring(with: match.range(at: 1))) { offsets.append(value) }
        }
        return offsets
    }

    /// Resolves a `kindle:pos:fid:XXXX:off:YYYYYYYYYY` reference to a byte offset, or nil.
    private static func resolvePosfid(_ reference: String, handle: OpaquePointer) -> Int? {
        guard let marker = reference.range(of: ":off:") else { return nil }
        let fid = String(reference[reference.index(marker.lowerBound, offsetBy: -4)..<marker.lowerBound])
        let off = String(reference[marker.upperBound...].prefix(10))
        let value = fid.withCString { f in
            off.withCString { o in MobiBookTextOffsetForPosfid(handle, f, o) }
        }
        return value >= 0 ? Int(value) : nil
    }

    private static func anchorName(_ position: Int) -> String { "toc\(position)" }

    /// Which planted anchors actually made it into the rendered markup.
    ///
    /// Only consulted for a book that was cut short. An entry pointing past the cut would
    /// be a dead link, so it keeps its title and loses its target.
    private static func anchorsPresent(in content: String) -> Set<String> {
        var found: Set<String> = []
        let source = content as NSString
        let whole = NSRange(location: 0, length: source.length)
        for match in RegexCache.regex("<a id=\"((?:toc|link)\\d+)\"").matches(in: content, range: whole) {
            found.insert(source.substring(with: match.range(at: 1)))
        }
        return found
    }

    /// Builds the tree the container describes, from its own parent links.
    ///
    /// The rank it gives each entry is a *category*, not a depth: this book lists all 24
    /// parts before any of its 272 chapters, so nesting by rank - which is right for the
    /// heading derivation, where the listed order really is a tree walk - would hang every
    /// chapter off the last part. The NCX carries parent links (`INDX_TAG_NCX_PARENT`), and
    /// those are what this follows.
    ///
    /// An entry with no title (the container has some) is spliced out - its children
    /// promoted to its parent - rather than dropped, which would take its subtree with it.
    private static func tree(_ entries: [FlatTOCEntry], live: Set<String>?) -> [TOCEntry] {
        var children: [[Int]] = Array(repeating: [], count: entries.count)
        var roots: [Int] = []
        for (position, entry) in entries.enumerated() {
            // A parent always precedes its children, which is also what keeps a malformed
            // list from recursing forever.
            if let parent = entry.parent, parent >= 0, parent < position {
                children[parent].append(position)
            } else {
                roots.append(position)
            }
        }

        func node(_ position: Int) -> [TOCEntry] {
            let entry = entries[position]
            let kids = children[position].flatMap(node)
            guard !entry.title.isEmpty else { return kids }
            return [TOCEntry(title: entry.title,
                             target: target(position, entry, live: live),
                             children: kids)]
        }
        return roots.flatMap(node)
    }

    /// Where an entry points: the anchor planted for it, in the spelling the renderer
    /// resolves. An entry the container gave no position for - or one whose anchor the
    /// truncation removed - is left without a target, and the renderer draws that as a
    /// plain label rather than a dead link.
    private static func target(_ position: Int, _ entry: FlatTOCEntry,
                               live: Set<String>?) -> BookTarget? {
        guard entry.offset != nil else { return nil }
        let name = anchorName(position)
        if let live, !live.contains(name) { return nil }
        return BookTarget(sectionPath: nil, fragment: chapterPrefix + name)
    }

    // MARK: - libmobi

    private static func format(for url: URL) -> BookFormat {
        switch url.pathExtension.lowercased() {
        case "azw": return .azw
        case "azw3": return .azw3
        default: return .mobi
        }
    }

    /// MobiShim* status -> the shared parse errors. The shim keeps libmobi's own
    /// distinction, so "encrypted" can be told apart from "corrupt" and the panel can
    /// say something useful instead of showing nothing.
    private static func error(for status: Int32) -> BookParseError {
        switch status {
        case Int32(MobiShimEncrypted): return .encrypted
        case Int32(MobiShimUnsupported): return .unsupportedFormat
        case Int32(MobiShimCorrupt): return .corrupt
        default: return .io
        }
    }

    /// Takes ownership of a string the shim allocated and releases it immediately.
    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { MobiBookFreeString(pointer) }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The whole book's reconstructed markup.
    private static func content(_ handle: OpaquePointer) throws -> String {
        var status: Int32 = 0
        guard let pointer = MobiBookContent(handle, &status) else { throw error(for: status) }
        defer { MobiBookFreeString(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Markup clean-up

    /// rawml is several XHTML parts concatenated, so the scaffolding is removed rather
    /// than a single body extracted: the first `<body>` can be empty and content
    /// continues after the first `</body></html>`.
    static func stripScaffolding(_ html: String) -> String {
        var content = html

        // <head> blocks carry only kindle:flow: stylesheet references, which cannot be
        // resolved outside the container. There is one per concatenated document and a
        // KF8 book can carry hundreds of them (245 measured here), so this has to be a
        // single pass: removing them one at a time rescans the whole book on every
        // iteration and goes quadratic - 813 KB took 10 s that way, 0.04 s this way.
        content = drop("<head\\b[^>]{0,400}>[\\s\\S]*?</head\\s*>", in: content)
        // A <head that never closes: everything from it on is scaffolding.
        if let head = content.range(of: "<head", options: [.caseInsensitive]) {
            content.removeSubrange(head.lowerBound..<content.endIndex)
        }

        content = drop("</?(?:html|body)\\b[^>]*>|<\\?xml[^>]*\\?>|<!DOCTYPE[^>]*>", in: content)
        // Images are resolved while their references are still in the container's own
        // spelling; whatever of the sort is left after that (a stylesheet link, say) is
        // dropped rather than left for WebKit to fail on.
        content = resolveImages(in: content)
        content = drop("<(?:link|img)\\b[^>]*kindle:[^>]*>", in: content)
        return content
    }

    // MARK: - Embedded images

    /// Rewrites every spelling of an embedded image into a URL the scheme handler can
    /// serve. MOBI names its images three ways and none of them is fetchable:
    ///
    ///     KF8   `<img src="kindle:embed:0001?mime=image/jpg">`  (and SVG `<image>`)
    ///     KF7   `<img recindex="00013">`                         (no src at all)
    ///     and libmobi's own rewritten form, `src="resource00042.jpg"`
    ///
    /// All three resolve to one 0-based resource id. The ids are decoded by the shim,
    /// which uses libmobi's own base32 reader rather than a second implementation.
    static func resolveImages(in html: String) -> String {
        var content = html

        // KF8. The `?mime=` query goes with it: it is only there because the container
        // said so, and the shim knows each record's real type.
        content = content.replacingOccurrences(of: "kindle:embed:([0-9A-Za-z]{4})(\\?[^\"\\s>]*)?") { _, matched in
            guard let fid = token(in: matched, after: "kindle:embed:", length: 4) else { return matched }
            var uid: UInt32 = 0
            guard fid.withCString({ MobiBookResourceUidFromEmbed($0, &uid) }) != 0 else { return matched }
            return Self.resourceURL(uid: Int(uid))
        }

        // KF7. Decimal and 1-based, and there is no src to replace - swapping the whole
        // attribute for one is the fix.
        content = content.replacingOccurrences(of: "recindex=\"(\\d{1,6})\"") { _, matched in
            guard let value = number(in: matched, after: "recindex=\""), value > 0 else { return matched }
            return "src=\"\(Self.resourceURL(uid: value - 1))\""
        }

        // libmobi's rewritten spelling, when it got there first. Already 0-based.
        content = content.replacingOccurrences(of: "resource(\\d{5})\\.[A-Za-z0-9]{1,5}") { _, matched in
            guard let value = number(in: matched, after: "resource") else { return matched }
            return Self.resourceURL(uid: value)
        }

        return content
    }

    /// The scheme handler's spelling for one embedded image.
    static func resourceURL(uid: Int) -> String {
        "\(BookResourceScheme.name):///mobi/\(uid)"
    }

    /// Reads the run of digits following `prefix` ("resource00042.jpg" -> 42).
    private static func number(in value: String, after prefix: String) -> Int? {
        guard let range = value.range(of: prefix) else { return nil }
        return Int(value[range.upperBound...].prefix { $0.isNumber })
    }

    /// The fixed-length token following `prefix` ("kindle:embed:0006?mime=…" -> "0006").
    private static func token(in value: String, after prefix: String, length: Int) -> String? {
        guard let range = value.range(of: prefix) else { return nil }
        let rest = value[range.upperBound...]
        guard rest.count >= length else { return nil }
        return String(rest.prefix(length))
    }

    private static func drop(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
        )
    }

    /// Cuts an over-long book at a heading, so the last section is not half a page.
    /// Returns the content and the byte count it was cut at (nil when nothing was cut).
    private static func truncate(_ text: String) -> (content: String, shownBytes: Int?) {
        guard text.utf8.count > contentLimit else { return (text, nil) }
        let cut = text.index(text.startIndex, offsetBy: contentLimit)
        let windowStart = text.index(cut, offsetBy: -4000, limitedBy: text.startIndex) ?? text.startIndex
        if let heading = text.range(of: "<h", options: [.backwards], range: windowStart..<cut) {
            return (String(text[text.startIndex..<heading.lowerBound]), contentLimit)
        }
        return (String(text[text.startIndex..<cut]), contentLimit)
    }
}

/// Serves the images embedded in a MOBI container to the preview's scheme handler.
///
/// It holds the libmobi handle, because the page reads images long after the backend
/// returns - and releases it when the preview goes away, which is the only moment the
/// container can be closed.
public final class MOBIResourceProvider: ResourceProvider {

    private let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        MobiBookClose(handle)
    }

    /// References are rewritten ahead of time (`resolveImages`), so there is nothing
    /// left for the renderer to resolve. It is here only because a provider also has to
    /// be able to say what a reference turns into.
    public func url(for path: String, relativeTo base: String?) -> String? {
        nil
    }

    /// Paths look like `/mobi/<id>`, where the id is the same 0-based resource id that
    /// `kindle:embed:` and `recindex` resolve to.
    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "mobi",
              let uid = UInt32(components[1]) else { return nil }

        var bytes: UnsafeMutablePointer<UInt8>?
        var mime = [CChar](repeating: 0, count: 64)
        let size = mime.withUnsafeMutableBufferPointer { buffer in
            MobiBookResource(handle, uid, &bytes, buffer.baseAddress, buffer.count)
        }
        guard let bytes, size > 0 else { return nil }

        let type = String(cString: mime)
        return (Data(bytes: bytes, count: size), type.isEmpty ? nil : type)
    }
}
