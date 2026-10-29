//
//  Main.swift
//  EBookQL
//
//  Host application: it carries the extensions, declares the UTIs, opens books in a
//  reader window, configures the preview extensions, and shows whether they are
//  actually live on this machine.
//

import SwiftUI

@main
struct EBookQLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recents = RecentBooks.shared

    var body: some Scene {
        // An inert scene: every window this app shows is an AppKit window it owns
        // (SettingsWindow and ReaderWindows), so the settings window and the book
        // windows follow one rule instead of two. `Settings` never opens by itself,
        // and its menu item is replaced below.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { ReaderWindows.shared.chooseAndOpen() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(recents.urls, id: \.self) { url in
                        Button(url.lastPathComponent) { ReaderWindows.shared.open(url) }
                    }
                    Divider()
                    Button("Clear Menu") { recents.clear() }
                        .disabled(recents.urls.isEmpty)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @State private var extensions: [ExtensionRegistration.Extension] = []
    @State private var checked = false
    @State private var markdownEnabled = false
    @State private var chmEnabled = false
    @State private var settings = HostSettings.defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            // Two kinds of setting, two tabs: what is installed on this Mac and how a
            // Markdown preview renders. The single column had outgrown itself - a list
            // of extension states and a rendering switch are not one list.
            TabView {
                generalSettings
                    .tabItem { Label("General", systemImage: "gearshape") }
                markdownSettings
                    .tabItem { Label("Markdown", systemImage: "doc.richtext") }
                fb2Settings
                    .tabItem { Label("FB2", systemImage: "book.closed") }
            }
            .frame(minWidth: 560, minHeight: 380)
        }
        .frame(minWidth: 560, alignment: .topLeading)
        .padding(20)
        .task {
            // Opening the app is the first launch in the ordinary case - drag to
            // /Applications, open once - so put this copy on the system's books here.
            ExtensionRegistration.register()
            settings = SettingsStore.load()
            markdownEnabled = ExtensionRegistration.markdownEnabled()
            chmEnabled = ExtensionRegistration.chmEnabled()
            refresh()
        }
    }

    /// Long explanatory strings, kept out of the view body: a chain of concatenated
    /// literals inside `.help` was enough to blow up the type checker on this target.
    private enum Help {
        static let markdownToggle = "Off, macOS falls back to its own plain-text preview for "
            + ".md and .mdx. The book formats — EPUB, MOBI/AZW/AZW3, FictionBook, DjVu, "
            + "CBZ/CBT, CHM — have no switch here: Quick Look maps one file type to one "
            + "extension, and EBookQL is the only one for them."
        static let chmToggle = "Microsoft HTML Help (.chm). Off by default: this registers or "
            + "unregisters the CHM Quick Look extensions, the same way the Markdown switch "
            + "works. While it is off, .chm files are left to macOS. The app itself can still "
            + "open a .chm in a reader window."
        static let registerAgain = "Hands this copy of the app back to LaunchServices and "
            + "pluginkit, and switches on anything the system has never seen. Press it when "
            + "the list above points at a different EBookQL.app, or when none of the six show "
            + "up at all."
        static let extensionSettings = "Opens System Settings ▸ General ▸ Login Items & "
            + "Extensions — the one place a Quick Look extension you switched off can be "
            + "switched back on. EBookQL never re-enables one you turned off."
        static let jsParse = "Renders the markup itself: maths, Mermaid diagrams and "
            + "GitHub-flavoured tables. Off, the file's own source is shown instead — no "
            + "script runs, and a very large file opens faster."
        static let lineNumbers = "Numbers the lines of code blocks."
        static let theme = "Markdown previews and reader windows only. Every other book "
            + "format — EPUB, MOBI/AZW/AZW3, FictionBook, DjVu, CBZ/CBT, CHM — keeps "
            + "following the system's own light/dark appearance."
        static let networkImages = "Off by default: a preview that opens a network "
            + "connection is your decision, not the app's. On, Markdown previews load remote "
            + "images over http and https, and the strip at the foot of the page shows where "
            + "a hovered image comes from. Off, a remote image is replaced by a placeholder "
            + "naming its host and nothing is fetched. No book format loads a remote image, "
            + "whatever this is set to."
        static let fb2Contents = "Only ever used for a book that has no chapter titles at "
            + "all — which is what .fb2 files from the usual converters look like. Their "
            + "headings survive as text (\"Chapter 4 …\", \"Part II …\", or a bold line of "
            + "its own) and are read back as headings. A book that has titles is never "
            + "touched, whatever this is set to."
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("EBookQL").font(.title2).bold()
                Text("Quick Look previews and thumbnails, and a reader window, for EPUB, MOBI, AZW, AZW3, FictionBook, DjVu, CBZ/CBT, CHM and Markdown.")
                    .foregroundStyle(.secondary)
                Text("Press Space in the Finder to preview, or open a book to read it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - General tab

    /// A grouped form, one section per question the reader can actually ask: is the
    /// Markdown pair on, what did the system register, and what to press when the
    /// answer is wrong. The long version of each explanation lives in a tooltip, so the
    /// window stays readable and the detail is still one hover away.
    @ViewBuilder private var generalSettings: some View {
        Form {
            Section {
                Toggle("Enable Markdown previews", isOn: markdownBinding)
                    .help(Help.markdownToggle)
                Toggle("Enable CHM previews", isOn: chmBinding)
                    .help(Help.chmToggle)
            } header: {
                Text("Quick Look extensions")
            }

            Section {
                status
            } header: {
                Text("What is registered on this Mac")
            } footer: {
                Text("Green: on. Orange: switched off. Red: never registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Register again") {
                        ExtensionRegistration.register()
                        refresh()
                    }
                    .help(Help.registerAgain)
                    Button("Extension settings…") { ExtensionRegistration.openSettings() }
                        .help(Help.extensionSettings)
                }
            } header: {
                Text("When something is wrong")
            }
        }
        .formStyle(.grouped)
    }

    private var markdownBinding: Binding<Bool> {
        Binding(
            get: { markdownEnabled },
            set: { newValue in
                ExtensionRegistration.setMarkdownEnabled(newValue)
                markdownEnabled = ExtensionRegistration.markdownEnabled()
                refresh()
            }
        )
    }
    private var chmBinding: Binding<Bool> {
        Binding(
            get: { chmEnabled },
            set: { newValue in
                ExtensionRegistration.setCHMEnabled(newValue)
                chmEnabled = ExtensionRegistration.chmEnabled()
                refresh()
            }
        )
    }

    // MARK: - Markdown tab

    /// Same shape, one section per group of settings. Each control's own tooltip says
    /// what it changes and what it costs; the form itself stays short.
    @ViewBuilder private var markdownSettings: some View {
        Form {
            Section {
                Toggle("Render with JavaScript", isOn: jsParseBinding)
                    .help(Help.jsParse)
                Toggle("Show line numbers", isOn: lineNumbersBinding)
                    .help(Help.lineNumbers)
            } header: {
                Text("Rendering")
            }

            Section {
                Picker("Theme", selection: themeBinding) {
                    ForEach(ThemeChoice.allCases, id: \.self) { theme in
                        Text(themeLabel(theme)).tag(theme)
                    }
                }
                .help(Help.theme)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Allow network images", isOn: networkImagesBinding)
                    .help(Help.networkImages)
            } header: {
                Text("Network")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - FB2 tab

    /// FictionBook's one choice. It exists because the converters in circulation drop every
    /// `<title>` element: the structure of those files survives only as text, so a book arrives
    /// with nothing for the sidebar to be built from.
    @ViewBuilder private var fb2Settings: some View {
        Form {
            Section {
                Toggle("Guess the contents from the text", isOn: fb2ContentsBinding)
                    .help(Help.fb2Contents)
            } header: {
                Text("Contents")
            } footer: {
                Text("Only affects FB2 files without chapter titles. The sidebar says when the contents were guessed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var fb2ContentsBinding: Binding<Bool> {
        Binding(
            get: { settings.fb2ContentsFromText },
            set: { newValue in
                var updated = settings
                updated.fb2ContentsFromText = newValue
                settings = updated
                SettingsStore.write(updated)
            }
        )
    }

    private var jsParseBinding: Binding<Bool> {
        Binding(
            get: { settings.jsParse },
            set: { newValue in
                var updated = settings
                updated.jsParse = newValue
                settings = updated
                SettingsStore.write(updated)
            }
        )
    }

    private var themeBinding: Binding<ThemeChoice> {
        Binding(
            get: { settings.theme },
            set: { newValue in
                var updated = settings
                updated.theme = newValue
                settings = updated
                SettingsStore.write(updated)
            }
        )
    }

    private var lineNumbersBinding: Binding<Bool> {
        Binding(
            get: { settings.showLineNumbers },
            set: { newValue in
                var updated = settings
                updated.showLineNumbers = newValue
                settings = updated
                SettingsStore.write(updated)
            }
        )
    }

    private var networkImagesBinding: Binding<Bool> {
        Binding(
            get: { settings.allowNetworkImages },
            set: { newValue in
                var updated = settings
                updated.allowNetworkImages = newValue
                settings = updated
                SettingsStore.write(updated)
            }
        )
    }

    private func themeLabel(_ theme: ThemeChoice) -> String {
        switch theme {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    // MARK: - Extension status

    @ViewBuilder private var status: some View {
        if !checked {
            Text("Checking…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(extensions) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: item))
                            .foregroundStyle(tint(for: item))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.callout)
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if item.fromAnotherCopy {
                                Text("Not the copy you opened — press “Register again” below, and remove any other copy of EBookQL.app.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .help(item.help)
                }
                if extensions.contains(where: { $0.registered && !$0.enabled }) {
                    Text("An extension you switched off stays off until you turn it back on — see Extension settings… below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if extensions.contains(where: { !$0.registered }) {
                    Text("If it stays unregistered, move EBookQL.app to /Applications and open it from there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func symbol(for item: ExtensionRegistration.Extension) -> String {
        if item.registered && item.enabled { return "checkmark.circle.fill" }
        return item.registered ? "exclamationmark.circle.fill" : "xmark.circle.fill"
    }

    private func tint(for item: ExtensionRegistration.Extension) -> Color {
        if item.registered && item.enabled { return .green }
        return item.registered ? .orange : .red
    }

    private func refresh() {
        extensions = ExtensionRegistration.survey()
        checked = true
    }
}
