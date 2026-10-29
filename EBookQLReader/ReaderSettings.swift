//
//  ReaderSettings.swift
//  EBookQLReader
//
//  The settings a reader page needs, in the reader's own terms. The Quick Look
//  extension fills it from the appex container's settings.json, the app from
//  SettingsStore; the controller never learns where they came from.
//

import EBookQLKit

struct ReaderSettings {
    var jsParse: Bool = true
    var theme: MarkdownTheme = .system
    var showLineNumbers: Bool = false
    var allowNetworkImages: Bool = false
    var fb2ContentsFromText: Bool = true
}
