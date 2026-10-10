//
//  CBZDocument.swift
//  EBookQLKit
//
//  A CBZ is a ZIP archive full of page images - the comic-book convention - so this is the
//  small amount of reading that is specific to it:
//
//  * which entries are pages, and in which order (the archive's own order is not a promise:
//    tools write entries as the filesystem handed them over, so the names are sorted the
//    way a person reads them, `page9` before `page10`);
//  * each page's pixel size, read from the image's own header so the page box can be given
//    its final height before the picture is loaded;
//  * `ComicInfo.xml`, the one manifest the format has (a ComicRack convention every comic
//    reader understands): the series, the writer, and per-page bookmarks that make a real
//    table of contents.
//
//  Only a prefix of each entry is ever inflated: an image header is in the first few
//  kilobytes, and a 400 MB comic must not be fully decompressed just to open it.
//

import Foundation
import ZIPFoundation

enum CBZParseError: Error, LocalizedError {
    case notAnArchive
    case noPages
    case rarArchive

    /// The detail line of the notice page (only `BookParseError` cases get a summary of
    /// their own), so it says what is actually wrong with this file.
    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "This file is not a readable ZIP or TAR archive."
        case .rarArchive: return "This comic is a RAR archive (.cbr), which this preview does not read."
        case .noPages: return "This archive holds no page images (the pages are .jpg, .png, .gif or .webp files)."
        }
    }
}

/// One page of a comic archive - a CBZ (ZIP) or a CBT (TAR).
struct CBZPage {
    /// The entry's path inside the archive; doubles as the section id.
    let path: String
    /// What the sidebar shows: the file's own name for the page, minus its extension.
    let label: String
    let width: Int
    let height: Int
    /// Folder the entry sits in, when it is nested (`chapter 3/004.jpg`).
    let folder: String?
}

struct CBZDocument {
    let pages: [CBZPage]
    /// From `ComicInfo.xml`, when the archive has one.
    let series: String?
    let number: String?
    let title: String?
    let writer: String?
    /// The manifest's bookmarks, resolved to page indices.
    let bookmarks: [(index: Int, title: String)]

    /// Extensions that are pages. An archive may also hold a `ComicInfo.xml`, `__MACOSX`
    /// droppings, or a text file - none of which are pages.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "avif", "heic",
    ]

    /// How much of an entry to inflate to find its image header. A JPEG's frame header can
    /// sit behind a large EXIF block, hence a value well above a bare header's size.
    private static let headerBytes = 64 * 1024

    // MARK: - Reading

    /// Lists the pages and reads the manifest. `geometries: false` skips the per-image
    /// header read, which is what the thumbnail path wants: a Finder card needs the title.
    init(url: URL, geometries: Bool = true) throws {
        let archive = try ComicArchiveFactory.open(url)

        var entries: [String] = []
        var manifest: String?
        for entry in archive.entries {
            if Self.isNoise(entry.path) { continue }
            if (entry.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml" {
                manifest = entry.path
                continue
            }
            guard Self.imageExtensions.contains(
                (entry.path as NSString).pathExtension.lowercased()) else { continue }
            entries.append(entry.path)
        }
        guard !entries.isEmpty else { throw CBZParseError.noPages }

        entries.sort { Self.readingOrder($0, $1) }
        let listed = entries.map { path in
            let size = geometries ? Self.pixelSize(of: path, in: archive) : (0, 0)
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            return CBZPage(
                path: path,
                label: (name as NSString).deletingPathExtension,
                width: size.0,
                height: size.1,
                folder: folder.isEmpty ? nil : folder
            )
        }
        pages = listed

        let info = manifest.flatMap { Self.readManifest($0, in: archive) }
        series = info?.series
        number = info?.number
        title = info?.title
        writer = info?.writer
        bookmarks = (info?.bookmarks ?? []).compactMap { bookmark in
            guard let index = CBZDocument.index(of: bookmark.reference, in: listed) else { return nil }
            return (index, bookmark.title)
        }
    }

    /// What the window and the Finder card call this comic.
    var displayTitle: String? {
        if let series { return number.map { "\(series) #\($0)" } ?? series }
        return title
    }

    /// Resolves a manifest page reference. The `Image` attribute is the page's index in the
    /// archive (ComicRack's convention), but writers are known to put the file name there
    /// instead, so both spellings are accepted.
    static func index(of reference: String, in pages: [CBZPage]) -> Int? {
        let value = reference.trimmingCharacters(in: .whitespaces)
        if let number = Int(value) { return pages.indices.contains(number) ? number : nil }
        let needle = (value as NSString).lastPathComponent.lowercased()
        return pages.firstIndex {
            ($0.path as NSString).lastPathComponent.lowercased() == needle
        }
    }

    /// macOS bookkeeping and archive metadata are not pages.
    private static func isNoise(_ path: String) -> Bool {
        if path.hasPrefix("__MACOSX/") || path.hasPrefix(".") { return true }
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("._") || name == ".DS_Store" || name.hasPrefix("Thumbs.db")
    }

    // MARK: - Page order

    /// Natural order: digit runs compare as numbers, so `page9` sorts before `page10` and
    /// `2.jpg` before `10.jpg`. Everything else compares case-insensitively.
    static func readingOrder(_ left: String, _ right: String) -> Bool {
        let a = Array(left), b = Array(right)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let (aDigit, bDigit) = (a[i].isNumber, b[j].isNumber)
            if aDigit && bDigit {
                var x = 0, y = 0
                while i < a.count && a[i].isNumber { x = x * 10 + (Int(String(a[i])) ?? 0); i += 1 }
                while j < b.count && b[j].isNumber { y = y * 10 + (Int(String(b[j])) ?? 0); j += 1 }
                if x != y { return x < y }
                continue
            }
            let x = String(a[i]).lowercased(), y = String(b[j]).lowercased()
            if x != y { return x < y }
            i += 1
            j += 1
        }
        return a.count < b.count
    }

    // MARK: - Image headers

    /// The pixel size of an image, from the first bytes of its header. Read here rather
    /// than through ImageIO because the data is deliberately truncated - a header and no
    /// image - and this is the code that has to know how much of a header it needs.
    static func pixelSize(of path: String, in archive: ComicArchive) -> (Int, Int) {
        if let header = archive.prefix(of: path, limit: headerBytes),
           let size = CBZImageHeader.size(of: header) {
            return size
        }
        // A header that did not turn up in the first 64 KB: rare (a JPEG with a large EXIF
        // thumbnail), and worth one more pass before the page gets a wrong shape.
        let whole = min(size(of: path, in: archive), 4 * 1024 * 1024)
        if let all = archive.prefix(of: path, limit: whole),
           let size = CBZImageHeader.size(of: all) {
            return size
        }
        return (0, 0)
    }

    private static func size(of path: String, in archive: ComicArchive) -> Int {
        archive.entries.first { $0.path == path }?.size ?? 0
    }

    // MARK: - ComicInfo.xml

    private static func readManifest(_ path: String, in archive: ComicArchive) -> CBZComicInfo? {
        guard let data = archive.prefix(of: path, limit: 4 * 1024 * 1024) else { return nil }
        return CBZComicInfo.parse(data)
    }
}

/// The header parsers: what a comic archive actually holds - PNG, GIF, JPEG, WebP and BMP.
enum CBZImageHeader {

    static func size(of data: Data) -> (Int, Int)? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(256 * 1024))
        if let png = png(bytes) { return png }
        if let gif = gif(bytes) { return gif }
        if let jpeg = jpeg(bytes) { return jpeg }
        if let webp = webp(bytes) { return webp }
        if let bmp = bmp(bytes) { return bmp }
        return nil
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 2 <= b.count else { return nil }
        return (Int(b[i]) << 8) | Int(b[i + 1])
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 2 <= b.count else { return nil }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    /// `\x89PNG\r\n\x1a\n`, then `IHDR`'s width and height.
    private static func png(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4e, b[3] == 0x47,
              b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52,
              let width = be32(b, 16), let height = be32(b, 20),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// `GIF87a` / `GIF89a`, then the logical screen descriptor.
    private static func gif(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46,
              let width = le16(b, 6), let height = le16(b, 8),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Walk the JPEG markers to the frame header. Everything before it - EXIF, an embedded
    /// thumbnail, a colour profile - declares its own length and is skipped.
    ///
    /// A JPEG can also carry an EXIF **orientation**, which a web view applies when it draws
    /// the image; a page box sized from the unrotated frame header would then be the wrong
    /// shape and would clip the picture. So a quarter-turn orientation swaps the box's sides -
    /// the size reported here is the size the page is *displayed* at.
    private static func jpeg(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 4, b[0] == 0xff, b[1] == 0xd8 else { return nil }
        var i = 2
        var orientation = 1
        while i + 3 < b.count {
            guard b[i] == 0xff else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xff { i += 1; continue }
            // Standalone markers carry no length.
            if marker == 0x01 || (marker >= 0xd0 && marker <= 0xd9) { i += 2; continue }
            guard let length = be16(b, i + 2), length >= 2 else { return nil }
            if marker == 0xe1, let found = exifOrientation(b, at: i + 4, length: length - 2) {
                orientation = found
            }
            let isFrame = (marker >= 0xc0 && marker <= 0xcf)
                && marker != 0xc4 && marker != 0xc8 && marker != 0xcc
            if isFrame {
                guard var height = be16(b, i + 5), var width = be16(b, i + 7) else { return nil }
                if orientation >= 5, orientation <= 8 { swap(&width, &height) }
                return (width, height)
            }
            if marker == 0xda { return nil }   // image data started: no frame header seen
            i += 2 + length
        }
        return nil
    }

    /// The EXIF orientation tag (0x0112) out of an `APP1` payload, when there is one.
    private static func exifOrientation(_ b: [UInt8], at start: Int, length: Int) -> Int? {
        guard start + 14 <= b.count, length > 8,
              b[start] == 0x45, b[start + 1] == 0x78, b[start + 2] == 0x69,
              b[start + 3] == 0x66, b[start + 4] == 0x00, b[start + 5] == 0x00 else { return nil }
        let tiff = start + 6
        let little: Bool
        if b[tiff] == 0x49, b[tiff + 1] == 0x49 { little = true }
        else if b[tiff] == 0x4d, b[tiff + 1] == 0x4d { little = false }
        else { return nil }
        func u16(_ index: Int) -> Int? {
            guard index + 2 <= b.count else { return nil }
            return little ? Int(b[index]) | (Int(b[index + 1]) << 8)
                          : (Int(b[index]) << 8) | Int(b[index + 1])
        }
        func u32(_ index: Int) -> Int? {
            guard index + 4 <= b.count else { return nil }
            return little
                ? Int(b[index]) | (Int(b[index + 1]) << 8) | (Int(b[index + 2]) << 16) | (Int(b[index + 3]) << 24)
                : (Int(b[index]) << 24) | (Int(b[index + 1]) << 16) | (Int(b[index + 2]) << 8) | Int(b[index + 3])
        }
        guard let directoryOffset = u32(tiff + 4), let count = u16(tiff + directoryOffset) else { return nil }
        for entry in 0..<min(count, 512) {
            let base = tiff + directoryOffset + 2 + entry * 12
            guard let tag = u16(base) else { return nil }
            if tag == 0x0112, let value = u16(base + 8) { return value }
        }
        return nil
    }

    /// `RIFF....WEBP`, then a VP8 (lossy), VP8L (lossless) or VP8X (extended) chunk.
    private static func webp(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 30, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
              b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 else { return nil }
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8X":
            guard let width = le32(b, 24), let height = le32(b, 27) else { return nil }
            // 24-bit canvas size, stored as size minus one.
            return ((width & 0xff_ffff) + 1, (height & 0xff_ffff) + 1)
        case "VP8L":
            guard b[20] == 0x2f, let bits = le32(b, 21) else { return nil }
            return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
        case "VP8 ":
            guard let width = le16(b, 26), let height = le16(b, 28) else { return nil }
            return (width & 0x3fff, height & 0x3fff)
        default:
            return nil
        }
    }

    /// `BM`, then either the old core header (16-bit sizes) or any of the later ones.
    private static func bmp(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count > 26, b[0] == 0x42, b[1] == 0x4d, let headerSize = le32(b, 14) else { return nil }
        if headerSize == 12 {
            guard let width = le16(b, 18), let height = le16(b, 20) else { return nil }
            return (width, height)
        }
        guard let width = le32(b, 18), let height = le32(b, 22) else { return nil }
        return (abs(width), abs(height))
    }
}
