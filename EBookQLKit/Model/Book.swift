//
//  Book.swift
//  EBookQLKit
//
//  The format-neutral model every backend produces and the reader only consumes.
//  Nothing here knows about EPUB or MOBI.
//

import Foundation

public enum BookFormat: String, Sendable {
    case epub
    case mobi
    case azw
    case azw3
    case markdown
}

public struct BookMetadata: Sendable {
    public var title: String?
    public var author: String?
    public var language: String?
    public var identifier: String?
    /// Path inside the book of a cover image, when the format has one.
    public var coverPath: String?

    public init(
        title: String? = nil,
        author: String? = nil,
        language: String? = nil,
        identifier: String? = nil,
        coverPath: String? = nil
    ) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.coverPath = coverPath
    }
}

/// One ordered content unit. An EPUB spine document is a section; a MOBI book is
/// one section to begin with. Links and resource references inside `html` have
/// already been rewritten to what the preview page can load.
public struct BookSection: Sendable {
    public let id: String
    public let html: String
    /// Folder of the source document, root-relative. Relative references resolve
    /// against this, not against the package root.
    public let basePath: String?
    /// Root-relative path of the source document, used to map cross-file links
    /// onto sections.
    public let sourcePath: String?
    /// The source document's own `<body id="…">`, which split books (Calibre/Sigil)
    /// use as a link target.
    public let bodyID: String?
    public let title: String?

    public init(
        id: String,
        html: String,
        basePath: String? = nil,
        sourcePath: String? = nil,
        bodyID: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.html = html
        self.basePath = basePath
        self.sourcePath = sourcePath
        self.bodyID = bodyID
        self.title = title
    }
}

/// Where a table-of-contents entry points. A backend knows document paths, not
/// section indices, so the renderer maps `sectionPath` onto a section afterwards.
public struct BookTarget: Sendable, Equatable {
    /// Root-relative path of the target document; nil means "not navigable".
    public let sectionPath: String?
    public let fragment: String?

    public init(sectionPath: String?, fragment: String? = nil) {
        self.sectionPath = sectionPath
        self.fragment = fragment
    }
}

/// A table-of-contents entry. Both a format-declared TOC (EPUB `nav` / NCX) and a
/// TOC derived from the book's own headings produce these, so the sidebar can
/// render either without knowing which it was.
public struct TOCEntry: Sendable {
    public let title: String
    public let target: BookTarget?
    public var children: [TOCEntry]

    public init(title: String, target: BookTarget? = nil, children: [TOCEntry] = []) {
        self.title = title
        self.target = target
        self.children = children
    }
}

/// Turns a reference inside the book into a URL the preview web view can load.
public protocol ResourceProvider: ResourceSource {
    func url(for path: String, relativeTo base: String?) -> String?
}

/// A book the preview can render, whichever format it came from.
///
/// Not `Sendable` on purpose: `resources` may be a stateful handler that is
/// handed to the web view on the main thread only (see the scheme handler).
public struct Book {
    public let url: URL
    public let format: BookFormat
    public let metadata: BookMetadata
    public let sections: [BookSection]
    /// Empty means "derive it from the headings" (see ReaderDocument).
    public let toc: [TOCEntry]
    /// Set when `toc` is only a last resort - a MOBI's NCX, whose entries carry a
    /// position rather than an anchor and so are not clickable yet. The heading
    /// derivation is what gives an entry something to jump to, so a fallback TOC fills
    /// in only when that produced nothing; it never displaces a clickable list.
    public let tocIsFallback: Bool
    /// Folder the TOC references resolve against, root-relative.
    public let tocBasePath: String?
    public let resources: ResourceProvider?
    /// Byte count the content was truncated to, when the book was too long to render.
    public let truncatedAt: Int?
    /// Byte count of the book's whole text, for the "showing the first X of Y" note.
    public let contentBytes: Int?

    public init(
        url: URL,
        format: BookFormat,
        metadata: BookMetadata,
        sections: [BookSection],
        toc: [TOCEntry] = [],
        tocBasePath: String? = nil,
        resources: ResourceProvider? = nil,
        truncatedAt: Int? = nil,
        contentBytes: Int? = nil,
        tocIsFallback: Bool = false
    ) {
        self.url = url
        self.format = format
        self.metadata = metadata
        self.sections = sections
        self.toc = toc
        self.tocBasePath = tocBasePath
        self.resources = resources
        self.truncatedAt = truncatedAt
        self.contentBytes = contentBytes
        self.tocIsFallback = tocIsFallback
    }
}

/// Where the reader left off. Shared by every backend and by the thumbnail
/// extension (which only reads the metadata fields).
public struct ReadingPosition: Sendable {
    /// Heading the viewport is inside, e.g. "ch37" or "mf-sec-12".
    public var anchor: String?
    /// How far into that heading's section, 0…1.
    public var sectionOffset: Double
    /// How far into the whole book, 0…1. Fallback when the anchor is gone.
    public var fraction: Double
    /// Raw scroll offset, last resort for books with no usable anchor.
    public var scrollY: Double
    public var updated: TimeInterval

    public init(
        anchor: String? = nil,
        sectionOffset: Double = 0,
        fraction: Double = 0,
        scrollY: Double = 0,
        updated: TimeInterval = 0
    ) {
        self.anchor = anchor
        self.sectionOffset = sectionOffset
        self.fraction = fraction
        self.scrollY = scrollY
        self.updated = updated
    }
}
