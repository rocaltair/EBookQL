//
//  MarkdownRenderer.swift
//  EBookQLKit
//
//  Markdown -> the reader's inner-<body> HTML, through JavaScriptCore.
//
//  The parser is marked (embedded in MarkdownAssets), configured by the bootstrap
//  that gives it the reader's HTML contract: GitHub-style heading ids, mermaid
//  fences, and math spans/blocks the reader renders with KaTeX. A *fresh* JSContext
//  is built for every call on purpose: parsing runs off the main thread and a
//  JSContext is not thread-safe, so none is ever shared.
//

import Foundation
import JavaScriptCore

enum MarkdownRenderer {

    /// Renders GFM markdown to HTML. Throws `BookParseError.malformed` when the
    /// JavaScript engine refuses the document or the parser is missing.
    static func html(from markdown: String) throws -> String {
        guard let context = JSContext() else { throw BookParseError.malformed }

        context.evaluateScript(MarkdownAssets.markedJS)
        if context.exception != nil { throw BookParseError.malformed }

        context.evaluateScript(MarkdownAssets.bootstrapJS)
        if context.exception != nil { throw BookParseError.malformed }

        guard let render = context.objectForKeyedSubscript("renderMarkdown"),
              !render.isUndefined else { throw BookParseError.malformed }

        context.exception = nil
        let result = render.call(withArguments: [markdown])
        if context.exception != nil { throw BookParseError.malformed }

        guard let html = result?.toString() else { throw BookParseError.malformed }
        return html
    }
}
