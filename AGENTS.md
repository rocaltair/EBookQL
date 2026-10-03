# PROJECT KNOWLEDGE BASE

**Generated:** 2026-10-03 09:41 CST
**Commit:** 30101e3
**Branch:** feature/markdown-0.2.0

## OVERVIEW
EBookQL is a macOS Quick Look preview + thumbnail extension for EPUB / MOBI / AZW / AZW3 / DjVu books and Markdown. One shared reader (WKWebView, one generated HTML page) over five parsers: a ZIP + OPF/NCX EPUB backend, a libmobi-backed MOBI backend, a JavaScriptCore + embedded `marked` Markdown backend, an XML FB2 backend, and a DjVu one that reads the container and decodes no image at all (the page's own vendored JavaScript decoder rasterises each scan in the web view). The host app is a configuration window (register Markdown preview, toggle JS rendering, pick the Markdown theme). Swift 5 + XcodeGen; the core is a static library.

## STRUCTURE
```
EBookQL/
├── project.yml            # XcodeGen source of truth (host + static lib + 4 appexes); edit this, NOT the .xcodeproj
├── EBookQLKit/            # static lib: all parsing + rendering + storage (~77% of first-party code)
│   ├── Model/Book.swift   # Book / BookMetadata / BookSection / TOCEntry / ReadingPosition
│   ├── Backend/           # BookBackend protocol + EPUB + MOBI + FB2 + DjVu + Markdown parsers
│   ├── Reader/            # HTML synthesis + reader CSS/JS + MarkdownTheme (Swift literals)
│   ├── Store/             # ReadingPositionStore (SQLite)
│   └── Vendor/libmobi/    # vendored LGPL C — never edit
├── EBookQLPreview/        # EPUB/MOBI/AZW/AZW3/FB2/DjVu preview appex (WKWebView + ekbres://)
│   ├── ReaderAssets/      # vendored Mermaid/KaTeX, shipped ONLY in the Markdown appex
│   └── DjVuAssets/        # vendored JavaScript DjVu decoder + reader glue (ships only here)
├── EBookQLThumbnail/      # EPUB/MOBI/AZW/AZW3/FB2/DjVu thumbnail appex
├── EBookQLMarkdownPreview/   # Markdown-only preview appex (Info.plist + entitlements; sources shared from EBookQLPreview/)
├── EBookQLMarkdownThumbnail/ # Markdown-only thumbnail appex (Info.plist + entitlements; sources shared from EBookQLThumbnail/)
├── EBookQLApp/            # host app: configuration window + carries/registers the 4 appexes
├── install.sh             # build/install/status/history/uninstall
└── release.sh             # DMG packaging
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Add/adjust a book format | EBookQLKit/Backend/ | conform to `BookBackend`, register in `BookOpener.backends` |
| Markdown parser, front matter, JS rendering | EBookQLKit/Backend/Markdown/ | see Backend/Markdown/AGENTS.md |
| DjVu container, outline, metadata, page bytes | EBookQLKit/Backend/DjVu/ | see Backend/AGENTS.md; no image decoding in Swift |
| The DjVu page decoder the web view runs | EBookQLPreview/DjVuAssets/ | see that dir's AGENTS.md |
| Bundled Mermaid / KaTeX assets | EBookQLPreview/ReaderAssets/ | shipped only in the Markdown appex; see that dir's AGENTS.md |
| Markdown theme / JS-render settings | EBookQLApp/SettingsStore.swift + EBookQLPreview/ReaderPreferences.swift | `settings.json` in the Markdown appex container |
| Reader page, TOC sidebar, CSS/JS, theme | EBookQLKit/Reader/ | see Reader/AGENTS.md |
| Reading-position persistence | EBookQLKit/Store/ReadingPositionStore.swift | SQLite, one table |
| Preview window, zoom, scheme | EBookQLPreview/ | see EBookQLPreview/AGENTS.md |
| Markdown-only appexes | EBookQLMarkdownPreview/ + EBookQLMarkdownThumbnail/ | Info.plist + entitlements only; sources shared from the EPUB/MOBI appexes |
| Thumbnail card drawing | EBookQLThumbnail/ThumbnailProvider.swift | CoreGraphics card |
| Extension registration / status UI | EBookQLApp/ | pluginkit / lsregister; 4 appexes |
| Build targets, linking, signing | project.yml | xcodegen generates the .xcodeproj |
| Design decisions + trap history | DESIGN.md | gitignored journal (Chinese) — authoritative |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BookOpener` | enum | Kit/Backend/BookBackend.swift:58 | format→backend dispatch (`backends = [EPUB, MOBI, Markdown]`) |
| `BookBackend` | protocol | Kit/Backend/BookBackend.swift:34 | `url → Book`, plus `markdownRendering` overload |
| `Book` / `BookSection` / `TOCEntry` / `BookMetadata` | structs | Kit/Model/Book.swift | format-neutral model (`BookFormat.markdown`) |
| `EPUBBackend` | class | Kit/Backend/EPUB/EPUBBackend.swift:21 | ZIP + OPF/NCX parser |
| `MOBIBackend` | class | Kit/Backend/MOBI/MOBIBackend.swift:22 | libmobi parser (KF7/KF8) |
| `FB2Backend` | class | Kit/Backend/FB2/FB2Backend.swift:22 | FictionBook XML parser |
| `DjVuBackend` | class | Kit/Backend/DjVu/DjVuBackend.swift:19 | DjVu container parser; pages served, not decoded |
| `DjVuStructureReader` | enum | Kit/Backend/DjVu/DjVuStructure.swift:108 | chunk tree, DIRM, NAVM outline, ANTz metadata, INFO |
| `DjVuBZZ` / `DjVuZPCoder` | enum / class | Kit/Backend/DjVu/DjVuBZZ.swift:19 / :175 | ZP arithmetic coder + BZZ (DIRM/NAVM/TXTz/ANTz) |
| `MarkdownBackend` | class | Kit/Backend/Markdown/MarkdownBackend.swift:19 | md/markdown/mdx parser (one section; JS render or raw source) |
| `MarkdownRenderer` | enum | Kit/Backend/Markdown/MarkdownRenderer.swift:17 | fresh `JSContext` + embedded marked 18.0.14 |
| `MarkdownAssets` | enum | Kit/Backend/Markdown/MarkdownAssets.swift:17 | marked UMD + bootstrap as Swift string literals |
| `MarkdownTheme` | enum | Kit/Reader/ReaderTheme.swift:15 | system/light/dark; the settings wire format |
| `ReaderDocument.build` | func | Kit/Reader/ReaderDocument.swift:57 | `Book` → single HTML page; emits `data-theme` for Markdown |
| `HTMLNormalizer` | enum | Kit/Reader/HTMLNormalizer.swift:16 | anchor prefix / link rewrite / body extract |
| `ReaderAssets.css` / `.js` | enum | Kit/Reader/ReaderAssets.swift:17 / :216 | the entire reader UI (string literals) |
| `ReadingPositionStore` | class | Kit/Store/ReadingPositionStore.swift:24 | SQLite positions, shared singleton |
| `SettingsStore` / `HostSettings` | enum / struct | EBookQLApp/SettingsStore.swift:38 / :31 | host writes `settings.json` into the Markdown appex container |
| `ReaderPreferences` | struct | EBookQLPreview/ReaderPreferences.swift:21 | sandboxed appex reads settings, falls back to defaults |
| `ExtensionRegistration` | enum | EBookQLApp/ExtensionRegistration.swift:18 | registers/surveys all 4 appexes; `markdownEnabled` / `setMarkdownEnabled` |
| `ReaderPreviewProvider` | class | EBookQLPreview/ReaderPreviewProvider.swift:21 | QLPreviewingController + WKWebView |
| `ReaderSchemeHandler` | class | EBookQLPreview/ReaderSchemeHandler.swift | `ekbres://` resource serving, incl. `assets` host |
| `ThumbnailProvider` | class | EBookQLThumbnail/ThumbnailProvider.swift:18 | QLThumbnailProvider card |

## CONVENTIONS
- Swift 5.0, macOS 14.0+, universal (arm64 + x86_64). No SwiftPM manifest; ZIPFoundation is declared in `project.yml`.
- No tests, no linter/formatter, no CI. Style is set by the existing files.
- Core is `library.static` on purpose: an ad-hoc-signed appex cannot load an embedded dylib ("different Team IDs"). Do NOT convert EBookQLKit to a framework.
- A static lib carries no resources → reader CSS/JS live as Swift string literals in `ReaderAssets.swift`.
- Strict one-way layering: Backend → Model → Reader → Preview/Thumbnail → Store. Backends never touch UI.
- DRM is out of scope; encrypted books render a notice page.
- All formats share one renderer + one CSS/JS. No per-format UI forks.
- `Book.toc` may be empty by contract; the renderer derives a TOC from `<h1..h3>` and the richer source wins.
- Markdown is ONE section (`id "md"`) with `toc = []` and `tocIsFallback: false`: the renderer derives the sidebar from the GitHub-style heading ids `marked` emits, so `[x](#slug)` links survive anchor prefixing.
- Markdown rendering runs embedded `marked` 18.0.14 in a fresh `JSContext` per parse (JavaScriptCore; not thread-safe, so never shared). Any engine failure becomes `BookParseError.malformed`.
- Only a Markdown page carries `data-theme="light|dark"` and only it ever fetches the vendored Mermaid/KaTeX assets. EPUB/MOBI pages get no `data-theme` and keep following `prefers-color-scheme`.
- One format, one `data-format` attribute: `ReaderDocument.build` tags the root with `data-format="markdown|fb2|djvu"` and every format-specific CSS rule in `ReaderAssets.css` is scoped under it, so a rule written for one format cannot touch another.
- A `.djvu` book is the only one whose page *fetches bytes and decodes them itself*: `ReaderDocument` adds one module script (`ekbres://assets/djvu-viewer.js`) for it, and `ReaderSchemeHandler` therefore answers `ekbres://` with `Access-Control-Allow-Origin` — a custom-scheme `fetch()` from a `file://` page is blocked without that header, while `<img>`/`<script>` loads are not (measured).
- DjVu's `Book` is one section per *page*, with a page list or the file's own `NAVM` outline in the sidebar; the images are never decoded in Swift. See `EBookQLPreview/DjVuAssets/AGENTS.md` and DESIGN.md §16.

## ANTI-PATTERNS (THIS PROJECT)
- Hand-edit `EBookQL.xcodeproj` (generated, gitignored). Edit `project.yml`, run `xcodegen generate`.
- Remove `-Wl,-needed_framework,QuickLookUI` from the preview appex — the extension crashes in `EXConcreteExtensionContextVendor`.
- Set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: YES` / `get-task-allow` — Quick Look stamps the extension `[DEBUG]`.
- Call `mobi_parse_rawml` — SIGSEGV: the vendored libmobi leaves resource data NULL. Use `first_resource_record + uid`.
- Expose libmobi's own headers in `module.modulemap` — only `MobiShim.h`.
- Unregister extensions by bundle id — kills the `/Applications` copy too.
- Re-enable an extension the user switched off.
- Omit `tocIsFallback: true` from a backend's TOC decision — documented cross-format repeat-regression (DESIGN.md §12.6).
- Edit anything under `EBookQLKit/Vendor/libmobi/` (third-party, modified upstream).
- Validate with `qlmanage` — it uses the old generator DB and shows a misleading `[DEBUG]` badge; Finder is the judge.
- Put `EBookQLPreview/ReaderAssets/` back into the shared `EBookQLPreview.appex`: only `EBookQLMarkdownPreview.appex` may carry it (the static Kit cannot bundle resources).
- Route the settings channel through App Groups or `UserDefaults`: the unsandboxed host writes `settings.json` into the sandboxed Markdown appex's own container. App Groups need a provisioning profile and can silently fail under ad-hoc signing.

## UNIQUE STYLES
- Embedded reader UI: `ReaderAssets.css` / `.js` are Swift string literals, not bundle resources.
- `ekbres://` custom scheme is the only resource path into the WebView (sandbox, no network). Reader assets use the reserved `assets` host and a bare filename (`ekbres://assets/katex.min.js`), served from `Bundle.main`; book resources use any other host and go through the book's `ResourceSource`.
- Only a Markdown page carries `data-theme="light|dark"`; EPUB/MOBI keep `prefers-color-scheme`.
- In-chapter anchors are prefixed (`chN--…`) unconditionally, but sidebar hrefs arrive already prefixed — opposite rules, see `EBookQLKit/Reader/AGENTS.md`.

## COMMANDS
```sh
brew install xcodegen          # once
./install.sh                   # xcodegen + Release build + install to /Applications + register all 4 appexes
./install.sh build             # build only (build/DerivedData)
./install.sh status            # registered/enabled extensions + how .epub/.mobi/.azw/.azw3/.md UTIs resolve
./install.sh history           # read positions.sqlite3
./install.sh uninstall
./release.sh [--keep]          # build + dist/EBookQL-<version>.dmg
xcodegen generate              # regenerate the (gitignored) .xcodeproj from project.yml

# raw xcodebuild needs the GUI Xcode (not Command Line Tools):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project EBookQL.xcodeproj -scheme EBookQL -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
```
Schemes: `EBookQL` (host), `EBookQLPreview`, `EBookQLThumbnail`, `EBookQLMarkdownPreview`, `EBookQLMarkdownThumbnail`. There is no test scheme.

## NOTES
- `build/`, `dist/`, `test-books/` (~416 MB of real books), `DESIGN.md`, and `*.xcodeproj` are gitignored working artifacts.
- `DESIGN.md` is the authoritative design journal (Chinese) with the full trap history (§12). Read it before non-trivial changes.
- The extension entry classes (`ReaderPreviewProvider`, `ThumbnailProvider`) are instantiated by macOS via Info.plist `NSExtensionPrincipalClass`, not by our code.
- The host window is the configuration UI: register the two Markdown appexes (on/off via `pluginkit`), toggle "Render with JavaScript", and pick System/Light/Dark. It writes `~/Library/Containers/com.rocaltair.EBookQL.MarkdownPreview/Data/Library/Application Support/EBookQL/settings.json`; only the Markdown appex reads it.
- Markdown assets (`mermaid.min.js`, `katex.min.js`, `katex.min.css`) live only in `EBookQLMarkdownPreview.appex` (from `EBookQLPreview/ReaderAssets/`) and are reached over `ekbres://assets/`.
- Real verification = build, install, then select a book in Finder and press Space. `test-books/` holds sample/test files.
