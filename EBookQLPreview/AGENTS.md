# EBookQLPreview

Quick Look preview app-extension. macOS instantiates `ReaderPreviewProvider` via `NSExtensionPrincipalClass`; it parses the book, builds the HTML with `ReaderDocument`, and hosts it in a `WKWebView`.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Preview lifecycle + WebView + messages | ReaderPreviewProvider.swift:21 |
| Quick Look entry point | ReaderPreviewProvider.swift:120 (`preparePreviewOfFile`) |
| JS→native handlers (position / ui / zoom) | ReaderPreviewProvider.swift:255–330 |
| `ekbres://` resource serving | ReaderSchemeHandler.swift |
| Panel sizing / zoom persistence (NSUserDefaults) | ReaderPreviewProvider.swift:25–38, :108 |

## CONVENTIONS
- Single combined page: sections are merged into one HTML document and loaded with `loadFileURL`; a `workDirectory` under the temporary dir holds it.
- The security-scoped resource stays open for the WHOLE preview (the archive is read lazily during scrolling), and is closed on disappear/deinit.
- Stale work directories are swept on open.
- Only the previewed book is served through `ekbres://`; the extension is sandboxed, with no network use beyond `network.client` for local HTML.
- Position is reported to `ReadingPositionStore` on scroll; zoom / sidebar width round-trip through NSUserDefaults.

## ANTI-PATTERNS
- Dropping `-Wl,-needed_framework,QuickLookUI` from `project.yml` (see root AGENTS.md) — the extension crashes in `EXConcreteExtensionContextVendor`.
- Releasing the security scope after parsing — breaks lazy image reads.
- Using `webView.pageZoom` for text size (see Reader/AGENTS.md).
- Trusting `qlmanage` output — it reflects neither the user's view nor the real generator; Finder is the judge.

## NOTES
- `ReaderSchemeHandler` bridges `ResourceProvider` to `WKURLSchemeHandler`.
- The preview panel size is a fraction of the Quick Look panel, applied in `applyPreferredPanelSize`.
