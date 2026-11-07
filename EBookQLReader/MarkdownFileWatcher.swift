//
//  MarkdownFileWatcher.swift
//  EBookQLReader
//
//  Watches the Markdown file currently shown by the reader. Editors save in two
//  different ways: some write the original file in place, while others write a
//  temporary file and rename it over the original. A descriptor on the original
//  inode stops reporting after the second kind of save, so the reader restarts this
//  watcher after every reload. Events are coalesced before the callback runs.
//

import Darwin
import Foundation

final class MarkdownFileWatcher {

    private let url: URL
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?
    private var retryCount = 0
    private var isRunning = false

    private static let retryDelay: TimeInterval = 0.1
    private static let maximumRetries = 20

    init(url: URL, debounceInterval: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Main thread only. Safe to call repeatedly; each call replaces the previous
    /// descriptor, which is what re-arms the watcher after an atomic save.
    func start() {
        stop()
        isRunning = true
        openSource()
    }

    func stop() {
        isRunning = false
        retryCount = 0
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    private func openSource() {
        guard isRunning else { return }

        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The path can briefly disappear while an editor replaces it. Retry
            // without blocking the main thread; a permanent deletion stops after
            // the retry window instead of leaving a stale watcher behind.
            scheduleChange(delay: Self.retryDelay)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: .main
        )
        self.source = source
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.source === source else { return }
            self.receive(source.data)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
    }

    private func receive(_ event: DispatchSource.FileSystemEvent) {
        guard isRunning else { return }
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            // This descriptor now refers to the replaced/unlinked inode. The path
            // may already point at the editor's new file, so retry opening it when
            // the debounce fires.
            source?.cancel()
            source = nil
        }
        scheduleChange()
    }

    private func scheduleChange(delay: TimeInterval? = nil) {
        guard isRunning else { return }
        pendingChange?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingChange = nil
            self.deliverIfAvailable()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? debounceInterval),
            execute: work
        )
    }

    private func deliverIfAvailable() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard retryCount < Self.maximumRetries else {
                retryCount = 0
                // A permanently removed file has no inode left to watch. Stop rather
                // than asking the reader to reload and start this same wait forever.
                stop()
                return
            }
            retryCount += 1
            scheduleChange(delay: Self.retryDelay)
            return
        }

        retryCount = 0
        onChange()
    }
}
