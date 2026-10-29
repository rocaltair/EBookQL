//
//  ReaderWindows.swift
//  EBookQL
//
//  The app's reader windows. One window per book, keyed by URL, so opening the same
//  book again brings its reader forward instead of stacking a second copy.
//
//  The window is an ordinary NSWindow holding BookReaderViewController - the same
//  controller the Quick Look appexes use - so the app has no second reader to keep
//  in step. The configuration window is SettingsWindow, also an AppKit window.
//

import AppKit
import Combine
import UniformTypeIdentifiers
import os.log
import EBookQLKit

@MainActor
final class ReaderWindows: NSObject, NSWindowDelegate {

    static let shared = ReaderWindows()

    private var windows: [URL: NSWindow] = [:]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: SettingsStore.didChange, object: nil)
    }

    @objc private func settingsChanged() {
        settingsDidChange()
    }

    var isEmpty: Bool { windows.isEmpty }

    /// Every format the app can open, as UTIs, for the Open panel.
    static let openableTypes: [UTType] = {
        let extensions = ["epub", "mobi", "azw", "azw3", "fb2", "djvu", "djv",
                          "cbz", "cbt", "chm", "md", "markdown", "mdx"]
        let known = extensions.compactMap { UTType(filenameExtension: $0) }
        var seen = Set<String>()
        return known.filter { seen.insert($0.identifier).inserted }
    }()

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = windows[url] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard BookOpener.backend(for: url) != nil else { return }

        let reader = BookReaderViewController()
        reader.readingPositionStore = ReadingPositionStore(databasePath: SettingsStore.sharedPositionsPath)
        reader.settingsProvider = { _ in SettingsStore.readerSettings() }
        reader.opensExternalLinks = true
        reader.workDirectoryPrefix = "EBookQLReader_"
        reader.staleWorkDirectoryAge = 24 * 60 * 60

        let window = NSWindow(contentViewController: reader)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.minSize = NSSize(width: 480, height: 400)
        window.setContentSize(NSSize(width: 1000, height: 900))
        window.setFrameAutosaveName("EBookQLReaderWindow")
        window.delegate = self
        windows[url] = window

        reader.onBookOpened = { [weak window] info in
            let parts = [info.title, info.author].compactMap { $0 }.filter { !$0.isEmpty }
            window?.title = parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " — ")
        }
        reader.onFailure = { [weak window] error in
            window?.title = url.lastPathComponent
            os_log("reader failed: %{public}@", type: .error, error.localizedDescription)
        }

        reader.loadBook(at: url)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentBooks.shared.refresh()
    }

    /// The app menu's Open…: one panel for every format EBookQL claims.
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    /// Settings changes reach the reader through the app's own notification, not a
    /// file read: only the formats the settings actually affect are reloaded, and the
    /// reload resumes from the position the reader was already at.
    func settingsDidChange() {
        for (url, window) in windows {
            guard let reader = window.contentViewController as? BookReaderViewController else { continue }
            let ext = url.pathExtension.lowercased()
            let affected = MarkdownBackend.supportedExtensions.contains(ext)
                || FB2Backend.supportedExtensions.contains(ext)
            guard affected else { continue }
            reader.loadBook(at: url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

/// The Open Recent submenu's contents. Kept as a small observable so the menu
/// rebuilds when a window is opened, without making every reader window track it.
@MainActor
final class RecentBooks: ObservableObject {
    static let shared = RecentBooks()

    @Published private(set) var urls: [URL] = []

    private init() {
        refresh()
    }

    func refresh() {
        urls = Array(NSDocumentController.shared.recentDocumentURLs.prefix(10))
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
}
