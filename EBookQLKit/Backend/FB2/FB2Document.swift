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
    }

    // MARK: - Entry point

    static func parse(
        _ text: String,
        markupLimit: Int,
        binaryLimit: Int,
        stopAfterFirstSection: Bool = false
    ) throws -> Result {
        let document = FB2Document(markupLimit: markupLimit, binaryLimit: binaryLimit,
                                   stopAfterFirstSection: stopAfterFirstSection)
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

    private init(markupLimit: Int, binaryLimit: Int, stopAfterFirstSection: Bool) {
        self.markupLimit = markupLimit
        self.binaryLimit = binaryLimit
        self.stopAfterFirstSection = stopAfterFirstSection
    }

    private func result() -> Result {
        Result(metadata: metadata, html: out, binaries: binaries, coverID: coverID,
               binaryBytes: binaryBytes, sections: sections, truncated: truncated)
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
            out += "<div class=\"fb2-section\"\(Self.idAttribute(attributes))>"
        case "title":
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
            out += paragraphDepth > 0
                ? "<img src=\"\(source)\" alt=\"\">"
                : "<img class=\"fb2-image\" src=\"\(source)\" alt=\"\">"
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
            if sectionDepth == 0 { checkLimits() }
        case "title":
            out += quoting > 0 ? "</p>" : "</h\(titleLevel)>"
            inTitle = false
        case "subtitle": out += "</p>"
        case "p":
            if inTitle { break }
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
