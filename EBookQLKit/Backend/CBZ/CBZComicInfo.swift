//
//  CBZComicInfo.swift
//  EBookQLKit
//
//  `ComicInfo.xml` - ComicRack's manifest, which every comic reader understands. Only what a
//  preview can use is read: the series and its number, the writer, and the per-page
//  bookmarks, which are a real table of contents for a format that otherwise has none (a
//  CBZ is a pile of images and nothing else).
//

import Foundation

struct CBZComicInfo {
    let series: String?
    let number: String?
    let title: String?
    let writer: String?
    /// `Image` attribute as written (a page index, or - in the wild - a file name) plus the
    /// bookmark's label. Resolved to a page by `CBZDocument.index(of:in:)`.
    let bookmarks: [(reference: String, title: String)]

    private static let fields = ["series", "number", "title", "writer"]

    /// Parses the manifest. Returns nil when the file is not XML this code understands -
    /// a comic without a usable manifest still previews, it just has no declared contents.
    static func parse(_ data: Data) -> CBZComicInfo? {
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // The declaration is about bytes that have already been decoded here, so it is
        // rewritten: otherwise the parser re-reads this UTF-8 as whatever the file claims
        // to be - the trap the FB2 backend hit with windows-1251 files.
        text = rewriteEncodingDeclaration(in: text)
        guard let bytes = text.data(using: .utf8) else { return nil }

        let delegate = Delegate()
        let parser = XMLParser(data: bytes)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return CBZComicInfo(
            series: delegate.values["series"],
            number: delegate.values["number"],
            title: delegate.values["title"],
            writer: delegate.values["writer"],
            bookmarks: delegate.bookmarks
        )
    }

    static func rewriteEncodingDeclaration(in text: String) -> String {
        guard let keyword = text.range(of: "encoding=", options: [.caseInsensitive]) else { return text }
        var index = keyword.upperBound
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return text }
        // The value is quoted, single or double.
        let quote = text[index]
        guard quote == "\"" || quote == "'" else { return text }
        let valueStart = text.index(after: index)
        guard let valueEnd = text[valueStart...].firstIndex(of: quote) else { return text }
        return text.replacingCharacters(in: index...valueEnd, with: "\"UTF-8\"")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var bookmarks: [(reference: String, title: String)] = []

        private var current: String?
        private var buffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let name = elementName.lowercased()
            current = CBZComicInfo.fields.contains(name) ? name : nil
            buffer = ""

            guard name == "page" else { return }
            let lookup = { (key: String) in
                attributes.first { $0.key.lowercased() == key }?.value
            }
            guard let title = lookup("bookmark")?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { return }
            guard let reference = lookup("image") ?? lookup("imagename") else { return }
            bookmarks.append((reference, title))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard current != nil else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            defer { current = nil; buffer = "" }
            guard let current, elementName.lowercased() == current else { return }
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            values[current] = value
        }
    }
}
