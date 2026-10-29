//
//  SettingsWindow.swift
//  EBookQL
//
//  The configuration window, as an ordinary AppKit window hosting the SwiftUI
//  ContentView. It is created on demand rather than by a SwiftUI scene so that the
//  app's windows share one lifetime rule: the settings window is shown when the app
//  is opened without a book, and a book window is shown when one is opened.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {

    static let shared = SettingsWindow()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: ContentView())
        let size = host.view.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: max(size.width, 620), height: max(size.height, 480))),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "EBookQL"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("EBookQLSettingsWindow")
        if window.frame.origin == .zero { window.center() }
        return window
    }
}
