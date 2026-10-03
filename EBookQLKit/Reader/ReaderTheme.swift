//
//  ReaderTheme.swift
//  EBookQLKit
//
//  The reader's colour scheme, as one shared word list. The host app's settings
//  UI, the settings JSON on disk and the preview extension that applies the theme
//  all spell it the same way, so the value round-trips without a translation step.
//
//  The raw values ("system" / "light" / "dark") are the wire format: the host's
//  `ThemeChoice` uses the same strings, and the JSON decoder here reads them back.
//

import Foundation

public enum MarkdownTheme: String, Sendable, Codable {
    case system
    case light
    case dark
}
