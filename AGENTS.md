# PROJECT KNOWLEDGE BASE

**Generated:** 2026-10-03 09:41 CST
**Commit:** 30101e3
**Branch:** main

## OVERVIEW
EBookQL is a macOS Quick Look preview + thumbnail extension for EPUB / MOBI / AZW / AZW3 books. One shared reader (WKWebView, one generated HTML page) over two parsers: a ZIP + OPF/NCX EPUB backend and a libmobi-backed MOBI backend. Swift 5 + XcodeGen; the core is a static library.

## STRUCTURE
```
EBookQL/
├── project.yml            # XcodeGen source of truth (4 targets); edit this, NOT the .xcodeproj
├── EBookQLKit/            # static lib: all parsing + rendering + storage (~77% of first-party code)
│   ├── Model/Book.swift   # Book / BookMetadata / BookSection / TOCEntry / ReadingPosition
│   ├── Backend/           # BookBackend protocol + EPUB + MOBI parsers
│   ├── Reader/            # HTML synthesis + the one CSS/JS bundle (Swift literals)
│   ├── Store/             # ReadingPositionStore (SQLite)
│   └── Vendor/libmobi/    # vendored LGPL C — never edit
├── EBookQLPreview/        # Quick Look preview appex (WKWebView + ekbres://)
├── EBookQLThumbnail/      # Quick Look thumbnail appex
├── EBookQLApp/            # host app: carries the extensions + registers them
├── install.sh             # build/install/status/history/uninstall
└── release.sh             # DMG packaging
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Add/adjust a book format | EBookQLKit/Backend/ | conform to `BookBackend`, register in `BookOpener.backends` |
| Reader page, TOC sidebar, CSS/JS | EBookQLKit/Reader/ | see Reader/AGENTS.md |
| Reading-position persistence | EBookQLKit/Store/ReadingPositionStore.swift | SQLite, one table |
| Preview window, zoom, scheme | EBookQLPreview/ | see EBookQLPreview/AGENTS.md |
| Thumbnail card drawing | EBookQLThumbnail/ThumbnailProvider.swift | CoreGraphics card |
| Extension registration / status UI | EBookQLApp/ | pluginkit / lsregister |
| Build targets, linking, signing | project.yml | xcodegen generates the .xcodeproj |
| Design decisions + trap history | DESIGN.md | gitignored journal (Chinese) — authoritative |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BookOpener` | enum | Kit/Backend/BookBackend.swift:49 | format→backend dispatch (`backends = [EPUB, MOBI]`) |
| `BookBackend` | protocol | Kit/Backend/BookBackend.swift:34 | `url → Book` |
| `Book` / `BookSection` / `TOCEntry` / `BookMetadata` | structs | Kit/Model/Book.swift | format-neutral model |
| `EPUBBackend` | class | Kit/Backend/EPUB/EPUBBackend.swift:21 | ZIP + OPF/NCX parser |
| `MOBIBackend` | class | Kit/Backend/MOBI/MOBIBackend.swift:22 | libmobi parser (KF7/KF8) |
| `ReaderDocument.build` | func | Kit/Reader/ReaderDocument.swift:47 | `Book` → single HTML page |
| `HTMLNormalizer` | enum | Kit/Reader/HTMLNormalizer.swift:16 | anchor prefix / link rewrite / body extract |
| `ReaderAssets.css` / `.js` | enum | Kit/Reader/ReaderAssets.swift:13 | the entire reader UI (string literals) |
| `ReadingPositionStore` | class | Kit/Store/ReadingPositionStore.swift:24 | SQLite positions, shared singleton |
| `ReaderPreviewProvider` | class | EBookQLPreview/ReaderPreviewProvider.swift:21 | QLPreviewingController + WKWebView |
| `ReaderSchemeHandler` | class | EBookQLPreview/ReaderSchemeHandler.swift | `ekbres://` resource serving |
| `ThumbnailProvider` | class | EBookQLThumbnail/ThumbnailProvider.swift:18 | QLThumbnailProvider card |

## CONVENTIONS
- Swift 5.0, macOS 14.0+, universal (arm64 + x86_64). No SwiftPM manifest; ZIPFoundation is declared in `project.yml`.
- No tests, no linter/formatter, no CI. Style is set by the existing files.
- Core is `library.static` on purpose: an ad-hoc-signed appex cannot load an embedded dylib ("different Team IDs"). Do NOT convert EBookQLKit to a framework.
- A static lib carries no resources → reader CSS/JS live as Swift string literals in `ReaderAssets.swift`.
- Strict one-way layering: Backend → Model → Reader → Preview/Thumbnail → Store. Backends never touch UI.
- DRM is out of scope; encrypted books render a notice page.
- All four formats share one renderer + one CSS/JS. No per-format UI forks.
- `Book.toc` may be empty by contract; the renderer derives a TOC from `<h1..h3>` and the richer source wins.

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

## UNIQUE STYLES
- Embedded reader UI: `ReaderAssets.css` / `.js` are Swift string literals, not bundle resources.
- `ekbres://` custom scheme is the only resource path into the WebView (sandbox, no network).
- In-chapter anchors are prefixed (`chN--…`) unconditionally, but sidebar hrefs arrive already prefixed — opposite rules, see `EBookQLKit/Reader/AGENTS.md`.

## COMMANDS
```sh
brew install xcodegen          # once
./install.sh                   # xcodegen + Release build + install to /Applications + register both appex
./install.sh build             # build only (build/DerivedData)
./install.sh status            # registered/enabled extensions + how .epub/.mobi/... UTIs resolve
./install.sh history           # read positions.sqlite3
./install.sh uninstall
./release.sh [--keep]          # build + dist/EBookQL-<version>.dmg
xcodegen generate              # regenerate the (gitignored) .xcodeproj from project.yml

# raw xcodebuild needs the GUI Xcode (not Command Line Tools):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project EBookQL.xcodeproj -scheme EBookQL -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build
```
Schemes: `EBookQL` (host), `EBookQLPreview`, `EBookQLThumbnail`. There is no test scheme.

## NOTES
- `build/`, `dist/`, `test-books/` (~416 MB of real books), `DESIGN.md`, and `*.xcodeproj` are gitignored working artifacts.
- `DESIGN.md` is the authoritative design journal (Chinese) with the full trap history (§12). Read it before non-trivial changes.
- The extension entry classes (`ReaderPreviewProvider`, `ThumbnailProvider`) are instantiated by macOS via Info.plist `NSExtensionPrincipalClass`, not by our code.
- Real verification = build, install, then select a book in Finder and press Space. `test-books/` holds sample/test files.
