//
//  ReaderPreviewProvider.swift
//  EBookQLPreview
//
//  View-based Quick Look preview: we host a WKWebView, which is what makes the
//  reading position possible (the page reports where it is over a script message
//  and the store keeps that, then hands it back when the book is opened again).
//  A data-based preview renders in Quick Look's own web view, which has no channel
//  back to the extension.
//
//  This file is only Quick Look glue: pick a backend, ask the renderer for the page,
//  host it. Every format goes through exactly the same path.
//

import AppKit
import QuickLookUI
import WebKit
import os.log
import EBookQLKit

final class ReaderPreviewProvider: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {

    /// Quick Look panel size, as a fraction of the screen it opens on.
    /// Quick Look caps the panel itself, so these are "at most" values.
    private static let panelWidthFraction: CGFloat = 2.0 / 3.0
    private static let panelHeightFraction: CGFloat = 0.95

    /// Page zoom (the sidebar's A− / A+ buttons, or ⌘-scroll), like a browser's: it
    /// scales the whole page, and the sidebar counter-scales itself so the chrome
    /// keeps its size. A ladder rather than a multiplier so steps stay predictable,
    /// and it is remembered across previews.
    private static let zoomKey = "previewZoom"
    private static let sidebarWidthKey = "readerSidebarWidth"
    private static let zoomLevels: [CGFloat] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]

    private static var storedZoom: CGFloat {
        let value = CGFloat(UserDefaults.standard.object(forKey: zoomKey) as? Double ?? 1.0)
        return min(max(value, zoomLevels.first!), zoomLevels.last!)
    }

    private enum Message {
        static let position = "ekbPosition"
        static let zoom = "ekbZoom"
        static let ui = "ekbUI"
    }

    private let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Preview")
    private var webView: WKWebView!
    private var schemeHandler: ReaderSchemeHandler!
    private var startedAt: Date?
    private var scopedResourceURL: URL?
    private var workDirectory: URL?
    private var currentBookURL: URL?
    private var currentBookSize: Int?
    private var zoom: CGFloat = ReaderPreviewProvider.storedZoom
    private var lastZoomCommand = Date.distantPast

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()

        // Images/fonts stay inside the book; this serves them straight from the archive.
        let handler = ReaderSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
        self.schemeHandler = handler

        for name in [Message.position, Message.zoom, Message.ui] {
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

        applyPreferredPanelSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPreferredPanelSize()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        releaseSecurityScope()
    }

    deinit {
        releaseSecurityScope()
    }

    /// Quick Look sizes its panel from this controller's `preferredContentSize`, and
    /// ignores it once the preview is on screen - so this runs as early as possible
    /// and again when the real screen is known.
    private func applyPreferredPanelSize() {
        guard let screen = view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        preferredContentSize = NSSize(
            width: min((frame.width * Self.panelWidthFraction).rounded(), visible.width),
            height: min((frame.height * Self.panelHeightFraction).rounded(), visible.height)
        )
    }

    // MARK: - Quick Look entry point

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        startedAt = Date()
        os_log("preparePreviewOfFile %{public}@", log: log, type: .info, url.path)

        // Ensure the view (and so the web view) exists before the async work starts.
        _ = view

        // The archive is read lazily while the reader scrolls, so the security scope
        // has to stay open for the whole preview, not just the parsing step.
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() { scopedResourceURL = url }
        currentBookURL = url.standardizedFileURL

        let bookSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        currentBookSize = bookSize

        // Where the reader stopped last time. The store keys on the path and checks the
        // file size, so a different book at the same path does not inherit a position.
        let savedPosition = ReadingPositionStore.shared.position(for: url, size: bookSize)
        if let savedPosition {
            os_log("restoring anchor=%{public}@ fraction=%.3f",
                   log: log, type: .info, savedPosition.anchor ?? "-", savedPosition.fraction)
        }

        // Reclaim the previous preview's extraction before making a new one: each
        // preview unpacks the book's text and nothing else would clean it up.
        if let previous = workDirectory {
            try? FileManager.default.removeItem(at: previous)
            workDirectory = nil
        }
        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookQL_\(UUID().uuidString)")
        self.workDirectory = workDirectory
        // Created here rather than by the backend: a file whose format has no
        // backend yet still needs somewhere to put its page, and a backend that
        // forgot to make it would fail with an error page instead of a preview.
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        Self.removeStaleWorkDirectories(keeping: workDirectory)

        webView.loadHTMLString(Self.loadingHTML(for: url), baseURL: nil)
        // Stop Finder's spinner promptly; the page fills in after.
        completionHandler(nil)

        let options = ReaderDocument.Options(
            readingPosition: savedPosition,
            sidebarWidth: UserDefaults.standard.object(forKey: Self.sidebarWidthKey) as? Int,
            zoom: Double(zoom),
            tocTitle: ReaderDocument.localizedTOCTitle()
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
                    // Hand the archive to the scheme handler before the page loads, so
                    // the images it asks for never need another trip to the volume.
                    self.schemeHandler.source = rendered.resources
                    self.webView.loadFileURL(indexURL, allowingReadAccessTo: workDirectory)
                    self.applyPreferredPanelSize()
                    if let url = self.currentBookURL {
                        ReadingPositionStore.shared.noteOpened(
                            url, title: rendered.title, author: rendered.author, size: self.currentBookSize)
                    }
                    os_log("rendered %.2fs (write %.2fs), %{public}d sections, %{public}d bytes of html",
                           log: self.log, type: .info,
                           Date().timeIntervalSince(started), writeTime,
                           rendered.sections, rendered.html.utf8.count)
                }
            } catch {
                os_log("preview error: %{public}@", log: self.log, type: .error,
                       error.localizedDescription)
                let html = ReaderDocument.noticeHTML(
                    summary: Self.summary(for: error),
                    detail: error.localizedDescription,
                    fileName: url.lastPathComponent,
                    options: options
                )
                DispatchQueue.main.async {
                    self.schemeHandler.source = nil
                    self.webView.loadHTMLString(html, baseURL: nil)
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
        guard let backend = BookOpener.backend(for: url) else {
            return Rendered(html: ReaderDocument.placeholderHTML(fileName: url.lastPathComponent, options: options),
                            resources: nil, sections: 0, title: nil, author: nil)
        }
        let t0 = Date()
        let book = try backend.open(url, workDirectory: workDirectory)
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

    private static let renderLog = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Render")

    private static func summary(for error: Error) -> String {
        switch error {
        case BookParseError.encrypted: return "This book is encrypted"
        case BookParseError.unsupportedFormat: return "Unsupported book type"
        case BookParseError.corrupt: return "Damaged book data"
        case BookParseError.malformed, BookParseError.opfNotFound, BookParseError.containerNotFound:
            return "This EPUB could not be read"
        default: return "Cannot preview this book"
        }
    }

    // MARK: - Script messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case Message.position: handlePosition(body)
        case Message.zoom: handleZoom(body)
        case Message.ui: handleUI(body)
        default: break
        }
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
        ReadingPositionStore.shared.store(position, for: url, size: currentBookSize)
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
        guard let width = body["sidebarWidth"] as? Int else { return }
        UserDefaults.standard.set(min(max(width, 80), 2000), forKey: Self.sidebarWidthKey)
    }

    /// The page's controls report a step; the extension clamps it, applies it, and
    /// tells the page what it settled on.
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
        os_log("render finished %.2fs after preparePreviewOfFile",
               log: log, type: .info, Date().timeIntervalSince(startedAt))
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

    /// Quick Look often hands each preview to a fresh extension instance, so a
    /// per-instance cleanup is not enough: sweep extraction folders older than a few
    /// minutes (a currently displayed preview keeps its folder, hence the threshold).
    private static func removeStaleWorkDirectories(keeping current: URL, olderThan age: TimeInterval = 300) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix("EBookQL_") {
            guard entry.standardizedFileURL != current.standardizedFileURL else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
