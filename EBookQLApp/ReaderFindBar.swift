//
//  ReaderFindBar.swift
//  EBookQL
//
//  Native find chrome for app reader windows. Quick Look never loads this file's
//  views; it keeps using BookReaderViewController straight.
//

import AppKit
import WebKit

@MainActor
final class ReaderFindBar: NSVisualEffectView, NSSearchFieldDelegate {

    weak var webView: WKWebView?
    var onRequestClose: (() -> Void)?

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var pendingSearch: DispatchWorkItem?
    private var searchGeneration = 0
    private var submittedQuery = ""
    private var searchAvailable = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .headerView
        blendingMode = .withinWindow
        state = .active

        searchField.placeholderString = "Find in Book"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Find in Book")

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureButton(previousButton, symbol: "chevron.up", title: "Previous Match",
                        action: #selector(previousMatch))
        configureButton(nextButton, symbol: "chevron.down", title: "Next Match",
                        action: #selector(nextMatch))
        configureButton(closeButton, symbol: "xmark", title: "Close Find",
                        action: #selector(closeFind))
        previousButton.isEnabled = false
        nextButton.isEnabled = false

        let stack = NSStackView(views: [
            searchField, countLabel, previousButton, nextButton, closeButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let flexibleWidth = searchField.widthAnchor.constraint(equalToConstant: 260)
        flexibleWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            flexibleWidth,
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginSearch(available: Bool) {
        setSearchAvailable(available)
        DispatchQueue.main.async { [weak self] in
            self?.focus()
        }
    }

    func focus() {
        guard searchAvailable else { return }
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        if searchField.stringValue.isEmpty {
            countLabel.stringValue = ""
        }
    }

    func findNext() {
        step(1)
    }

    func findPrevious() {
        step(-1)
    }

    func endSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchGeneration += 1
        submittedQuery = ""
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        countLabel.stringValue = ""
        webView?.evaluateJavaScript(
            "window.ekbFindClose ? window.ekbFindClose() : null",
            completionHandler: nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        pendingSearch?.cancel()
        pendingSearch = nil
        let query = trimmedQuery
        if query.isEmpty {
            endSearch()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runSearch(query)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onRequestClose?()
            return true
        }
        let submits = commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertLineBreak(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        guard submits else { return false }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        step(backwards ? -1 : 1)
        return true
    }

    private var trimmedQuery: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setSearchAvailable(_ available: Bool) {
        searchAvailable = available
        searchField.isEnabled = available
        if available {
            countLabel.stringValue = submittedQuery.isEmpty ? "" : countLabel.stringValue
        } else {
            pendingSearch?.cancel()
            pendingSearch = nil
            searchGeneration += 1
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            countLabel.stringValue = "No text to search"
        }
    }

    private func configureButton(
        _ button: NSButton, symbol: String, title: String, action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func step(_ direction: Int) {
        guard searchAvailable else { return }
        let query = trimmedQuery
        guard !query.isEmpty else {
            focus()
            return
        }
        if query != submittedQuery {
            runSearch(query)
            return
        }
        oneShotJavaScript(
            "window.ekbFindStep ? window.ekbFindStep(\(direction)) : null")
    }

    private func runSearch(_ query: String) {
        pendingSearch?.cancel()
        pendingSearch = nil
        submittedQuery = query
        countLabel.stringValue = "..."
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        oneShotJavaScript(
            "window.ekbFind ? window.ekbFind(\(javascriptString(query))) : null")
    }

    private func oneShotJavaScript(_ source: String) {
        searchGeneration += 1
        let generation = searchGeneration
        webView?.evaluateJavaScript(source) { [weak self] result, error in
            guard let self, self.searchGeneration == generation else { return }
            if error != nil {
                self.showUnavailable()
                return
            }
            guard let body = result as? [String: Any] else {
                self.showUnavailable()
                return
            }
            self.apply(body)
        }
    }

    private func apply(_ body: [String: Any]) {
        let available = boolValue(body["available"]) ?? false
        searchAvailable = available
        searchField.isEnabled = available
        if !available {
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            countLabel.stringValue = "No text to search"
            return
        }

        let total = intValue(body["total"]) ?? 0
        let index = intValue(body["index"]) ?? 0
        let capped = boolValue(body["capped"]) ?? false
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
        if total == 0 {
            countLabel.stringValue = "No matches"
        } else {
            countLabel.stringValue = "\(index) of \(total)\(capped ? "+" : "")"
        }
    }

    private func showUnavailable() {
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        countLabel.stringValue = "Find unavailable"
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func javascriptString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    @objc private func previousMatch() {
        step(-1)
    }

    @objc private func nextMatch() {
        step(1)
    }

    @objc private func closeFind() {
        onRequestClose?()
    }
}

@MainActor
final class ReaderWindowContentViewController: NSViewController {

    let reader: BookReaderViewController
    private let findBar = ReaderFindBar()
    private var findBarHeight: NSLayoutConstraint!
    private(set) var isFinding = false

    init(reader: BookReaderViewController) {
        self.reader = reader
        super.init(nibName: nil, bundle: nil)
        findBar.onRequestClose = { [weak self] in
            self?.hideFind()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addChild(reader)
        _ = reader.view
        findBar.webView = reader.webView
        findBar.translatesAutoresizingMaskIntoConstraints = false
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(findBar)
        root.addSubview(reader.view)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: root.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBarHeight,
            reader.view.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            reader.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        findBar.isHidden = true
        view = root
    }

    func showFind() {
        _ = view
        if !isFinding {
            isFinding = true
            findBarHeight.constant = 38
            findBar.isHidden = false
            view.layoutSubtreeIfNeeded()
        }
        findBar.beginSearch(available: reader.supportsTextSearch)
    }

    func hideFind() {
        guard isFinding else { return }
        isFinding = false
        findBar.endSearch()
        findBarHeight.constant = 0
        findBar.isHidden = true
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(reader.webView)
    }

    func findNext() {
        if !isFinding { showFind() }
        findBar.findNext()
    }

    func findPrevious() {
        if !isFinding { showFind() }
        findBar.findPrevious()
    }
}
