//
//  FB2Document.swift
//  EBookQLKit
//
//  One pass over a FictionBook document: `XMLParser` in, HTML out.
//
//  The interesting part of FB2 is that it is a *tree with no list*: sections nest, and a
//  `<title>` inside a section is the only thing that says where a reader can jump to. So
//  titles become `<h1>`-`<h3>` and the renderer's own heading derivation builds the sidebar;
//  nothing here has to invent anchors, and every chapter gets a real one for the reading
//  position.
//
//  Everything else is a translation table: FB2's paragraph/poem/table/epigraph vocabulary
//  into the elements the reader already styles. `<binary>` elements are not content - they
//  are collected by id and served to the page on demand.
//

import Foundation

final class FB2Document: NSObject, XMLParserDelegate {

    struct Result {
        var metadata: BookMetadata
        var html: String
        var binaries: [String: FB2Image]
        var coverID: String?
        /// Bytes of base64 that came with the file, so the sidebar can say how much of it
        /// was not text when the book had to be cut.
        var binaryBytes: Int
        var sections: Int
        var truncated: Bool
        /// True when the contents had to be guessed from the text (see `promotedContents`).
        var guessedContents: Bool
        var guessedEntries: Int
    }

    // MARK: - Entry point

    static func parse(
        _ text: String,
        markupLimit: Int,
        binaryLimit: Int,
        stopAfterFirstSection: Bool = false,
        contentsFromText: Bool = false
    ) throws -> Result {
        let document = FB2Document(markupLimit: markupLimit, binaryLimit: binaryLimit,
                                   stopAfterFirstSection: stopAfterFirstSection,
                                   contentsFromText: contentsFromText)
        let parser = XMLParser(data: Data(declarationNormalized(sanitizedEntities(in: text)).utf8))
        parser.delegate = document
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        document.parser = parser

        let ok = parser.parse()
        // Stopping early is deliberate (`abortParsing`); a document that simply fell over is
        // not, and neither is a file whose XML is broken. Those get the notice page instead
        // of a half-rendered book.
        guard ok || document.aborted else { throw BookParseError.malformed }
        guard !document.parseFailed else { throw BookParseError.malformed }
        return document.result()
    }

    /// The string handed to `XMLParser` is UTF-8 by construction, whatever the file was. Its
    /// XML declaration still names the *file's* encoding, though - and the parser believes it,
    /// decodes these bytes as windows-1251 and hands back mojibake (measured: a Russian 1251
    /// fixture came out as "РўРµСЃС‚РѕРІР°СЏ"). So the declaration is rewritten to match what is
    /// actually being parsed, and a leading BOM goes with it.
    static func declarationNormalized(_ text: String) -> String {
        var value = text
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }

        guard let open = value.range(of: "<?xml"), let close = value.range(of: "?>", range: open.upperBound..<value.endIndex) else {
            return value
        }
        let declaration = value[open.upperBound..<close.lowerBound]
        guard let attribute = declaration.range(of: "encoding") else { return value }

        let rest = declaration[attribute.upperBound...]
        guard let openQuote = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return value }
        let body = rest[rest.index(after: openQuote)...]
        guard let closeQuote = body.firstIndex(of: rest[openQuote]) else { return value }

        return String(value[value.startIndex..<attribute.upperBound])
            + "=\"UTF-8\""
            + String(body[body.index(after: closeQuote)...])
            + String(value[close.lowerBound...])
    }

    /// HTML entities that XML does not define, which is most of the ones an FB2 file written
    /// from HTML-ish sources carries. `&nbsp;` alone is enough to make `XMLParser` refuse a
    /// whole book, so the handful that actually turns up is mapped to numeric references -
    /// which XML does define - before parsing. The five XML built-ins are left alone.
    private static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165,
        "brvbar": 166, "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171,
        "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176, "plusmn": 177,
        "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183,
        "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "times": 215, "divide": 247, "mdash": 8212,
        "ndash": 8211, "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221,
        "bull": 8226, "hellip": 8230, "dagger": 8224, "Dagger": 8225, "permil": 8240,
        "lsaquo": 8249, "rsaquo": 8250, "euro": 8364, "trade": 8482, "larr": 8592,
        "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596, "minus": 8722,
        "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805,
    ]

    static func sanitizedEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        let xmlBuiltins: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
        return text.replacingOccurrences(of: "&([a-zA-Z][a-zA-Z0-9]{1,9});") { _, matched in
            let name = String(matched.dropFirst().dropLast())
            guard !xmlBuiltins.contains(name) else { return matched }
            guard let code = htmlEntities[name] ?? htmlEntities[name.lowercased()] else { return matched }
            return "&#\(code);"
        }
    }

    // MARK: - State

    private let markupLimit: Int
    private let binaryLimit: Int
    private let stopAfterFirstSection: Bool

    private var out = ""
    private var metadata = BookMetadata()
    private var binaries: [String: FB2Image] = [:]
    private var binaryBytes = 0
    private var coverID: String?
    private var sections = 0
    private var truncated = false
    /// Set only by this document's own early stop, so a genuinely broken file cannot be
    /// mistaken for a deliberate one.
    private var aborted = false
    private var parseFailed = false
    private weak var parser: XMLParser?

    private var inDescription = false
    private var inBinary = false
    private var binaryID: String?
    private var binaryMime: String?
    private var binaryText = ""

    private var inBody = false
    private var bodyCount = 0
    private var sectionDepth = 0
    private var paragraphDepth = 0
    /// Elements whose subtree is dropped whole (stylesheets, and anything a future FB2
    /// revision adds next to them).
    private var skipping = 0
    /// Non-zero while inside an element that is quoted rather than laid out: a title inside
    /// a poem or a cite is not a chapter heading and must not become one.
    private var quoting = 0

    private var inTitle = false
    private var titleParagraphs = 0

    private var field: String?
    private var fieldText = ""
    private var authorParts: [String] = []
    /// Which part of `<description>` is being read - `title-info`, `document-info`, … - so a
    /// field is only taken from where it means what we want it to mean.
    private var descriptionSection: String?
    /// How many `<title>` elements the document has. Zero is what allows the contents to be
    /// guessed from the text at all.
    private var titles = 0
    private let contentsFromText: Bool

    /// A section as it is written: where it starts in `out`, how deep it is, how many ordinary
    /// paragraphs it holds and where its first one begins. A converted file keeps all of this
    /// even when every `<title>` element was dropped, which is what tells a guessed chapter
    /// title (the section's first paragraph) from a guessed subheading - and what gives a flat
    /// file a tree at all.
    private struct SectionMark {
        var start: Int
        var depth: Int
        var paragraphs = 0
        var firstParagraph: Int?
    }
    /// Written in document order, so the innermost section holding an offset is the last one
    /// that starts at or before it.
    private var sectionMarks: [SectionMark] = []
    /// Indices into `sectionMarks` of the sections that are still open.
    private var openSections: [Int] = []
    /// Where the paragraph being written began, for the first-paragraph rule above.
    private var paragraphStart: Int?

    private init(markupLimit: Int, binaryLimit: Int, stopAfterFirstSection: Bool, contentsFromText: Bool) {
        self.markupLimit = markupLimit
        self.binaryLimit = binaryLimit
        self.stopAfterFirstSection = stopAfterFirstSection
        self.contentsFromText = contentsFromText
    }

    private func result() -> Result {
        var html = out
        var guessed = false
        var entries = 0
        // Only ever for a file that carries no structure of its own. A book with `<title>`
        // elements keeps exactly the contents its author gave it - nothing guessed is mixed in.
        if contentsFromText, titles == 0 {
            (html, entries) = Self.promotedContents(html, sections: sectionMarks)
            guessed = entries > 0
        }
        return Result(metadata: metadata, html: html, binaries: binaries, coverID: coverID,
                      binaryBytes: binaryBytes, sections: sections, truncated: truncated,
                      guessedContents: guessed, guessedEntries: entries)
    }

    // MARK: - Elements

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if inBinary { return }
        if skipping > 0 { skipping += 1; return }
        let element = Self.local(name)
        guard !inDescription else { return describe(element, attributes) }
        guard inBody else {
            // Outside the bodies: the description, the binaries, and FB2's stylesheet links.
            switch element {
            case "description": inDescription = true
            case "binary": startBinary(attributes)
            case "stylesheet": skipping = 1
            case "body":
                bodyCount += 1
                inBody = true
                // Only the first body is the book. A second one is the notes (or a second
                // volume): it stays in the same section, behind a rule, because a note link
                // has to land in the same section for its anchor to survive.
                if bodyCount > 1 { out += "<div class=\"fb2-body-break\"></div>" }
            default: break
            }
            return
        }
        emit(element, attributes)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBinary { binaryText += string; return }
        guard skipping == 0 else { return }
        if inDescription { fieldText += string; return }
        guard inBody else { return }
        out += HTMLNormalizer.escapeHTML(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        if inBinary {
            if Self.local(name) == "binary" { finishBinary() }
            return
        }
        if skipping > 0 { skipping -= 1; return }
        let element = Self.local(name)
        if inDescription {
            if element == "description" { inDescription = false } else { describeEnd(element) }
            return
        }
        guard inBody else { return }
        if element == "body" { inBody = false; return }
        close(element)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // `abortParsing` reports itself as a failure too; only an error we did not ask for
        // makes the document unreadable.
        if !aborted { parseFailed = true }
    }

    // MARK: - <description>

    private static let metadataFields: Set<String> = [
        "book-title", "lang", "id", "first-name", "middle-name", "last-name", "nickname",
    ]

    /// The description is metadata only - nothing in it is part of the page (the cover image
    /// included: the reader draws its own card).
    ///
    /// Which part of it a field is read from matters: `title-info` carries the book's own
    /// title, author and language, while `document-info` carries the *file's* author - the
    /// person or program that made the file. Measured on the sample book, where reading both
    /// put "Sanchez, Cesar" in the byline twice.
    private func describe(_ element: String, _ attributes: [String: String]) {
        switch element {
        case "title-info", "document-info", "publish-info", "src-title-info", "custom-info":
            descriptionSection = element
            return
        case "coverpage":
            coverID = nil
            return
        case "image":
            if let href = Self.href(attributes) { coverID = String(href.drop { $0 == "#" }) }
            return
        case "author":
            authorParts = []
            return
        default:
            break
        }
        guard Self.metadataFields.contains(element) else { return }
        if element == "id" {
            guard descriptionSection == "document-info" else { return }
        } else if descriptionSection != "title-info" {
            return
        }
        field = element
        fieldText = ""
    }

    private func describeEnd(_ element: String) {
        if element == descriptionSection { descriptionSection = nil }
        if element == "author" {
            // Only the book's own author. A `<author>` in `document-info` is whoever made the
            // file, and the byline is not the place for them.
            guard descriptionSection == "title-info" else { return }
            let parts = authorParts.filter { !$0.isEmpty }
            if !parts.isEmpty {
                let name = parts.joined(separator: " ")
                metadata.author = metadata.author.map { $0 + ", " + name } ?? name
            }
            return
        }
        guard element == field else { return }
        let value = HTMLNormalizer.collapsedText(fieldText)
        field = nil
        fieldText = ""
        guard !value.isEmpty else { return }

        switch element {
        case "book-title": metadata.title = value
        case "lang": metadata.language = value
        case "id": metadata.identifier = value
        case "first-name", "middle-name", "last-name", "nickname": authorParts.append(value)
        default: break
        }
    }

    // MARK: - <binary>

    private func startBinary(_ attributes: [String: String]) {
        inBinary = true
        binaryID = attributes["id"]
        binaryMime = attributes["content-type"]
        binaryText = ""
    }

    private func finishBinary() {
        inBinary = false
        defer { binaryID = nil; binaryMime = nil; binaryText = "" }
        guard let id = binaryID, !id.isEmpty, binaryLimit > 0 else { return }
        guard binaryBytes < binaryLimit else { return }

        let payload = binaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = payload.utf8.count
        guard !payload.isEmpty else { return }
        binaryBytes += size
        binaries[id] = FB2Image(mimeType: binaryMime, base64: payload)
    }

    // MARK: - Markup

    /// Falls back to the body's first paragraph when a book has no title at all: an untitled
    /// preview is worse than a rough one.
    private func emit(_ element: String, _ attributes: [String: String]) {
        switch element {
        case "section":
            sectionDepth += 1
            sections += 1
            sectionMarks.append(SectionMark(start: out.utf16.count, depth: sectionDepth))
            openSections.append(sectionMarks.count - 1)
            out += "<div class=\"fb2-section\"\(Self.idAttribute(attributes))>"
        case "title":
            titles += 1
            titleParagraphs = 0
            inTitle = true
            out += quoting > 0
                ? "<p class=\"fb2-minor-title\">"
                : "<h\(titleLevel)>"
        case "subtitle":
            out += "<p class=\"fb2-subtitle\"\(Self.idAttribute(attributes))>"
        case "p":
            if inTitle {
                titleParagraphs += 1
                if titleParagraphs > 1 { out += "<br>" }
            } else {
                paragraphDepth += 1
                paragraphStart = out.utf16.count
                out += "<p\(Self.idAttribute(attributes))>"
            }
        case "v":
            paragraphDepth += 1
            out += "<p class=\"fb2-verse\"\(Self.idAttribute(attributes))>"
        case "empty-line":
            // A line of vertical space. Inside a paragraph it has to be a `<br>`, or the
            // browser closes the paragraph to hold a block element.
            out += (inTitle || paragraphDepth > 0) ? "<br>" : "<div class=\"fb2-empty-line\"></div>"
        case "emphasis": out += "<em>"
        case "strong": out += "<strong>"
        case "strikethrough": out += "<del>"
        case "sub", "sup", "code": out += "<\(element)>"
        case "style": out += "<span class=\"fb2-style\">"
        case "a":
            let note = attributes["type"] == "note"
            let href = Self.href(attributes) ?? ""
            // In-book targets stay BARE (`#n1`): the renderer prefixes every id and every
            // same-document fragment in a section with that section's index, so spelling the
            // namespace here too would produce `ch0--ch0--n1` (see HTMLNormalizer).
            out += "<a class=\"\(note ? "fb2-note-ref" : "fb2-link")\" href=\"\(HTMLNormalizer.escapeHTML(href))\""
            if let title = attributes["title"] { out += " title=\"\(HTMLNormalizer.escapeHTML(title))\"" }
            out += ">"
        case "image":
            guard let id = Self.href(attributes)?.drop(while: { $0 == "#" }), !id.isEmpty else { return }
            let source = "\(BookResourceScheme.name)://\(FB2ResourceProvider.prefix)\(Self.encode(String(id)))"
            // FB2 gives an image `alt`, `title` and `id` (the last one is a link target, so it
            // has to survive into the page like any other anchor).
            out += paragraphDepth > 0 ? "<img src=\"\(source)\"" : "<img class=\"fb2-image\" src=\"\(source)\""
            out += " alt=\"\(HTMLNormalizer.escapeHTML(attributes["alt"] ?? ""))\""
            if let title = attributes["title"] { out += " title=\"\(HTMLNormalizer.escapeHTML(title))\"" }
            out += Self.idAttribute(attributes) + ">"
        case "epigraph", "cite":
            quoting += 1
            out += "<blockquote class=\"fb2-\(element)\"\(Self.idAttribute(attributes))>"
        case "poem":
            quoting += 1
            out += "<div class=\"fb2-poem\"\(Self.idAttribute(attributes))>"
        case "stanza": out += "<div class=\"fb2-stanza\">"
        case "annotation":
            quoting += 1
            out += "<div class=\"fb2-annotation\"\(Self.idAttribute(attributes))>"
        case "text-author": out += "<p class=\"fb2-text-author\">"
        case "table": out += "<table\(Self.idAttribute(attributes))>"
        case "tr": out += "<tr>"
        case "td", "th": out += "<td\(Self.cellAttributes(attributes))>"
        default: break
        }
    }

    private func close(_ element: String) {
        switch element {
        case "section":
            out += "</div>"
            sectionDepth = max(0, sectionDepth - 1)
            _ = openSections.popLast()
            if sectionDepth == 0 { checkLimits() }
        case "title":
            out += quoting > 0 ? "</p>" : "</h\(titleLevel)>"
            inTitle = false
        case "subtitle": out += "</p>"
        case "p":
            if inTitle { break }
            // The section this paragraph belongs to is the innermost one still open.
            if let start = paragraphStart, let section = openSections.last {
                sectionMarks[section].paragraphs += 1
                if sectionMarks[section].firstParagraph == nil {
                    sectionMarks[section].firstParagraph = start
                }
            }
            paragraphStart = nil
            paragraphDepth = max(0, paragraphDepth - 1)
            out += "</p>"
        case "v":
            paragraphDepth = max(0, paragraphDepth - 1)
            out += "</p>"
        case "emphasis": out += "</em>"
        case "strong": out += "</strong>"
        case "strikethrough": out += "</del>"
        case "sub", "sup", "code": out += "</\(element)>"
        case "style": out += "</span>"
        case "a": out += "</a>"
        case "epigraph", "cite", "poem", "annotation":
            quoting = max(0, quoting - 1)
            out += element == "poem" ? "</div>" : "</blockquote>"
        case "stanza": out += "</div>"
        case "text-author": out += "</p>"
        case "table": out += "</table>"
        case "tr": out += "</tr>"
        case "td", "th": out += "</td>"
        default: break
        }
    }

    /// The heading level for the section being written: one deeper per enclosing section,
    /// capped where the renderer stops looking (see `titleLevelLimit`).
    private var titleLevel: Int {
        min(max(sectionDepth, 1), FB2Backend.titleLevelLimit)
    }

    /// Stops a book that is longer than anyone wants to lay out - at a section boundary, so
    /// the last section is not left half a page. Also where a thumbnail parse stops, after the
    /// first section, because Finder asks for a folder's worth of them at once.
    private func checkLimits() {
        if stopAfterFirstSection {
            aborted = true
        } else if out.utf8.count > markupLimit {
            truncated = true
            aborted = true
        }
        guard aborted else { return }
        parser?.abortParsing()
    }

    // MARK: - Guessed contents

    /// A paragraph short enough to be a heading, with the section it sits in.
    private struct Candidate {
        let range: NSRange
        let attributes: String
        let inner: String
        /// `inner` with its tags stripped, lowercased: what the entry would be called, computed
        /// once because every tier compares it.
        let label: String
        /// Index into `SectionMark`s, or nil for text outside every section.
        let section: Int?
    }

    /// Turns paragraphs that read like headings into real ones, so the renderer's own heading
    /// derivation can build a sidebar for a book whose `<title>` elements are all missing.
    ///
    /// The file's own section boundaries are the spine, because they are the one piece of
    /// structure a converter cannot flatten away - every FB2 file has them, titles or not:
    ///
    /// 1. A section's **first paragraph** is that section's title, at the level its `<title>`
    ///    would have had. Measured on `sample.fb2` (13 equal sections, 0 titles): all ten of its
    ///    chapters open with exactly that line, so the tree comes out two levels deep, which is
    ///    the book's own shape.
    /// 2. A paragraph that **names its own level** ("Part II …", "Chapter 4 …", "Appendix",
    ///    "Глава 1", "Kapitel 3") is a heading at that level. This is what carries a book whose
    ///    sections are few and huge: 《AI for Physics》has three sections of ~2000 paragraphs,
    ///    one of them a flattened table of contents.
    /// 3. Failing both, a paragraph that is **nothing but one bold run** is a subheading - looked
    ///    at only once 1-2 found fewer than three entries, because the same files bold their
    ///    series lists and author names too (205 such paragraphs in the measured book).
    ///
    /// The callers only run this for a file with no `<title>` at all, and the reader is told the
    /// result was guessed (`Book.tocNote`).
    private static func promotedContents(_ html: String, sections: [SectionMark]) -> (html: String, entries: Int) {
        let candidates = paragraphCandidates(in: html, sections: sections)
        let contentsSections = contentsLikeSections(candidates, sections)

        var seen: Set<String> = []
        var edits: [(range: NSRange, text: String)] = []
        var deferred: [Candidate] = []
        var named = 0
        var sectionTitles = 0

        // 1. Each section's own title. The only tier that is not reading the text for meaning -
        //    it is the file's structure - which is why it runs first and why what it finds
        //    decides how the two text tiers below are used.
        for candidate in candidates {
            guard let section = candidate.section.map({ sections[$0] }),
                  section.firstParagraph == candidate.range.location, section.paragraphs >= 3,
                  !candidate.label.isEmpty, passesCommonGuards(candidate.label, limit: titleLengthLimit),
                  seen.insert(candidate.label).inserted else { continue }
            let level = min(max(section.depth, 1), FB2Backend.titleLevelLimit)
            edits.append((candidate.range, heading(level: level, attributes: candidate.attributes, inner: candidate.inner)))
            named += 1
            sectionTitles += 1
        }

        // A file whose sections carry titles does not need its table of contents read as headings:
        // those lines point at the entries above and would duplicate every one of them (measured on
        // `sample.fb2`, whose contents page is ten bold chapter titles). A file whose sections
        // carry none has nothing else - 《AI for Physics》is three 2000-paragraph sections and one
        // flattened outline, so that outline *is* its structure.
        let readsContentsBlocks = sectionTitles < 3

        // 2. A paragraph that names its own level.
        for candidate in candidates {
            if let section = candidate.section, contentsSections.contains(section), !readsContentsBlocks { continue }
            guard !candidate.label.isEmpty, let level = guessedLevel(label: candidate.label),
                  seen.insert(candidate.label).inserted else { continue }
            edits.append((candidate.range, heading(level: level, attributes: candidate.attributes, inner: candidate.inner)))
            named += 1
        }

        // 3. Everything still spare is a candidate for the bold tier, whose gate is the count
        //    tier 2 produced (tier 1's entries are structure, not evidence either way). The bold
        //    test is made here rather than for every paragraph, since this tier usually does not
        //    run at all.
        for candidate in candidates {
            if let section = candidate.section, contentsSections.contains(section), !readsContentsBlocks { continue }
            guard !candidate.label.isEmpty, !seen.contains(candidate.label),
                  isOneBoldRun(candidate.inner) else { continue }
            deferred.append(candidate)
        }
        if named - sectionTitles < 3 {
            for candidate in deferred {
                guard seen.insert(candidate.label).inserted else { continue }
                edits.append((candidate.range, heading(level: 2, attributes: candidate.attributes, inner: candidate.inner)))
            }
        }

        // Applied back to front so the ranges stay valid: the section lookups above are in the
        // coordinates of the unedited document, and a String rewritten as we go would shift them.
        let out = NSMutableString(string: html)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.text)
        }
        return (out as String, edits.count)
    }

    private static func heading(level: Int, attributes: String, inner: String) -> String {
        "<h\(level)\(attributes)>\(inner)</h\(level)>"
    }

    /// Every paragraph short enough to be a heading, in document order, with the section it sits
    /// in. Paragraphs the backend already styled (`<p class="fb2-…">`: subtitles, verses, a
    /// quotation's author) are skipped - the book's structure is not written there.
    private static func paragraphCandidates(in html: String, sections: [SectionMark]) -> [Candidate] {
        let source = html as NSString
        let found = paragraphPattern.matches(in: html, range: NSRange(location: 0, length: source.length))
        var out: [Candidate] = []
        out.reserveCapacity(found.count)
        for match in found {
            guard match.numberOfRanges >= 3 else { continue }
            let attributes = source.substring(with: match.range(at: 1))
            guard !attributes.contains("class=\"fb2-") else { continue }
            let inner = source.substring(with: match.range(at: 2))
            out.append(Candidate(
                range: match.range,
                attributes: attributes,
                inner: inner,
                label: HTMLNormalizer.collapsedText(inner).lowercased(),
                section: sectionIndex(at: match.range.location, in: sections)
            ))
        }
        return out
    }

    /// The innermost section containing `offset`: the last one that starts at or before it, since
    /// a nested section always starts after its parent.
    private static func sectionIndex(at offset: Int, in sections: [SectionMark]) -> Int? {
        var low = 0
        var high = sections.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if sections[mid].start <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Sections that *are* a table of contents ("Contents", "Document Outline", "Оглавление").
    /// Their lines are references to the real headings, so promoting them duplicates the whole
    /// tree - measured on `sample.fb2`, whose contents page is ten bold lines that would otherwise
    /// double every chapter entry. Only honoured once the sections themselves gave titles: in
    /// 《AI for Physics》the flattened contents *is* the book's structure and the only thing there
    /// is to read.
    private static func contentsLikeSections(_ candidates: [Candidate], _ sections: [SectionMark]) -> Set<Int> {
        var out: Set<Int> = []
        for candidate in candidates {
            guard let index = candidate.section,
                  sections[index].firstParagraph == candidate.range.location else { continue }
            if contentsTitles.contains(HTMLNormalizer.collapsedText(candidate.inner).lowercased()) {
                out.insert(index)
            }
        }
        return out
    }

    private static let contentsTitles: Set<String> = [
        "contents", "table of contents", "document outline", "оглавление", "содержание",
    ]

    /// A whole paragraph, tags and all, up to the length a heading can be. Longer paragraphs are
    /// prose and simply do not match - which is also what keeps this affordable on a big book.
    private static let paragraphPattern = try! NSRegularExpression(
        pattern: #"<p([^>]*)>(.{2,240}?)</p>"#, options: [.dotMatchesLineSeparators]
    )

    /// How the converters in circulation mark a heading once the `<title>` element is gone: the
    /// paragraph is one bold run and nothing else.
    private static func isOneBoldRun(_ text: String) -> Bool {
        matches(boldOnlyPattern, HTMLNormalizer.collapsedText(text))
    }

    private static let boldOnlyPattern = try! NSRegularExpression(
        pattern: #"^\s*<(strong|emphasis)>.{2,80}</(strong|emphasis)>\s*$"#
    )

    /// The heading level a paragraph's own text claims, or nil. A part is a top level entry and
    /// everything else sits under it, which is the shape these books have. `label` is the
    /// caller's already-collapsed text, so this does no string work of its own.
    static func guessedLevel(label: String) -> Int? {
        guard passesCommonGuards(label, limit: headingLengthLimit) else { return nil }
        for (pattern, level) in headingPatterns where matches(pattern, label) { return level }
        return nil
    }

    /// Where the text itself is the evidence, a heading is short: "Chapter 6." and "Chapter 8)."
    /// are cross-references to a chapter, not headings, and a sentence is prose. That is what
    /// these limits are for; the section-title tier has its own, looser one above.
    private static let headingLengthLimit = 80
    private static let titleLengthLimit = 140

    private static func passesCommonGuards(_ value: String, limit: Int) -> Bool {
        guard value.count >= 3, value.count <= limit else { return false }
        guard let last = value.last, !".,;".contains(last) else { return false }
        guard !value.contains("http"), !value.contains("@"), !value.contains("://") else { return false }
        guard !matches(runningHeadPattern, value) else { return false }
        // "Epilogue 113", "Appendix 12": a front/back-matter word *followed by nothing but a
        // number* is the page's running head, while the bare word is the section itself. Measured
        // on the real book, which has both.
        return !matches(numberedRunningHeadPattern, value)
    }

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    /// Level per pattern. Language-specific on purpose: the format is Russian in origin, but most
    /// files in the wild are English or German conversions, and a book in another language simply
    /// gets no guess rather than a wrong one.
    private static let headingPatterns: [(NSRegularExpression, Int)] = [
        (#"(?i)^(part|teil|часть|книга|том)\s+([ivxlc]+|\d+)\b"#, 1),
        (#"(?i)^(chapter|kapitel|глава|раздел)\s+[\dIVXLC]+[.:)]?\s*\S"#, 2),
        (#"(?i)^(appendix|preface|foreword|prologue|epilogue|introduction|conclusion|afterword|glossary|bibliography|references|notes|index|приложение|предисловие|заключение|примечания)\b"#, 2),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// "References 23" is a running head, not a heading, and one of them sits at the top of
    /// almost every chapter in a converted book.
    private static let runningHeadPattern = try! NSRegularExpression(
        pattern: #"(?i)^(references|notes|index|contents|bibliography|оглавление|содержание|примечания)\s*\d*$"#
    )

    /// The same shape, for the words that also name a real section: the bare word stays, the
    /// numbered one goes.
    private static let numberedRunningHeadPattern = try! NSRegularExpression(
        pattern: #"(?i)^(references|notes|index|contents|bibliography|epilogue|prologue|appendix|glossary|примечания|содержание|оглавление)\s+\d+$"#
    )

    // MARK: - Attributes

    private static func idAttribute(_ attributes: [String: String]) -> String {
        guard let id = attributes["id"], !id.isEmpty else { return "" }
        return " id=\"\(HTMLNormalizer.escapeHTML(id))\""
    }

    private static func cellAttributes(_ attributes: [String: String]) -> String {
        var out = idAttribute(attributes)
        for name in ["colspan", "rowspan", "align"] {
            if let value = attributes[name], !value.isEmpty {
                out += " \(name)=\"\(HTMLNormalizer.escapeHTML(value))\""
            }
        }
        return out
    }

    /// `l:href` is the spelling the schema mandates (xlink), `href` the one files in the wild
    /// also use, and the prefix itself is free - so any attribute whose local name is `href`.
    private static func href(_ attributes: [String: String]) -> String? {
        for (key, value) in attributes where local(key) == "href" {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func local(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name.lowercased() }
        return String(name[name.index(after: colon)...]).lowercased()
    }

    /// Ids are free-form (`img_0`, `cover.jpg`, and in a Russian book a Cyrillic one), so
    /// they are escaped for the URL - keeping the characters a path may hold so the spelling
    /// stays recognisable in the reader's hover strip.
    private static let pathCharacters = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/%?#"))

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? value
    }
}
