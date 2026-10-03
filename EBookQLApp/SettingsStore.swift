//
//  SettingsStore.swift
//  EBookQL
//
//  The write side of the cross-sandbox settings channel.
//
//  The host app is not sandboxed, so it can write straight into an extension's
//  container: `~/Library/Containers/<appex-id>/Data/Library/Application Support/
//  EBookQL/settings.json`. The sandboxed extension reads that file from inside its
//  own container (`ReaderPreferences`), which is why the path is built from the
//  real home directory rather than `FileManager`'s.
//
//  Nothing here imports EBookQLKit: the host target does not link it, so
//  `ThemeChoice` mirrors `MarkdownTheme`'s raw values instead. The JSON therefore
//  round-trips between the two enums unchanged.
//

import Foundation

enum ThemeChoice: String, CaseIterable {
    case system
    case light
    case dark
}

// Declared separately so the enum's own declaration stays exactly as specified;
// the String raw value gives CodingKeys "system" / "light" / "dark", matching
// MarkdownTheme so the settings JSON round-trips between host and extension.
extension ThemeChoice: Codable {}

struct HostSettings: Codable {
    var jsParse: Bool
    var theme: ThemeChoice
    var showLineNumbers: Bool

    static let defaults = HostSettings(jsParse: true, theme: .system, showLineNumbers: false)

    enum CodingKeys: String, CodingKey {
        case jsParse
        case theme
        case showLineNumbers
    }

    init(jsParse: Bool, theme: ThemeChoice, showLineNumbers: Bool) {
        self.jsParse = jsParse
        self.theme = theme
        self.showLineNumbers = showLineNumbers
    }

    /// Tolerant decode: a settings file written before a key existed must not reset
    /// the reader's other choices. Every field falls back to its default when absent,
    /// so an older `settings.json` keeps working unchanged. `encode` is still
    /// synthesized from `CodingKeys`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsParse = try container.decodeIfPresent(Bool.self, forKey: .jsParse) ?? true
        theme = try container.decodeIfPresent(ThemeChoice.self, forKey: .theme) ?? .system
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? false
    }
}

enum SettingsStore {

    /// The Markdown preview extension's bundle id. Its container is the one the
    /// markdown settings are written to.
    static let markdownPreviewID = "com.rocaltair.EBookQL.MarkdownPreview"

    /// `~/Library/Containers/<id>/Data/Library/Application Support/EBookQL/settings.json`
    static func settingsURL(forAppexID id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("EBookQL", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() -> HostSettings {
        let url = settingsURL(forAppexID: markdownPreviewID)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(HostSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    static func write(_ s: HostSettings) {
        let url = settingsURL(forAppexID: markdownPreviewID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(s)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort: the container may not exist yet (the extension has
            // never run), and a failed settings write must never take the app down.
        }
    }
}
