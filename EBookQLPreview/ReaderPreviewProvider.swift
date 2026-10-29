//
//  ReaderPreviewProvider.swift
//  EBookQLPreview
//
//  Quick Look glue only: the panel's size, and `preparePreviewOfFile` handing the URL
//  to the shared reader host. Everything the reader does lives in
//  EBookQLReader/BookReaderViewController, which the app compiles too.
//

import AppKit
import QuickLookUI
import EBookQLKit

final class ReaderPreviewProvider: BookReaderViewController, QLPreviewingController {

    /// Quick Look panel size, as a fraction of the screen it opens on.
    /// Quick Look caps the panel itself, so these are "at most" values.
    private static let panelWidthFraction: CGFloat = 2.0 / 3.0
    private static let panelHeightFraction: CGFloat = 0.95

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        settingsProvider = { url in
            guard Self.readsSettings(url) else { return nil }
            let preferences = ReaderPreferences.load()
            return ReaderSettings(
                jsParse: preferences.jsParse,
                theme: preferences.theme,
                showLineNumbers: preferences.showLineNumbers,
                allowNetworkImages: preferences.allowNetworkImages,
                fb2ContentsFromText: preferences.fb2ContentsFromText
            )
        }
        loadBook(at: url) { completionHandler($0) }
    }

    /// Quick Look sizes its panel from this controller's `preferredContentSize`, and
    /// ignores it once the preview is on screen - so this runs as early as possible
    /// and again when the real screen is known.
    override func updatePanelSize() {
        guard let screen = view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        preferredContentSize = NSSize(
            width: min((frame.width * Self.panelWidthFraction).rounded(), visible.width),
            height: min((frame.height * Self.panelHeightFraction).rounded(), visible.height)
        )
    }

    /// The formats that read `settings.json`. The book appex wants the FB2 key even though it
    /// is not the Markdown one; the Markdown appex never sees an FB2 file, and neither appex
    /// pays for a settings read for EPUB/MOBI.
    private static func readsSettings(_ url: URL) -> Bool {
        MarkdownBackend.supportedExtensions.contains(url.pathExtension.lowercased())
            || FB2Backend.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
