//
//  CHMBackend.swift
//  EBookQLKit
//
//  Microsoft HTML Help (.chm) -> Book.
//
//  A CHM is a compressed archive of ordinary HTML pages, so this backend is close to
//  the EPUB one: one section per topic, cross-topic links left to the renderer's
//  `sectionIndexByPath` rewrite, resources served on demand over `ekbres://chm/…`
//  (only the pages being read are ever decompressed).
//
//  Two things a CHM does not hand over for free:
//    * **Encoding.** Topics, and the .hhc/.hhk that list them, are ANSI in whatever
//      code page the compiler was told to use; Chinese help files are GB2312/GBK in
//      practice, and files *declaring* gb2312 are routinely GB18030 bytes. The topic's
//      own `<meta charset>` is tried first and anything Chinese is decoded as GB18030,
//      then Foundation's detector, then Latin-1 so a stray file stays readable.
//    * **Contents.** The sidebar comes from a `*.hhc` when the archive has one; this
//      sample (and every help file compiled with "automatically generated TOC") has
//      none, and the tree only exists as a binary structure chmlib and 7-Zip do not
//      parse either. The contents are then derived from the topics' own titles, grouped
//      by folder the way CBZ groups pages, and the sidebar is told they were derived -
//      a derived list must never look like the book's own structure (Book.tocNote).
//

import Foundation
import UniformTypeIdentifiers

public final class CHMBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["chm"]

    /// Same ceiling the other markup backends use: a book longer than this stops at a
    /// topic boundary and says so, rather than taking the preview down with it.
    private static let markupBudget = 8 * 1024 * 1024

    // MARK: - Open

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let container = try openContainer(url)

        let topics = topicEntries(container)
        guard !topics.isEmpty else { throw BookParseError.malformed }

        let system = container.systemInfo
        let defaultTopic = system?.defaultTopic.map { CHMContainer.canonicalPath($0) }
        let ordered = orderedTopics(topics, defaultTopic: defaultTopic)

        var sections: [BookSection] = []
        var titles: [String: String] = [:]
        var markup = 0
        var truncatedAt: Int?
        var contentBytes = 0
        var index = 0

        for entry in ordered {
            guard let text = topicText(container, entry) else { continue }
            contentBytes += text.utf8.count
            let body = HTMLNormalizer.extractBody(text)
            let title = topicTitle(text) ?? (entry.path as NSString).lastPathComponent
            titles[entry.path] = title
            markup += body.content.utf8.count
            if markup > markupBudget {
                truncatedAt = markup
                break
            }
            sections.append(BookSection(
                id: "ch\(index)",
                html: body.content,
                basePath: parentPath(entry.path),
                sourcePath: relativePath(entry.path),
                bodyID: body.bodyID,
                title: title
            ))
            index += 1
        }
        guard !sections.isEmpty else { throw BookParseError.malformed }

        // A topic the budget cut off stays in the sidebar as a label, so the reader can
        // see it is there and not reachable (the same rule MOBI and FB2 follow).
        let included = Set(sections.compactMap(\.sourcePath))
        let contents = derivedContents(
            topics: ordered,
            titles: titles,
            included: included
        )

        let title = system?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        return Book(
            url: url,
            format: .chm,
            metadata: BookMetadata(title: title, language: nil, identifier: nil),
            sections: sections,
            toc: contents.entries,
            tocBasePath: nil,
            resources: CHMResourceProvider(container: container),
            truncatedAt: truncatedAt,
            contentBytes: contentBytes,
            // Derived, not declared - see `derivedContentsNote`. `tocIsFallback` stays
            // false on purpose: the renderer only consults a fallback list when the
            // heading derivation produced nothing, and it would then hide the folder
            // grouping behind 400 flat headings (FB2's promoted contents take the same
            // route).
            tocIsFallback: false,
            tocNote: contents.note
        )
    }

    /// Cheap open: the container's directory plus `/#SYSTEM`, which carries the title
    /// and the default topic. Finder asks for a folder's worth of thumbnails at once,
    /// so nothing here may decompress the whole book.
    public static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        _ = workDirectory
        let container = try openContainer(url)
        let system = container.systemInfo
        let title = system?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        var sections: [BookSection] = []
        if let defaultTopic = system?.defaultTopic,
           let entry = container.entry(CHMContainer.canonicalPath(defaultTopic)),
           let text = topicText(container, entry) {
            let body = HTMLNormalizer.extractBody(text)
            sections.append(BookSection(
                id: "ch0",
                html: String(body.content.prefix(2000)),
                basePath: parentPath(entry.path),
                sourcePath: relativePath(entry.path),
                bodyID: body.bodyID,
                title: topicTitle(text)
            ))
        }
        if sections.isEmpty {
            sections.append(BookSection(id: "ch0", html: "", sourcePath: nil))
        }

        return Book(
            url: url,
            format: .chm,
            metadata: BookMetadata(title: title),
            sections: sections,
            toc: [],
            resources: CHMResourceProvider(container: container),
            tocIsFallback: false
        )
    }

    // MARK: - Container

    private static func openContainer(_ url: URL) throws -> CHMContainer {
        do {
            return try CHMContainer(url: url)
        } catch CHMError.notCHM {
            throw BookParseError.malformed
        } catch {
            throw BookParseError.corrupt
        }
    }

    /// The pages: the archive's HTML, in directory order. Everything the container
    /// keeps for itself is left out - `/#…` and `/$…` are the compiler's tables,
    /// `::DataSpace/…` is the container's plumbing, and the B-tree files are its search
    /// index.
    private static func topicEntries(_ container: CHMContainer) -> [CHMEntry] {
        container.entries.filter { entry in
            let path = entry.path.lowercased()
            guard path.hasSuffix(".htm") || path.hasSuffix(".html") else { return false }
            guard !entry.path.hasPrefix("/#"), !entry.path.hasPrefix("/$"),
                  !entry.path.hasPrefix("/::") else { return false }
            return true
        }
    }

    private static func orderedTopics(_ topics: [CHMEntry], defaultTopic: String?) -> [CHMEntry] {
        guard let defaultTopic, let first = topics.first(where: { $0.path == defaultTopic }) else {
            return topics
        }
        return [first] + topics.filter { $0.path != defaultTopic }
    }

    private static func topicText(_ container: CHMContainer, _ entry: CHMEntry) -> String? {
        guard let bytes = try? container.data(of: entry) else { return nil }
        return decodeText(bytes)
    }

    // MARK: - Contents

    /// A sidebar built from the topics' own titles, one level per folder (the rule CBZ
    /// uses for pages: 400 sibling entries named `Array`, `Block`, … is not navigation).
    private static func derivedContents(
        topics: [CHMEntry],
        titles: [String: String],
        included: Set<String>
    ) -> (entries: [TOCEntry], note: String?) {
        var folders: [String: [TOCEntry]] = [:]
        var folderOrder: [String] = []
        var root: [TOCEntry] = []

        for entry in topics {
            let title = titles[entry.path] ?? (entry.path as NSString).lastPathComponent
            // A topic the markup budget cut off keeps its label but has nowhere to go.
            let target = included.contains(relativePath(entry.path))
                ? BookTarget(sectionPath: relativePath(entry.path))
                : nil
            let item = TOCEntry(title: title, target: target)
            let folder = parentPath(entry.path)
            if folder.isEmpty {
                root.append(item)
            } else {
                if folders[folder] == nil { folderOrder.append(folder) }
                folders[folder, default: []].append(item)
            }
        }

        var entries = root
        for folder in folderOrder.sorted() {
            guard let children = folders[folder], !children.isEmpty else { continue }
            entries.append(TOCEntry(title: folder, children: children))
        }
        guard entries.count > 1 else { return ([], nil) }
        return (entries, derivedContentsNote)
    }

    /// The sidebar must say the contents were derived: this CHM stores its table of
    /// contents as a binary structure (Microsoft's "automatically generated TOC"), not
    /// as the `.hhc` a help file normally carries, so the list below is the topics' own
    /// titles, not the book's declared structure.
    public static var derivedContentsNote: String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh")
            ? "这个文件没有目录表（.hhc），下面的目录由各页标题推断。"
            : "This file carries no .hhc table of contents; the list below is derived from the page titles."
    }

    // MARK: - Text

    /// The topic's own `<meta charset>` first, then Foundation's detector, then Latin-1.
    static func decodeText(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if let declared = declaredCharset(bytes), let encoding = encoding(for: declared),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        var converted: NSString?
        var lossy = ObjCBool(false)
        _ = NSString.stringEncoding(for: data, encodingOptions: nil,
                                    convertedString: &converted, usedLossyConversion: &lossy)
        if let converted, converted.length > 0, !lossy.boolValue {
            return converted as String
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func declaredCharset(_ bytes: [UInt8]) -> String? {
        let head = String(decoding: bytes.prefix(2048), as: UTF8.self)
        guard let range = head.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let rest = head[range.upperBound...]
        let name = rest.prefix { $0 != "\"" && $0 != "'" && $0 != ">" && $0 != " " && $0 != ";" }
        return name.isEmpty ? nil : String(name)
    }

    /// Anything Chinese is decoded as GB18030 whatever the declaration says: files that
    /// say `gb2312` are routinely GB18030 bytes, and a GB2312 decoder fails on them.
    private static func encoding(for name: String) -> String.Encoding? {
        func cf(_ value: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gb2312", "gbk", "gb18030", "cp936", "x-gbk": return cf(.GB_18030_2000)
        case "big5", "cp950": return cf(.big5)
        case "shift_jis", "shift-jis", "sjis", "cp932", "x-sjis": return .shiftJIS
        case "euc-kr", "cp949": return cf(.EUC_KR)
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1250": return .windowsCP1250
        case "windows-1252": return .windowsCP1252

        default: return nil
        }
    }

    // MARK: - Titles and paths

    private static func topicTitle(_ html: String) -> String? {
        for pattern in [#"<title[^>]*>(.*?)</title\s*>"#, #"<h1[^>]*>(.*?)</h1\s*>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let text = HTMLNormalizer.collapsedText(String(html[range]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// "…/docs/lib/Array.htm" -> "docs/lib" ("" at the archive root), the same shape the
    /// other backends use for `basePath`.
    static func parentPath(_ path: String) -> String {
        let trimmed = relativePath(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[trimmed.startIndex..<slash])
    }

    /// The container spells paths with a leading "/", but a section's `sourcePath` has to
    /// match what `BookPath.normalize` produces for a link inside a page - which has none.
    /// A mismatch here is invisible until something is clicked: every cross-topic link is
    /// then served as a resource (`ekbres://chm/docs/Other.htm`) instead of jumping to the
    /// section that holds the page.
    static func relativePath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}

// MARK: - Resources

/// Serves the archive's own files (images, CSS, scripts, fonts) over `ekbres://chm/…`,
/// decompressing only what the page asks for. The container is already open - the
/// directory has to be parsed before a page can be built - so nothing is reopened here.
public final class CHMResourceProvider: ResourceProvider {

    private let container: CHMContainer

    init(container: CHMContainer) {
        self.container = container
    }

    public func url(for path: String, relativeTo base: String?) -> String? {
        let normalized = BookPath.normalize(path, relativeTo: base)
        guard !normalized.isEmpty else { return nil }
        return "\(BookResourceScheme.name)://chm/\(normalized)"
    }

    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        guard let entry = container.entry(CHMContainer.canonicalPath(path)),
              let bytes = try? container.data(of: entry) else { return nil }
        return (Data(bytes), UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType)
    }
}
