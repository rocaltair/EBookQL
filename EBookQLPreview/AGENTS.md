# EBookQLPreview

Quick Look preview app-extension for EPUB / MOBI / AZW / AZW3 / FB2 / DjVu / CBZ. macOS instantiates `ReaderPreviewProvider` via `NSExtensionPrincipalClass`; it is now a thin adapter - panel size plus `preparePreviewOfFile` - over the shared reader host in `EBookQLReader/`, which the app compiles too. The Markdown-only sibling `EBookQLMarkdownPreview` reuses these same Swift sources (plus `ReaderAssets/`); only its Info.plist/entitlements and UTI list differ. `DjVuAssets/` ships only here and in the app, and a CBZ needs no asset at all.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Quick Look entry point | ReaderPreviewProvider.swift:21 (`preparePreviewOfFile`) |
| Panel sizing | ReaderPreviewProvider.swift:39 (`updatePanelSize`) |
| Which formats read settings.json | ReaderPreviewProvider.swift:52 (`readsSettings`) |
| Markdown preference read (settings.json) | ReaderPreferences.swift:21 |
| Everything else (WebView, messages, parse, position, zoom) | ../EBookQLReader/BookReaderViewController.swift (see its AGENTS.md) |
| `ekbres://` resource serving (book + `assets` host) | ../EBookQLReader/ReaderSchemeHandler.swift |
| The DjVu page decoder the page loads | DjVuAssets/ (see its AGENTS.md) |

## CONVENTIONS
- This target supplies only what is Quick Look's own: the panel fraction, and reading the appex's settings file into a `ReaderSettings` for the host.
- Single combined page, the security scope, the stale sweep and the position writes all live in `EBookQLReader/BookReaderViewController.swift` - one implementation for the preview and the app.
- Only the previewed book is served through `ekbres://`; the extension is sandboxed, with no network use beyond `network.client` for local HTML.
- Markdown preferences are read ONCE per preview and only when the URL is Markdown or FB2 (the book appex wants the FB2 key too): `ReaderPreferences.load()` returns `jsParse`/`theme` (defaults on any failure), `jsParse` decides rendered HTML vs raw source in the backend and gates the page's assets, and a `.system` theme is resolved against the appex's `effectiveAppearance` before `ReaderDocument.Options` is built. EPUB/MOBI keep `ReaderDocument.Options` defaults.
- `ReaderSchemeHandler` serves `ekbres://assets/<bare filename>` from `Bundle.main`; every other host goes through the book's `ResourceSource`. Every answer carries `Access-Control-Allow-Origin`, without which a DjVu page's `fetch()` of its page images is blocked (an `<img>` would still load - the two are not the same check).
- A DjVu book's page loads one extra module from the bundle (`ekbres://assets/djvu-viewer.js`, emitted by `ReaderDocument` for `.djvu` only); the appex target must therefore keep `DjVuAssets/` in its resources phase, flat. A CBZ emits no script: its page boxes hold `<img src="ekbres://cbz/page/<n>">` and the web view does the rest, so `com.rocaltair.cbz` costs the appex nothing but its UTI declaration.

## ANTI-PATTERNS
- Dropping `-Wl,-needed_framework,QuickLookUI` from `project.yml` (see root AGENTS.md) — the extension crashes in `EXConcreteExtensionContextVendor`.
- Releasing the security scope after parsing — breaks lazy image reads.
- Using `webView.pageZoom` for text size (see Reader/AGENTS.md).
- Trusting `qlmanage` output — it reflects neither the user's view nor the real generator; Finder is the judge.
- Adding `ReaderAssets/` back to this target's sources: the folder is excluded here on purpose and belongs only to `EBookQLMarkdownPreview.appex` (and to the app).
- Putting reader logic back in subclasses of the provider here: the host lives in `EBookQLReader/` and must stay shared, or the app and the panel will drift.
- Removing `DjVuAssets/` from this target's resources, or adding it to the Markdown targets: the module import chain and the bundle layout are one contract (see DjVuAssets/AGENTS.md).
- Answering a `ekbres://` request without `Access-Control-Allow-Origin` (see CONVENTIONS).

## NOTES
- `ReaderSchemeHandler` bridges `ResourceProvider` to `WKURLSchemeHandler`, and the reserved `assets` host to `Bundle.main`.
- The preview panel size is a fraction of the Quick Look panel, applied in `updatePanelSize`.
- `ReaderPreferences` is the read half of the cross-sandbox settings channel; the unsandboxed host writes the file (`EBookQLApp/SettingsStore.swift`). No App Groups, no UserDefaults.
