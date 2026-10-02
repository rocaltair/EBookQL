//
//  BookBackend.swift
//  EBookQLKit
//
//  One protocol every format implements, and the plumbing that picks the right
//  one for a file. Nothing here knows about EPUB or MOBI.
//

import Foundation

public enum BookParseError: Error, LocalizedError {
    case unsupportedFormat
    case containerNotFound
    case opfNotFound
    case malformed
    case io
    case encrypted
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "This file is not a book format EBookQL can open."
        case .containerNotFound: return "The book has no META-INF/container.xml."
        case .opfNotFound: return "The book has no package document (.opf)."
        case .malformed: return "The book's package document is malformed."
        case .io: return "The book could not be read."
        case .encrypted: return "This book is encrypted (DRM)."
        case .corrupt: return "The book's data is damaged."
        }
    }
}

/// A format backend: file in, `Book` out. Parsing only - no UI, no web view.
public protocol BookBackend {
    static var supportedExtensions: Set<String> { get }
    static func open(_ url: URL, workDirectory: URL) throws -> Book
    /// A cheap parse for thumbnails: the title, the author and the opening text are
    /// all a card needs. Finder asks for thumbnails for a whole folder at once, so a
    /// backend that would otherwise read a 200 MB book into memory must not.
    static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book
}

public extension BookBackend {
    static func openForThumbnail(_ url: URL, workDirectory: URL) throws -> Book {
        try open(url, workDirectory: workDirectory)
    }
}

public enum BookOpener {
    /// Order matters only for formats that share an extension.
    public static let backends: [BookBackend.Type] = [EPUBBackend.self, MOBIBackend.self]

    public static func backend(for url: URL) -> BookBackend.Type? {
        let ext = url.pathExtension.lowercased()
        return backends.first { $0.supportedExtensions.contains(ext) }
    }
}

/// Where the preview's scheme handler reads resources from - the archive an EPUB was
/// unpacked from, or a MOBI's embedded records. The handler knows nothing about
/// formats: it asks for a path and gets bytes back.
public protocol ResourceSource: AnyObject {
    /// Reads the resource at a scheme-relative path (`/OEBPS/img/x.png`, `/mobi/12`).
    /// Returns nil when there is no such resource.
    func resource(at path: String) -> (data: Data, mimeType: String?)?
}

/// The URL scheme the preview registers, and that both backends use for resources
/// living inside the book rather than on disk.
public enum BookResourceScheme {
    public static let name = "ekbres"
}

/// Path handling shared by every backend and by the renderer.
///
/// References inside a book are URL-encoded, may be root-relative (`/images/x.png`)
/// or document-relative (`../images/x.png`), and both sides have to agree on one
/// normalized spelling or cross-file links and images silently break.
public enum BookPath {

    /// Normalizes a reference into a root-relative path such as `OEBPS/text/ch1.xhtml`.
    /// `base` is the folder of the document the reference appeared in, root-relative.
    public static func normalize(_ path: String, relativeTo base: String?) -> String {
        // EPUB hrefs are percent-encoded ("text/33%20-%20x.html" for "33 - x.html").
        var value = path.removingPercentEncoding ?? path
        // Drop any fragment and query; callers handle those separately.
        if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[value.startIndex..<query]) }

        var components: [String] = []
        if value.hasPrefix("/") {
            // Root-relative: the book root, not the current folder.
            components = []
        } else {
            components = (base?.split(separator: "/").map(String.init)) ?? []
        }

        for piece in value.split(separator: "/", omittingEmptySubsequences: false) {
            switch piece {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }

    /// Splits "text/ch1.xhtml#note3" into ("text/ch1.xhtml", "note3").
    public static func splitFragment(_ value: String) -> (path: String, fragment: String?) {
        guard let hash = value.firstIndex(of: "#") else { return (value, nil) }
        let path = String(value[value.startIndex..<hash])
        let fragment = String(value[value.index(after: hash)...])
        return (path, fragment.isEmpty ? nil : fragment)
    }

    /// Fragments are URL-encoded too ("#%E4%B8%AD" for the id "中").
    public static func decodedFragment(_ fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        return fragment.removingPercentEncoding ?? fragment
    }
}
