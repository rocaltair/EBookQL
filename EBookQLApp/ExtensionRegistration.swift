//
//  ExtensionRegistration.swift
//  EBookQL
//
//  Registers the Quick Look and Markdown extensions with the system, and reports what the
//  system actually thinks of them.
//
//  Dragging the app into /Applications and opening it once is normally enough: measured on
//  this machine, the copy alone registers nothing, and the first launch registers them all
//  and leaves them enabled. This file exists for the cases where that is not
//  enough - an older copy elsewhere winning the registration, or an extension the user has
//  switched off - and so the window can show the real state instead of describing it.
//

import AppKit
import Foundation

enum ExtensionRegistration {
    static let previewID = "com.rocaltair.EBookQL.Preview"
    static let thumbnailID = "com.rocaltair.EBookQL.Thumbnail"
    static let markdownPreviewID = "com.rocaltair.EBookQL.MarkdownPreview"
    static let markdownThumbnailID = "com.rocaltair.EBookQL.MarkdownThumbnail"
    /// The CHM pair. Off by default: registered so pluginkit knows them, ignored until the
    /// user ticks the box (see `setCHMEnabled`).
    static let chmPreviewID = "com.rocaltair.EBookQL.CHMPreview"
    static let chmThumbnailID = "com.rocaltair.EBookQL.CHMThumbnail"

    private static let allIDs = [previewID, thumbnailID, markdownPreviewID, markdownThumbnailID,
                                 chmPreviewID, chmThumbnailID]
    private static let chmIDs = [chmPreviewID, chmThumbnailID]

    private static let pluginkit = "/usr/bin/pluginkit"
    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// What the system has, for one extension.
    struct Extension: Identifiable {
        let id: String
        let title: String
        /// Which formats this extension is for. Shown as the row's tooltip: the titles
        /// name the extension, and the formats are what a reader actually wants to know.
        let help: String
        /// Where it is registered from, when it is registered at all.
        var path: String?
        var enabled: Bool

        var registered: Bool { path != nil }
        /// Registered, but from a different copy of the app than the one running.
        var fromAnotherCopy: Bool {
            guard let path else { return false }
            return !path.hasPrefix(Bundle.main.bundleURL.path + "/")
        }
        var summary: String {
            guard let path else { return "not registered" }
            return (enabled ? "enabled" : "switched off") + " — " + path
        }
    }

    /// The extensions as the system currently has them, in display order.
    static func survey() -> [Extension] {
        let listed = pluginkitListing()
        return [Extension(id: previewID, title: "Quick Look preview",
                          help: "Preview panel for EPUB, MOBI, AZW, AZW3, FictionBook, DjVu and CBZ books.",
                          path: listed[previewID]?.path, enabled: listed[previewID]?.enabled ?? false),
                Extension(id: thumbnailID, title: "Finder thumbnails",
                          help: "Finder cards for the same books: EPUB, MOBI, AZW, AZW3, FictionBook, DjVu and CBZ.",
                          path: listed[thumbnailID]?.path, enabled: listed[thumbnailID]?.enabled ?? false),
                Extension(id: markdownPreviewID, title: "Markdown Preview",
                          help: "Preview panel for .md, .markdown and .mdx — math and diagrams included.",
                          path: listed[markdownPreviewID]?.path, enabled: listed[markdownPreviewID]?.enabled ?? false),
                Extension(id: markdownThumbnailID, title: "Markdown Thumbnail",
                          help: "Finder cards for .md, .markdown and .mdx.",
                          path: listed[markdownThumbnailID]?.path, enabled: listed[markdownThumbnailID]?.enabled ?? false),
                Extension(id: chmPreviewID, title: "CHM Preview",
                          help: "Preview panel for .chm help files. Off until this is switched on.",
                          path: listed[chmPreviewID]?.path, enabled: listed[chmPreviewID]?.enabled ?? false),
                Extension(id: chmThumbnailID, title: "CHM Thumbnail",
                          help: "Finder cards for .chm help files.",
                          path: listed[chmThumbnailID]?.path, enabled: listed[chmThumbnailID]?.enabled ?? false)]
    }

    /// Ask the system to take this copy of the app, then make sure it is switched on -
    /// but never fight a deliberate switch-off: an extension registered and disabled stays
    /// that way, and the window says so.
    static func register() {
        let app = Bundle.main.bundleURL.path
        run(lsregister, ["-f", app])
        for appex in appexPaths() {
            run(pluginkit, ["-a", appex])
        }
        for id in allIDs where pluginkitListing()[id] == nil {
            // Registering an extension is not the same as switching it on: CHM ships off, so
            // the first sight of its appexes leaves them ignored (the box in the window is
            // what turns them on, and nothing here overrides that afterwards).
            run(pluginkit, ["-e", chmIDs.contains(id) ? "ignore" : "use", "-i", id])
        }
    }

    /// True only when both markdown extensions are registered and switched on.
    static func markdownEnabled() -> Bool {
        let listed = pluginkitListing()
        return listed[markdownPreviewID]?.enabled == true
            && listed[markdownThumbnailID]?.enabled == true
    }

    /// Switch both markdown extensions on or off. Turning one on also registers its
    /// appex first when the system has never seen it, but a deliberate switch-off is
    /// never overridden.
    static func setMarkdownEnabled(_ enabled: Bool) {
        let listed = pluginkitListing()
        for (id, appexName) in [(markdownPreviewID, "EBookQLMarkdownPreview.appex"),
                                (markdownThumbnailID, "EBookQLMarkdownThumbnail.appex")] {
            if enabled {
                if listed[id] == nil, let appex = appexPath(named: appexName) {
                    run(pluginkit, ["-a", appex])
                }
                run(pluginkit, ["-e", "use", "-i", id])
            } else {
                run(pluginkit, ["-e", "ignore", "-i", id])
            }
        }
    }

    /// True only when both CHM extensions are registered and switched on.
    static func chmEnabled() -> Bool {
        let listed = pluginkitListing()
        return listed[chmPreviewID]?.enabled == true && listed[chmThumbnailID]?.enabled == true
    }

    /// Switch both CHM extensions on or off, registering the appexes first when the system
    /// has never seen them. Off is the shipped default.
    static func setCHMEnabled(_ enabled: Bool) {
        let listed = pluginkitListing()
        for (id, appexName) in [(chmPreviewID, "EBookQLCHMPreview.appex"),
                                (chmThumbnailID, "EBookQLCHMThumbnail.appex")] {
            if enabled {
                if listed[id] == nil, let appex = appexPath(named: appexName) {
                    run(pluginkit, ["-a", appex])
                }
                run(pluginkit, ["-e", "use", "-i", id])
            } else {
                run(pluginkit, ["-e", "ignore", "-i", id])
            }
        }
    }

    /// Open the pane where a switched-off extension can be turned back on.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private static func appexPaths() -> [String] {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return [] }
        return ["EBookQLPreview.appex", "EBookQLThumbnail.appex",
                "EBookQLMarkdownPreview.appex", "EBookQLMarkdownThumbnail.appex",
                "EBookQLCHMPreview.appex", "EBookQLCHMThumbnail.appex"]
            .map { plugins.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func appexPath(named name: String) -> String? {
        appexPaths().first { $0.hasSuffix("/" + name) }
    }

    /// `pluginkit -m -v` lists one line per registered copy:
    /// `+    com.example.Ext(1.0)\tUUID\tdate\t/path/to/Ext.appex`
    /// A leading `+` means enabled, `-` means switched off. The flag and the spaces between
    /// it and the identifier have to be stripped from the same string: trimming after
    /// splitting on `(` leaves `"+    com.example.Ext"`, which matches no identifier and
    /// makes every extension look unregistered.
    private static func pluginkitListing() -> [String: (path: String, enabled: Bool)] {
        var out: [String: (path: String, enabled: Bool)] = [:]
        for line in run(pluginkit, ["-m", "-v"]).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let open = fields[0].firstIndex(of: "(") else { continue }
            let head = fields[0]
            let enabled = head.hasPrefix("+") || head.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            let id = head[head.startIndex..<open]
                .trimmingCharacters(in: CharacterSet(charactersIn: "+- \t"))
            guard allIDs.contains(id) else { continue }
            let path = fields[fields.count - 1].trimmingCharacters(in: .whitespaces)
            // A later line for the same id is a second copy; keep the enabled one, since
            // that is the one Quick Look will actually use.
            if out[id] == nil || (enabled && out[id]?.enabled == false) {
                out[id] = (path: path, enabled: enabled)
            }
        }
        return out
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
