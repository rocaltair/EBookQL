# EBookQLPreview

Quick Look preview app-extension for EPUB / MOBI / AZW / AZW3 / FB2 / DjVu / CBZ. macOS instantiates `ReaderPreviewProvider` via `NSExtensionPrincipalClass`; it parses the book, builds the HTML with `ReaderDocument`, and hosts it in a `WKWebView`. The Markdown-only sibling `EBookQLMarkdownPreview` reuses these same Swift sources (plus `ReaderAssets/`); only its Info.plist/entitlements and UTI list differ. `DjVuAssets/` ships only here, and a CBZ needs no asset at all.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Preview lifecycle + WebView + messages | ReaderPreviewProvider.swift:21 |
| Quick Look entry point | ReaderPreviewProvider.swift:120 (`preparePreviewOfFile`) |
| Parse + page build off the main thread | ReaderPreviewProvider.swift:228 (`render`) |
| JS→native handlers (position / ui / zoom) | ReaderPreviewProvider.swift:282 |
| Markdown preference read (settings.json) | ReaderPreferences.swift:21 |
| Markdown URL check + theme resolve | ReaderPreviewProvider.swift:254 (`isMarkdown`) / :261 (`resolvedTheme`) |
| `ekbres://` resource serving (book + `assets` host) | ReaderSchemeHandler.swift |
| Panel sizing / zoom persistence (NSUserDefaults) | ReaderPreviewProvider.swift:25–38, :108 |
| The DjVu page decoder the page loads | DjVuAssets/ (see its AGENTS.md) |

## CONVENTIONS
- Single combined page: sections are merged into one HTML document and loaded with `loadFileURL`; a `workDirectory` under the temporary dir holds it.
- The security-scoped resource stays open for the WHOLE preview (the archive is read lazily during scrolling), and is closed on disappear/deinit.
- Stale work directories are swept on open.
- Only the previewed book is served through `ekbres://`; the extension is sandboxed, with no network use beyond `network.client` for local HTML.
- Position is reported to `ReadingPositionStore` on scroll; zoom / sidebar width round-trip through NSUserDefaults.
- Markdown preferences are read ONCE per preview and only when `isMarkdown(url)` is true: `ReaderPreferences.load()` returns `jsParse`/`theme` (defaults on any failure), `jsParse` decides rendered HTML vs raw source in the backend and gates the page's assets, and a `.system` theme is resolved against the appex's `effectiveAppearance` before `ReaderDocument.Options` is built. EPUB/MOBI keep `ReaderDocument.Options` defaults.
- `ReaderSchemeHandler` serves `ekbres://assets/<bare filename>` from `Bundle.main`; every other host goes through the book's `ResourceSource`. Every answer carries `Access-Control-Allow-Origin`, without which a DjVu page's `fetch()` of its page images is blocked (an `<img>` would still load - the two are not the same check).
- A DjVu book's page loads one extra module from the bundle (`ekbres://assets/djvu-viewer.js`, emitted by `ReaderDocument` for `.djvu` only); the appex target must therefore keep `DjVuAssets/` in its resources phase, flat. A CBZ emits no script: its page boxes hold `<img src="ekbres://cbz/page/<n>">` and the web view does the rest, so `com.rocaltair.cbz` costs the appex nothing but its UTI declaration.

## ANTI-PATTERNS
- Dropping `-Wl,-needed_framework,QuickLookUI` from `project.yml` (see root AGENTS.md) — the extension crashes in `EXConcreteExtensionContextVendor`.
- Releasing the security scope after parsing — breaks lazy image reads.
- Using `webView.pageZoom` for text size (see Reader/AGENTS.md).
- Trusting `qlmanage` output — it reflects neither the user's view nor the real generator; Finder is the judge.
- Adding `ReaderAssets/` back to this target's sources: the folder is excluded here on purpose and belongs only to `EBookQLMarkdownPreview.appex`.
- Removing `DjVuAssets/` from this target's resources, or adding it to the Markdown targets: the module import chain and the bundle layout are one contract (see DjVuAssets/AGENTS.md).
- Answering a `ekbres://` request without `Access-Control-Allow-Origin` (see CONVENTIONS).

## NOTES
- `ReaderSchemeHandler` bridges `ResourceProvider` to `WKURLSchemeHandler`, and the reserved `assets` host to `Bundle.main`.
- The preview panel size is a fraction of the Quick Look panel, applied in `applyPreferredPanelSize`.
- `ReaderPreferences` is the read half of the cross-sandbox settings channel; the unsandboxed host writes the file (`EBookQLApp/SettingsStore.swift`). No App Groups, no UserDefaults.
