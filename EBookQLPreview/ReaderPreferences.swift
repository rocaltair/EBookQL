//
//  ReaderPreferences.swift
//  EBookQLPreview
//
//  The read side of the cross-sandbox settings channel.
//
//  The preview extension is sandboxed, so its Application Support directory is
//  inside its own container. The unsandboxed host app writes
//  `<container>/Data/Library/Application Support/EBookQL/settings.json`; this
//  side only ever reads it. Any failure - missing file, unreadable, malformed
//  JSON, a key from a future version - falls back to the defaults, so a settings
//  problem can never stop a preview from rendering.
//
//  No UserDefaults: the appex's NSUserDefaults live in a different container and
//  cannot see what the host wrote.
//

import Foundation
import EBookQLKit

struct ReaderPreferences: Codable {
    var jsParse: Bool = true
    var theme: MarkdownTheme = .system
    var showLineNumbers: Bool = false
    /// Whether Markdown previews may fetch remote (http/https) images. Off unless
    /// the reader turned it on in the host window; EPUB/MOBI ignore it and never
    /// load remote images.
    var allowNetworkImages: Bool = false

    enum CodingKeys: String, CodingKey {
        case jsParse
        case theme
        case showLineNumbers
        case allowNetworkImages
    }

    init() {}

    /// Tolerant decode: a settings file written by an older host lacks newer keys.
    /// Each missing key falls back to its default instead of failing the whole read,
    /// so the other preferences survive alongside the new one. `encode` stays
    /// synthesized from `CodingKeys`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsParse = try container.decodeIfPresent(Bool.self, forKey: .jsParse) ?? true
        theme = try container.decodeIfPresent(MarkdownTheme.self, forKey: .theme) ?? .system
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? false
        allowNetworkImages = try container.decodeIfPresent(Bool.self, forKey: .allowNetworkImages) ?? false
    }

    static func load() -> ReaderPreferences {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return ReaderPreferences()
        }

        let url = base.appendingPathComponent("EBookQL", isDirectory: true)
            .appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(ReaderPreferences.self, from: data) else {
            return ReaderPreferences()
        }
        return preferences
    }
}
