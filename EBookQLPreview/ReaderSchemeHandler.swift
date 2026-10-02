//
//  ReaderSchemeHandler.swift
//  EBookQLPreview
//
//  Serves the resources that were never unpacked from a book - images, fonts, media -
//  so a book full of artwork can be previewed without extracting it first. It knows
//  nothing about formats: either backend hands it a `ResourceSource`, and the page asks
//  for a path.
//

import Foundation
import WebKit
import UniformTypeIdentifiers
import os.log
import EBookQLKit

final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = BookResourceScheme.name

    private static let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Resources")

    /// Set before the page loads. Main thread only.
    var source: ResourceSource?

    private let queue = DispatchQueue(label: "com.rocaltair.EBookQL.resources")
    private let stoppedLock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else {
            finish(task, nil)
            return
        }
        // A book's source is read on one serial queue, so a provider that opens its
        // archive lazily needs no locking of its own.
        queue.async { [weak self] in
            guard let self else { return }
            self.finish(task, self.source?.resource(at: requestURL.path))
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stoppedLock.lock()
        stoppedTasks.insert(ObjectIdentifier(task))
        stoppedLock.unlock()
    }

    private func finish(_ task: WKURLSchemeTask, _ resource: (data: Data, mimeType: String?)?) {
        stoppedLock.lock()
        let wasStopped = stoppedTasks.remove(ObjectIdentifier(task)) != nil
        stoppedLock.unlock()
        guard !wasStopped else { return }

        guard let url = task.request.url, let resource else {
            // Worth a log: a miss here is an image the page asked for and will not get.
            os_log("missing %{public}@", log: Self.log, type: .error,
                   task.request.url?.path ?? "(no url)")
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        os_log("served %{public}@ (%{public}d bytes, %{public}@)", log: Self.log, type: .debug,
               url.path, resource.data.count, resource.mimeType ?? "by extension")
        // A MOBI record carries its real type; for an EPUB the file name is the only clue.
        let response = URLResponse(url: url,
                                   mimeType: resource.mimeType ?? Self.mimeType(for: url.path),
                                   expectedContentLength: resource.data.count,
                                   textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(resource.data)
        task.didFinish()
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
