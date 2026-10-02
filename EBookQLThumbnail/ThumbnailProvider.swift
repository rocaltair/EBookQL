//
//  ThumbnailProvider.swift
//  EBookQLThumbnail
//
//  Draws a page card — title, author and the opening lines — instead of the
//  generic document icon the Finder shows for books it does not know.
//
//  The same `Book` the preview shows, parsed cheaply (openForThumbnail), so EPUB and
//  MOBI get the same card and a folder full of large books does not turn into a
//  memory storm.
//

import Cocoa
import QuickLookThumbnailing
import os.log
import EBookQLKit

final class ThumbnailProvider: QLThumbnailProvider {

    private let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Thumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        var size = request.maximumSize
        if size.width < 16 || size.height < 16 {
            size = CGSize(width: 256, height: 320)
        }

        let url = request.fileURL
        let started = Date()
        var title = url.deletingPathExtension().lastPathComponent
        var author: String?
        var body: String?

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookQLThumb_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        if let backend = BookOpener.backend(for: url) {
            do {
                let book = try backend.openForThumbnail(url, workDirectory: work)
                if let bookTitle = book.metadata.title, !bookTitle.isEmpty { title = bookTitle }
                author = book.metadata.author
                body = book.sections.first.flatMap { ThumbnailProvider.openingText($0.html) }
                os_log("thumb %{public}@ in %.2fs", log: log, type: .info,
                       url.lastPathComponent, Date().timeIntervalSince(started))
            } catch {
                os_log("thumb %{public}@ could not be parsed: %{public}@", log: log, type: .error,
                       url.lastPathComponent, error.localizedDescription)
            }
        }

        let reply = QLThumbnailReply(contextSize: size) { context -> Bool in
            ThumbnailProvider.drawCard(in: context, size: size, title: title,
                                       subtitle: author ?? url.pathExtension.uppercased(),
                                       body: body)
            return true
        }
        handler(reply, nil)
    }

    /// Enough of the opening to fill the card, without doing work proportional to the
    /// whole book.
    private static func openingText(_ html: String) -> String? {
        let limit = 200_000
        let window = html.count > limit ? String(html.prefix(limit)) : html
        let text = HTMLNormalizer.collapsedText(window)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(600))
    }

    // MARK: - Drawing

    /// Drawn through AppKit inside the provided CGContext.
    private static func drawCard(
        in context: CGContext,
        size: CGSize,
        title: String,
        subtitle: String?,
        body: String?
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let page = NSRect(origin: .zero, size: size)
        NSColor.white.setFill()
        page.fill()

        let margin = max(10, size.width * 0.08)
        let textRect = page.insetBy(dx: margin, dy: margin)

        var y = textRect.maxY - 8

        func draw(_ text: String, font: NSFont, color: NSColor, maxLines: Int) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            let lineHeight = font.ascender - font.descender + font.leading
            let available = max(0, y - textRect.minY)
            let limit = min(Int(available / max(1, lineHeight)), maxLines)
            guard limit > 0 else { return }
            let rect = NSRect(x: textRect.minX, y: y - lineHeight * CGFloat(limit),
                              width: textRect.width, height: lineHeight * CGFloat(limit))
            (text as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )
            y -= lineHeight * CGFloat(limit) + 8
        }

        let titleFontSize = max(9, min(20, size.width * 0.085))
        draw(title, font: .boldSystemFont(ofSize: titleFontSize), color: .black, maxLines: 3)
        if let subtitle, !subtitle.isEmpty {
            draw(subtitle, font: .systemFont(ofSize: titleFontSize * 0.7),
                 color: NSColor(white: 0.45, alpha: 1), maxLines: 1)
        }
        if let body, !body.isEmpty {
            draw(body, font: .systemFont(ofSize: titleFontSize * 0.62),
                 color: NSColor(white: 0.3, alpha: 1), maxLines: 6)
        }
    }
}
