//
//  MarkdownResources.swift
//  EBookQLKit
//
//  Resolves a Markdown document's relative images against the folder it lives in.
//
//  Unlike an EPUB, a .md file is not a container: there is no archive to read from,
//  so a relative image is simply a sibling on disk. It is still served over the
//  reader's ekbres:// scheme (rather than a file:// URL) so the page's one resource
//  path stays uniform - and so the traversal guard below is the only thing that
//  decides what a document may reach.
//

import Foundation
import UniformTypeIdentifiers

/// Serves a Markdown document's sibling files. The directory is the folder of the
/// previewed file, and nothing above it is ever readable, however a `src` is written.
public final class MarkdownResourceSource: ResourceProvider {

    /// Scheme host the reader routes back here (`ekbres://md/…`). Any host other than
    /// the reserved `assets` one reaches this provider, but `md` names it clearly.
    private static let host = "md"

    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    // MARK: - ResourceProvider

    /// Turns a reference inside the document into an `ekbres://md/…` URL.
    public func url(for path: String, relativeTo base: String?) -> String? {
        let normalized = BookPath.normalize(path, relativeTo: base)
        // BookPath.normalize pops `..` against what is already there, so anything left
        // over could only climb above a root that had nothing to pop.
        guard !normalized.isEmpty, !normalized.hasPrefix("..") else { return nil }
        guard let fileURL = confinedURL(for: normalized) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        // Normalized already dropped the percent-encoding; re-encode for the URL path,
        // keeping `/` so subfolders survive. `.urlPathAllowed` leaves `#`/`?` out, so a
        // filename cannot smuggle a fragment or query into the scheme request.
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return "\(BookResourceScheme.name)://\(Self.host)/\(encoded)"
    }

    /// Reads a sibling file for the scheme handler. `path` is the request's URL path,
    /// so it keeps the leading `/` and, depending on the caller, may already be decoded.
    public func resource(at path: String) -> (data: Data, mimeType: String?)? {
        let stripped = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let decoded = stripped.removingPercentEncoding ?? stripped
        guard let fileURL = confinedURL(for: decoded) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
        return (data, mimeType)
    }

    // MARK: - Containment

    /// Joins a relative path onto the base directory and refuses anything that lands
    /// outside it. `standardizedFileURL` resolves `.` and `..` lexically, so a crafted
    /// `../../etc/passwd` is caught here even though `BookPath.normalize` already
    /// collapsed most of it.
    private func confinedURL(for relativePath: String) -> URL? {
        let root = baseDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        var rootPath = root.path
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }
}
