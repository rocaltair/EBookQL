//
//  BookReaderViewController.swift
//  EBookQLReader
//
//  The reader host: one WKWebView showing one generated page, one reading position.
//  It is shared by the Quick Look preview appexes and the app, so it knows nothing
//  about Quick Look - panel sizing and `preparePreviewOfFile` live in the appex
//  subclass, window placement and menus in the app.
//
//  Everything below is the same code the appex used when it was the only host: pick
//  a backend, ask the renderer for the page, host it, and report the position back.
//

import AppKit
import WebKit
import os.log
import EBookQLKit

class BookReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    struct BookInfo {
        let url: URL
        let title: String?
        let author: String?
    }

    /// Page zoom (the sidebar's A− / A+ buttons, or ⌘-scroll) scales the whole page, and
    /// the sidebar counter-scales itself so the chrome keeps its size. A ladder rather
    /// than a multiplier so steps stay predictable; it is remembered per host.
    private static let zoomKey = "previewZoom"
    private static let sidebarWidthKey = "readerSidebarWidth"
    private static let autoFoldTOCKey = "readerAutoFoldTOC"
    static let zoomLevels: [CGFloat] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]

    private static var storedZoom: CGFloat {
        let value = CGFloat(UserDefaults.standard.object(forKey: zoomKey) as? Double ?? 1.0)
        return min(max(value, zoomLevels.first!), zoomLevels.last!)
    }

    /// Unset means on. Read through `NSNumber` rather than `as? Bool` so a stored value
    /// of an unexpected type can never be mistaken for "never set".
    private static var storedAutoFold: Bool {
        (UserDefaults.standard.object(forKey: autoFoldTOCKey) as? NSNumber)?.boolValue ?? true
    }

    private enum Message {
        static let position = "ekbPosition"
        static let zoom = "ekbZoom"
        static let ui = "ekbUI"
        static let copy = "ekbCopy"
    }

    let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Reader")
    private(set) var webView: WKWebView!
    private var schemeHandler: ReaderSchemeHandler!
    private var startedAt: Date?
    private var scopedResourceURL: URL?
    private(set) var workDirectory: URL?
    private(set) var currentBookURL: URL?
    private var currentBookSize: Int?
    private var zoom: CGFloat = BookReaderViewController.storedZoom
    private var lastZoomCommand = Date.distantPast
    /// Identifies the in-flight load, so a slow render for a book the reader has
    /// already navigated away from cannot paint over the newer one.
    private var generation = UUID()

    /// Where this host's rendering choices come from. Nil for a format that has no
    /// settings of its own, which keeps EPUB/MOBI from paying for a settings read.
    var settingsProvider: ((URL) -> ReaderSettings?)?
    /// The app names the preview extension's database so a book keeps one position in
    /// both hosts; the appexes keep the default, inside their own sandbox container.
    var readingPositionStore = ReadingPositionStore.shared
    var onBookOpened: ((BookInfo) -> Void)?
    var onFailure: ((Error) -> Void)?
    /// Whether a clicked http/https/mailto link is handed to the browser instead of
    /// navigating the reader away from the book. Quick Look leaves this off, so its
    /// behaviour is unchanged.
    var opensExternalLinks = false
    /// Distinct from the appex prefix so neither host's stale-directory sweep can
    /// delete a directory another live host is still reading from.
    var workDirectoryPrefix = "EBookQL_"
    var staleWorkDirectoryAge: TimeInterval = 300

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()

        let handler = ReaderSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
        self.schemeHandler = handler

        for name in [Message.position, Message.zoom, Message.ui, Message.copy] {
            configuration.userContentController.add(self, name: name)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        updatePanelSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updatePanelSize()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        releaseSecurityScope()
    }

    deinit {
        releaseSecurityScope()
    }

    /// A hook: Quick Look overrides it to ask for a panel two thirds of the screen;
    /// a window already has its own size.
    func updatePanelSize() {}

    // MARK: - Loading

    func loadBook(at url: URL, completion: ((Error?) -> Void)? = nil) {
        startedAt = Date()
        os_log("open %{public}@", log: log, type: .info, url.path)

        // Ensure the view (and so the web view) exists before the async work starts.
        _ = view

        // The archive is read lazily while the reader scrolls, so the security scope
        // has to stay open for the whole read, not just the parsing step.
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() { scopedResourceURL = url }
        currentBookURL = url.standardizedFileURL

        let bookSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        currentBookSize = bookSize

        let savedPosition = readingPositionStore.position(for: url, size: bookSize)
        if let savedPosition {
            os_log("restoring anchor=%{public}@ fraction=%.3f",
                   log: log, type: .info, savedPosition.anchor ?? "-", savedPosition.fraction)
        }

        // Reclaim the previous load's extraction before making a new one.
        if let previous = workDirectory {
            try? FileManager.default.removeItem(at: previous)
            workDirectory = nil
        }
        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(workDirectoryPrefix)\(UUID().uuidString)")
        self.workDirectory = workDirectory
        // Created here rather than by the backend: a file whose format has no
        // backend yet still needs somewhere to put its page, and a backend that
        // forgot to make it would fail with an error page instead of a reader.
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        Self.removeStaleWorkDirectories(
            prefix: workDirectoryPrefix, keeping: workDirectory, olderThan: staleWorkDirectoryAge)

        let token = UUID()
        generation = token

        webView.loadHTMLString(Self.loadingHTML(for: url), baseURL: nil)
        // Stop Finder's spinner promptly; the page fills in after.
        completion?(nil)

        let settings = settingsProvider?(url) ?? ReaderSettings()
        let options = ReaderDocument.Options(
            readingPosition: savedPosition,
            sidebarWidth: UserDefaults.standard.object(forKey: Self.sidebarWidthKey) as? Int,
            autoFoldTOC: Self.storedAutoFold,
            zoom: Double(zoom),
            allowNetworkImages: settings.allowNetworkImages,
            fb2ContentsFromText: settings.fb2ContentsFromText,
            tocTitle: ReaderDocument.localizedTOCTitle(),
            theme: Self.resolvedTheme(settings.theme),
            markdownRendering: settings.jsParse,
            showLineNumbers: settings.showLineNumbers
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let rendered = try Self.render(url: url, workDirectory: workDirectory, options: options)
                let indexURL = workDirectory.appendingPathComponent("index.html")
                let writeStart = Date()
                try rendered.html.write(to: indexURL, atomically: true, encoding: .utf8)
                let writeTime = Date().timeIntervalSince(writeStart)

                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    // Hand the archive to the scheme handler before the page loads, so
                    // the images it asks for never need another trip to the volume.
                    self.schemeHandler.source = rendered.resources
                    self.webView.loadFileURL(indexURL, allowingReadAccessTo: workDirectory)
                    self.updatePanelSize()
                    if let url = self.currentBookURL {
                        self.readingPositionStore.noteOpened(
                            url, title: rendered.title, author: rendered.author, size: self.currentBookSize)
                        self.onBookOpened?(BookInfo(url: url, title: rendered.title, author: rendered.author))
                    }
                    os_log("rendered %.2fs (write %.2fs), %{public}d sections, %{public}d bytes of html",
                           log: self.log, type: .info,
                           Date().timeIntervalSince(started), writeTime,
                           rendered.sections, rendered.html.utf8.count)
                }
            } catch {
                os_log("reader error: %{public}@", log: self.log, type: .error,
                       error.localizedDescription)
                let html = ReaderDocument.noticeHTML(
                    summary: Self.summary(for: error),
                    detail: error.localizedDescription,
                    fileName: url.lastPathComponent,
                    options: options
                )
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.schemeHandler.source = nil
                    self.webView.loadHTMLString(html, baseURL: nil)
                    self.onFailure?(error)
                }
            }
        }
    }

    private struct Rendered {
        let html: String
        let resources: ResourceSource?
        let sections: Int
        let title: String?
        let author: String?
    }

    /// Parses the book and builds the page. Runs off the main thread.
    private static func render(url: URL, workDirectory: URL, options: ReaderDocument.Options) throws -> Rendered {
        guard BookOpener.backend(for: url) != nil else {
            return Rendered(html: ReaderDocument.placeholderHTML(fileName: url.lastPathComponent, options: options),
                            resources: nil, sections: 0, title: nil, author: nil)
        }
        let t0 = Date()
        // One call for every format: the facade picks the backend by extension and hands each
        // one only what it understands - `markdownRendering` reaches Markdown alone (it decides
        // between the rendered page and the raw source) and `contentsFromText` reaches FB2 alone
        // (whether a file with no `<title>` may have its contents guessed).
        let book = try BookOpener.open(
            url,
            workDirectory: workDirectory,
            markdownRendering: options.markdownRendering,
            contentsFromText: options.fb2ContentsFromText
        )
        let t1 = Date()
        let page = try ReaderDocument.build(book, options: options)
        let t2 = Date()
        os_log("open %.2fs build %.2fs", log: renderLog, type: .info,
               t1.timeIntervalSince(t0), t2.timeIntervalSince(t1))
        return Rendered(html: page.html,
                        resources: book.resources as? ResourceSource,
                        sections: book.sections.count,
                        title: book.metadata.title,
                        author: book.metadata.author)
    }

    /// `.system` becomes a concrete scheme from the host's own appearance, because the
    /// page cannot see the system's choice and a forced scheme must beat
    /// `prefers-color-scheme`. Light when AppKit cannot tell.
    private static func resolvedTheme(_ theme: MarkdownTheme) -> MarkdownTheme {
        guard theme == .system else { return theme }
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    private static let renderLog = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Render")

    private static func summary(for error: Error) -> String {
        switch error {
        case BookParseError.encrypted: return "This book is encrypted"
        case BookParseError.unsupportedFormat: return "Unsupported book type"
        case BookParseError.corrupt: return "Damaged book data"
        case BookParseError.malformed, BookParseError.opfNotFound, BookParseError.containerNotFound:
            return "This EPUB could not be read"
        default: return "Cannot open this book"
        }
    }

    // MARK: - Script messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Copy is the one message that carries a bare string rather than a dictionary.
        if message.name == Message.copy {
            handleCopy(message.body)
            return
        }
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case Message.position: handlePosition(body)
        case Message.zoom: handleZoom(body)
        case Message.ui: handleUI(body)
        default: break
        }
    }

    private func handleCopy(_ body: Any) {
        guard let text = body as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        os_log("copy %{public}d chars to pasteboard", log: log, type: .debug, text.count)
    }

    private func handlePosition(_ body: [String: Any]) {
        guard let url = currentBookURL else { return }
        let position = ReadingPosition(
            anchor: body["anchor"] as? String,
            sectionOffset: body["sectionOffset"] as? Double ?? 0,
            fraction: body["fraction"] as? Double ?? 0,
            scrollY: body["scrollY"] as? Double ?? 0,
            updated: Date().timeIntervalSince1970
        )
        readingPositionStore.store(position, for: url, size: currentBookSize)
        os_log("position %{public}@ anchor=%{public}@ section=%.3f fraction=%.4f",
               log: log, type: .debug,
               url.lastPathComponent, position.anchor ?? "(none)",
               position.sectionOffset, position.fraction)
    }

    private func handleUI(_ body: [String: Any]) {
        if let phase = body["phase"] as? String {
            os_log("page %{public}@ at %{public}d ms", log: log, type: .info, phase,
                   body["ms"] as? Int ?? -1)
            return
        }
        // Both settings the page owns: the sidebar width it was dragged to and the
        // auto-fold mode it was switched to. Each is stored on its own, so a message
        // carrying one does not have to carry the other.
        if let width = body["sidebarWidth"] as? Int {
            UserDefaults.standard.set(min(max(width, 80), 2000), forKey: Self.sidebarWidthKey)
        }
        if let autoFold = (body["autoFoldTOC"] as? NSNumber)?.boolValue {
            UserDefaults.standard.set(autoFold, forKey: Self.autoFoldTOCKey)
        }
    }

    /// The page's controls report a step; the host clamps it, applies it, and tells the
    /// page what it settled on.
    private func handleZoom(_ body: [String: Any]) {
        let step = body["step"] as? Int ?? 0
        let isReset = (step == 0)
        let now = Date()
        if !isReset {
            // At most one step per keystroke/click; the page's hold-to-repeat is
            // deliberately slower than this.
            guard now.timeIntervalSince(lastZoomCommand) > 0.15 else { return }
        }
        lastZoomCommand = now
        if isReset {
            applyZoom(1.0)
        } else {
            stepZoom(by: step)
        }
    }

    private func stepZoom(by steps: Int) {
        guard steps != 0 else { return }
        let index = Self.zoomLevels.enumerated()
            .min { abs($0.element - zoom) < abs($1.element - zoom) }?.offset ?? 4
        let target = min(max(index + steps, 0), Self.zoomLevels.count - 1)
        guard target != index else { return }
        applyZoom(Self.zoomLevels[target])
    }

    private func applyZoom(_ level: CGFloat) {
        let clamped = min(max(level, Self.zoomLevels.first!), Self.zoomLevels.last!)
        zoom = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.zoomKey)
        // Deliberately not `webView.pageZoom`: that scales the whole page, panel-sized
        // layout and sidebar included, so the reader's divider and window move under them
        // for a change they made to the text. The page scales the book's text alone.
        webView.evaluateJavaScript("window.ekbSetZoom && window.ekbSetZoom(\(clamped))",
                                   completionHandler: nil)
        os_log("zoom %{public}d percent", log: log, type: .info, Int((clamped * 100).rounded()))
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.ekbSetZoom && window.ekbSetZoom(\(zoom))", completionHandler: nil)
        guard let startedAt else { return }
        os_log("render finished %.2fs after load", log: log, type: .info, Date().timeIntervalSince(startedAt))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard opensExternalLinks,
              navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: - Bookkeeping

    private func releaseSecurityScope() {
        scopedResourceURL?.stopAccessingSecurityScopedResource()
        scopedResourceURL = nil
    }

    private static func loadingHTML(for url: URL) -> String {
        """
        <html><body style="font: -apple-system-body; padding:24px">
        <p>Opening \(HTMLNormalizer.escapeHTML(url.lastPathComponent))…</p>
        </body></html>
        """
    }

    /// Quick Look hands each preview to a fresh extension instance, so a per-instance
    /// cleanup is not enough: sweep extraction folders older than a few minutes (a
    /// currently displayed preview keeps its folder, hence the threshold). The prefix
    /// keeps one host's sweep away from another host's live directories.
    private static func removeStaleWorkDirectories(
        prefix: String, keeping current: URL, olderThan age: TimeInterval
    ) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard entry.standardizedFileURL != current.standardizedFileURL else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
