//
//  Main.swift
//  EBookQL
//
//  Host application: it exists to carry the two extensions, to declare the UTIs, and to
//  show whether the extensions are actually live on this machine.
//

import SwiftUI

@main
struct EBookQLApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var extensions: [ExtensionRegistration.Extension] = []
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EBookQL").font(.title2).bold()
                    Text("Quick Look previews and thumbnails for EPUB, MOBI, AZW and AZW3.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Select a book in the Finder and press Space.")

            status

            Divider()

            HStack(spacing: 10) {
                Button("Register again") {
                    ExtensionRegistration.register()
                    refresh()
                }
                Button("Extension settings…") { ExtensionRegistration.openSettings() }
                Spacer()
            }
        }
        .frame(minWidth: 520, alignment: .topLeading)
        .padding(22)
        .task {
            // Opening the app is the first launch in the ordinary case - drag to
            // /Applications, open once - so put this copy on the system's books here.
            ExtensionRegistration.register()
            refresh()
        }
    }

    @ViewBuilder private var status: some View {
        if !checked {
            Text("Checking…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(extensions) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.registered && item.enabled
                              ? "checkmark.circle.fill"
                              : (item.registered ? "exclamationmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(item.registered && item.enabled ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(item.title) — \(item.summary)")
                                .font(.callout)
                                .textSelection(.enabled)
                            if item.fromAnotherCopy {
                                Text("That is not the copy you opened — press “Register again”, and remove any other copy of EBookQL.app.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if extensions.contains(where: { $0.registered && !$0.enabled }) {
                    Text("An extension that is switched off stays off until you turn it on — see Extension settings.")
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

    private func refresh() {
        extensions = ExtensionRegistration.survey()
        checked = true
    }
}
