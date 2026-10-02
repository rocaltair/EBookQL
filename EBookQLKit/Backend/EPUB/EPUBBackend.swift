//
//  EPUBBackend.swift
//  EBookQLKit
//
//  EPUB -> Book.
//
//  Nothing is unpacked to disk. Text is read straight out of the archive (which is
//  held in memory for every book up to `memoryAwareLimit`), and everything the page
//  asks for later - images, fonts, media - is streamed by the preview's scheme
//  handler from the same archive. The earlier version wrote every text entry to the
//  work directory and read it straight back; on a 402-chapter book that was 402
//  writes plus 402 reads for nothing, since the only file the page needs on disk is
//  index.html. Kept fixes: `<body id="…">` anchors survive, and hrefs are
//  percent-decoded before they are resolved.
//

import Foundation
import ZIPFoundation
import os.log

public final class EPUBBackend: BookBackend {

    public static let supportedExtensions: Set<String> = ["epub"]

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "EPUB")

    /// Books up to this size are read into memory once, so the preview touches the
    /// volume once instead of once per archive entry.
    ///
    /// This is about the *images*, not the text: reading 402 chapters' text took
    /// 0.1 s even straight off an SMB share, but the page asks for its artwork as the
    /// reader scrolls, and each of those would otherwise be its own seek on the
    /// volume.
    private static let inMemoryArchiveLimit = 512 * 1024 * 1024

    /// ...but never take more than a quarter of physical memory. Above this the
    /// archive is read from disk on demand - correct, just slower.
    private static var memoryAwareLimit: Int {
        let quarter = Int(ProcessInfo.processInfo.physicalMemory / 4)
        return max(64 * 1024 * 1024, min(inMemoryArchiveLimit, quarter))
    }

    // MARK: - Entry point

    public static func open(_ url: URL, workDirectory: URL) throws -> Book {
        try open(url, workDirectory: workDirectory, inMemoryLimit: memoryAwareLimit, sectionLimit: nil)
    }

    /// Thumbnails read no archive into memory and stop after the first section: Finder
    /// thumbnails a whole folder at once, and the title, author and opening lines are
    /// all the card shows.
    public static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        try open(url, workDirectory: workDirectory, inMemoryLimit: 0, sectionLimit: 1)
    }

    private static func open(_ url: URL, workDirectory: URL, inMemoryLimit: Int, sectionLimit: Int?) throws -> Book {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let t0 = Date()
        let source = try makeSource(url, workDirectory: workDirectory, inMemoryLimit: inMemoryLimit)
        let archive = source.openArchive()
        let t1 = Date()
        let package = try parsePackage(source, archive: archive)
        let t2 = Date()

        var sections: [BookSection] = []
        for (index, spine) in package.spine.enumerated() {
            if let sectionLimit, index >= sectionLimit { break }
            guard let data = source.read(spine.path, archive: archive) else { continue }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            let body = HTMLNormalizer.extractBody(text)
            sections.append(BookSection(
                id: "ch\(index)",
                html: body.content,
                basePath: parentPath(spine.path),
                sourcePath: spine.path,
                bodyID: body.bodyID
            ))
        }
        guard !sections.isEmpty else { throw BookParseError.malformed }
        let t3 = Date()

        os_log("source %.2fs parse %.2fs sections %.2fs | %{public}d sections | mem=%{public}@",
               log: log, type: .info,
               t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2),
               sections.count, source.isInMemory ? "yes" : "no")

        return Book(
            url: url,
            format: .epub,
            metadata: package.metadata,
            sections: sections,
            toc: package.toc,
            tocBasePath: package.tocBasePath,
            // The declared list is the publisher's, but it is not always the more useful
            // one: this book's nav lists its twelve files while the text marks 383 headings
            // inside them, so a sidebar built from the declaration alone shows a twelfth of
            // the structure. Marked as a fallback, so the heading derivation takes over when
            // it yields more - the same rule MOBI books already follow - and a book whose
            // own list is richer keeps it (265 for one EPUB against a single heading).
            resources: EPUBResourceProvider(source: source),
            tocIsFallback: true
        )
    }

    // MARK: - Where the bytes come from

    /// A directory-bundle EPUB sits on disk; a zipped one is either read into memory
    /// once or read from the file on demand. Both are reached through `read`, so the
    /// parsing code above never knows which it is.
    struct Source {
        let bundleRoot: URL?
        let archiveURL: URL?
        let inMemory: Data?

        var isInMemory: Bool { inMemory != nil }

        func openArchive() -> Archive? {
            if let inMemory { return try? Archive(data: inMemory, accessMode: .read) }
            if let archiveURL { return Archive(url: archiveURL, accessMode: .read) }
            return nil
        }

        /// One entry, given a root-relative percent-decoded path.
        func read(_ path: String, archive: Archive?) -> Data? {
            if let bundleRoot {
                return try? Data(contentsOf: bundleRoot.appendingPathComponent(path))
            }
            guard let archive else { return nil }
            // Archives store names verbatim, so a decoded path may need re-encoding.
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            for candidate in [path, encoded] {
                guard let entry = archive[candidate] else { continue }
                // Reserve up front: the closure form appends chunk by chunk, and a
                // Data that keeps growing reallocates on every append. Without this
                // the in-memory read measured slower than extracting to a file.
                var data = Data()
                data.reserveCapacity(Int(entry.uncompressedSize))
                if (try? archive.extract(entry) { data.append($0) }) != nil { return data }
            }
            return nil
        }

        /// Every file path in the book - only needed to hunt for the OPF when a
        /// package has no usable META-INF/container.xml.
        func allPaths(archive: Archive?) -> [String] {
            if let bundleRoot {
                guard let enumerator = FileManager.default.enumerator(
                    at: bundleRoot, includingPropertiesForKeys: nil) else { return [] }
                var paths: [String] = []
                for case let file as URL in enumerator where !file.hasDirectoryPath {
                    paths.append(EPUBBackend.relativePath(of: file, under: bundleRoot))
                }
                return paths
            }
            guard let archive else { return [] }
            return archive.compactMap { $0.type == .file ? $0.path : nil }
        }
    }

    private static func makeSource(_ url: URL, workDirectory: URL, inMemoryLimit: Int) throws -> Source {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookParseError.io
        }

        // An Apple "package" .epub is a directory bundle (UTI com.apple.ibooks.epub).
        // It is copied rather than read in place: the security scope covers the whole
        // preview, but a stable private copy keeps the reading code single-path.
        if isDirectory.boolValue {
            let destination = workDirectory.appendingPathComponent("EPUBPackage", isDirectory: true)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.copyItem(at: url, to: destination)
            return Source(bundleRoot: destination, archiveURL: nil, inMemory: nil)
        }

        let fileSize = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let inMemory = (inMemoryLimit > 0 && fileSize > 0 && fileSize <= inMemoryLimit)
            ? (try? Data(contentsOf: url)) : nil
        return Source(bundleRoot: nil, archiveURL: url, inMemory: inMemory)
    }

    // MARK: - Package parsing

    private struct SpineItem {
        let path: String
    }

    private struct Package {
        var metadata: BookMetadata
        var spine: [SpineItem]
        var toc: [TOCEntry]
        var tocBasePath: String?
    }

    private struct ManifestItem {
        let href: String
        let mediaType: String?
        let properties: String?
    }

    private static func parsePackage(_ source: Source, archive: Archive?) throws -> Package {
        var opfPath: String?

        if let data = source.read("META-INF/container.xml", archive: archive),
           let document = try? XMLDocument(data: data),
           let attribute = try? document.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first,
           let value = attribute.stringValue {
            opfPath = BookPath.normalize(value, relativeTo: nil)
        }
        if opfPath == nil {
            opfPath = source.allPaths(archive: archive).first {
                ($0 as NSString).pathExtension.lowercased() == "opf"
            }
        }
        guard let opfPath, let opfData = source.read(opfPath, archive: archive) else {
            throw BookParseError.opfNotFound
        }

        let opf: XMLDocument
        do { opf = try XMLDocument(data: opfData) } catch { throw BookParseError.malformed }

        // Manifest hrefs resolve against the OPF's own folder.
        let opfBase = parentPath(opfPath)

        var items: [String: ManifestItem] = [:]
        let itemNodes = (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) as? [XMLElement] ?? []
        for item in itemNodes {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            items[id] = ManifestItem(
                href: href,
                mediaType: item.attribute(forName: "media-type")?.stringValue,
                properties: item.attribute(forName: "properties")?.stringValue
            )
        }

        var spine: [SpineItem] = []
        let spineNodes = (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) as? [XMLElement] ?? []
        for node in spineNodes {
            guard let idref = node.attribute(forName: "idref")?.stringValue,
                  let item = items[idref] else { continue }
            let ext = (item.href as NSString).pathExtension.lowercased()
            guard ["xhtml", "html", "htm"].contains(ext) else { continue }
            spine.append(SpineItem(path: BookPath.normalize(item.href, relativeTo: opfBase)))
        }
        guard !spine.isEmpty else { throw BookParseError.malformed }

        // Table of contents: the EPUB 3 nav document first, NCX as the fallback.
        let spineElement = (try? opf.nodes(forXPath: "//*[local-name()='spine']"))?.first as? XMLElement
        let ncxID = spineElement?.attribute(forName: "toc")?.stringValue

        var toc: [TOCEntry] = []
        var tocBasePath: String? = opfBase
        if let navItem = items.values.first(where: {
            ($0.properties ?? "").split(separator: " ").contains("nav")
        }) {
            let navPath = BookPath.normalize(navItem.href, relativeTo: opfBase)
            if let data = source.read(navPath, archive: archive) {
                let nav = parseNav(data: data, base: parentPath(navPath))
                if !nav.isEmpty {
                    toc = nav
                    tocBasePath = parentPath(navPath)
                }
            }
        }
        if toc.isEmpty {
            let ncxItem = ncxID.flatMap { items[$0] }
                ?? items.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncxItem {
                let ncxPath = BookPath.normalize(ncxItem.href, relativeTo: opfBase)
                if let data = source.read(ncxPath, archive: archive) {
                    let ncx = parseNCX(data: data, base: parentPath(ncxPath))
                    if !ncx.isEmpty {
                        toc = ncx
                        tocBasePath = parentPath(ncxPath)
                    }
                }
            }
        }

        return Package(metadata: parseMetadata(opf), spine: spine, toc: toc, tocBasePath: tocBasePath)
    }

    private static func parseMetadata(_ opf: XMLDocument) -> BookMetadata {
        func first(_ xpath: String) -> String? {
            guard let node = (try? opf.nodes(forXPath: xpath))?.first else { return nil }
            let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }
        return BookMetadata(
            title: first("//*[local-name()='metadata']/*[local-name()='title']"),
            author: first("//*[local-name()='metadata']/*[local-name()='creator']"),
            language: first("//*[local-name()='metadata']/*[local-name()='language']"),
            identifier: first("//*[local-name()='metadata']/*[local-name()='identifier']"),
            coverPath: first("//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']/@content")
        )
    }

    // MARK: - Table of contents

    private static func parseNav(data: Data, base: String) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data) else { return [] }
        let navs = (try? document.nodes(forXPath: "//*[local-name()='nav']")) as? [XMLElement] ?? []
        let tocNav = navs.first { nav in
            (nav.attributes ?? []).contains { attribute in
                attribute.localName == "type"
                    && (attribute.stringValue ?? "").lowercased().contains("toc")
            }
        } ?? navs.first

        guard let tocNav,
              let list = (try? tocNav.nodes(forXPath: "(.//*[local-name()='ol'])[1]"))?.first as? XMLElement
        else { return [] }
        return parseNavList(list, base: base)
    }

    private static func parseNavList(_ list: XMLElement, base: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for child in (list.children ?? []) {
            guard let item = child as? XMLElement, item.localName?.lowercased() == "li" else { continue }

            let label = (item.children ?? []).first {
                guard let name = ($0 as? XMLElement)?.localName?.lowercased() else { return false }
                return name == "a" || name == "span"
            } as? XMLElement

            let title = (label?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let target = label?.attribute(forName: "href")?.stringValue
                .flatMap { makeTarget(from: $0, base: base) }

            let sublist = (item.children ?? []).first {
                ($0 as? XMLElement)?.localName?.lowercased() == "ol"
            } as? XMLElement
            let children = sublist.map { parseNavList($0, base: base) } ?? []

            if !title.isEmpty || !children.isEmpty {
                entries.append(TOCEntry(title: title, target: target, children: children))
            }
        }
        return entries
    }

    private static func parseNCX(data: Data, base: String) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data) else { return [] }
        let roots = (try? document.nodes(forXPath: "//*[local-name()='navMap']/*[local-name()='navPoint']")) as? [XMLElement] ?? []
        return roots.compactMap { parseNavPoint($0, base: base) }
    }

    private static func parseNavPoint(_ element: XMLElement, base: String) -> TOCEntry? {
        let label = (try? element.nodes(forXPath: "(.//*[local-name()='navLabel']/*[local-name()='text'])[1]"))?.first
        let title = (label?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let content = (element.children ?? []).first {
            ($0 as? XMLElement)?.localName?.lowercased() == "content"
        } as? XMLElement
        let target = content?.attribute(forName: "src")?.stringValue
            .flatMap { makeTarget(from: $0, base: base) }

        let children = ((element.children ?? []).compactMap { $0 as? XMLElement })
            .filter { $0.localName?.lowercased() == "navpoint" }
            .compactMap { parseNavPoint($0, base: base) }

        if title.isEmpty && children.isEmpty { return nil }
        return TOCEntry(title: title, target: target, children: children)
    }

    /// A TOC reference as a normalized (path, fragment) pair. The renderer maps the
    /// path onto a section index afterwards.
    private static func makeTarget(from href: String, base: String) -> BookTarget? {
        guard !href.isEmpty, href != "#" else { return nil }
        if href.hasPrefix("#") {
            return BookTarget(sectionPath: nil, fragment: BookPath.decodedFragment(String(href.dropFirst())))
        }
        let (path, fragment) = BookPath.splitFragment(href)
        return BookTarget(sectionPath: BookPath.normalize(path, relativeTo: base),
                          fragment: BookPath.decodedFragment(fragment))
    }

    // MARK: - Paths

    /// The folder part of a root-relative path, "" at the top level.
    static func parentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<separator])
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(rootPath) else { return "" }
        var relative = String(target.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}

// MARK: - Resources

/// Resolves references inside an EPUB. A directory-bundle book is read from its
/// folder; a zipped one is handed to the preview's scheme handler, which streams the
/// entry straight out of the archive - nothing is unpacked to disk first.
public final class EPUBResourceProvider: ResourceProvider {

    /// Scheme the preview registers for archive-backed resources.
    public static let scheme = BookResourceScheme.name

    private let source: EPUBBackend.Source
    /// Opened on first use, off the scheme handler's serial queue.
    private var archive: Archive?

    init(source: EPUBBackend.Source) {
        self.source = source
    }

    /// Reads an entry straight out of the container. `Source.read` already retries the
    /// still-percent-encoded spelling, because archives store names verbatim while the
    /// page asks for a decoded path.
    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        let normalized = String(path.drop(while: { $0 == "/" }))
        guard !normalized.isEmpty else { return nil }
        guard let data = source.read(normalized, archive: openArchive()) else { return nil }
        return (data, nil)
    }

    private func openArchive() -> Archive? {
        if let archive { return archive }
        let opened = source.openArchive()
        archive = opened
        return opened
    }

    public func url(for path: String, relativeTo base: String?) -> String? {
        guard !path.isEmpty, !isExternal(path) else { return nil }
        let normalized = BookPath.normalize(path, relativeTo: base)
        guard !normalized.isEmpty else { return nil }

        if let bundleRoot = source.bundleRoot {
            let onDisk = bundleRoot.appendingPathComponent(normalized)
            if FileManager.default.fileExists(atPath: onDisk.path) { return onDisk.absoluteString }
        }
        // Archives store names verbatim (still percent-encoded), so re-encode.
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return "\(Self.scheme):///\(encoded)"
    }

    private func isExternal(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["http:", "https:", "file:", "data:", "mailto:", "tel:", "javascript:", "blob:", "#"]
            .contains { lower.hasPrefix($0) }
    }
}
