//
//  AppDelegate.swift
//  EBookQL
//
//  The app's AppKit half: it takes the documents the Finder, `open` or the Dock hand
//  over and puts each one in a reader window, and it decides what a plain launch
//  shows - the settings window - and what launching a book shows - only the book.
//

import AppKit
import EBookQLKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening the app is the first launch in the ordinary case - drag to
        // /Applications, open once - so put this copy on the system's books here,
        // whether or not a document was also handed over.
        ExtensionRegistration.register()

        // A document open event arrives just after launch, so give it one beat before
        // deciding that this was a plain launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard ReaderWindows.shared.isEmpty else { return }
            SettingsWindow.shared.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ReaderWindows.shared.open(url) }
    }

    /// A Dock click with no window brings the settings back; a book window keeps it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.shared.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
