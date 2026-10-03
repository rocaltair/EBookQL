# EBookQLKit/Reader

Turns a `Book` into one self-contained HTML page plus the reader chrome. `ReaderDocument.build` is the entry; `HTMLNormalizer` does the string surgery; `ReaderAssets` holds the entire CSS/JS; `ReaderTheme.swift` holds `MarkdownTheme`.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| `Book` → HTML page + sidebar | ReaderDocument.swift:57 (`build`) |
| Reader `Options` (position / zoom / theme / jsParse) | ReaderDocument.swift:14 |
| `data-theme` + `window.__ql` injection | ReaderDocument.swift:130 (`themeAttribute`) / :346 (`injectedState`) |
| TOC tree from headings | ReaderDocument.swift:247 (`tocTree`) |
| Fallback / notice pages | ReaderDocument.swift:275 / :286 |
| Anchor prefix / link rewrite / body extract | HTMLNormalizer.swift:16 |
| Regex cache (compiled once) | HTMLNormalizer.swift:268 |
| Reader CSS + JS (string literals) | ReaderAssets.swift:17 (`css`) / :216 (`js`) |
| Markdown theme enum (system/light/dark) | ReaderTheme.swift:15 (`MarkdownTheme`) |

## CONVENTIONS
- Per section: extract `<body>` → prefix anchors (`chN--…`) → rewrite `src`/`href` (cross-section → in-page anchor; resources → `ekbres://`) → wrap as `<section class="chapter" id="chN">`.
- `content-visibility: auto` (not two-phase injection) keeps big books fast; positions are re-measured each scroll because off-screen sections are not laid out.
- Text zoom scales only `#content` font-size — never `webView.pageZoom`. Images, sidebar and panel keep their size.
- Current-chapter highlight and sidebar clicks share one `targetOf(link)` resolver: try `id`, else fall back to `^ch(\d+)`; unresolved anchors degrade to the chapter, never a dead link.
- A book with no TOC adds `body.no-toc` so content is not pushed right.
- The sidebar is a flex column: `#toc-head` (title + text-size buttons + fold toggle + hide) never scrolls; only `#toc-scroll` (the note + list) does. The auto-follow in `updateCurrent` measures against `#toc-scroll`, not `#toc`.
- `#toc-fold-toggle` is ONE button with two states (▸▸ fold all / ▾▾ unfold all). It reads the list's live state (`anyExpanded()`) on every click instead of caching a flag — `updateCurrent` re-opens the highlighted branch on scroll, which would desync a cached flag. `reflectFoldState()` re-syncs the glyph/title from the DOM after any change.
- `updateCurrent` folds **only the branch the previous highlight was holding open on its own** (its exclusive ancestors), while opening the new entry's chain. Branches the reader opened by hand and is still looking at are left alone; the chain shared with the new entry stays open. Strict follow-fold (collapse everything not in the current chain) was tried and reverted — it folded branches the reader had deliberately opened. Only runs when the highlight actually changes (early `current === match` return).
- `data-theme="light|dark"` is emitted on `<html>` ONLY when `book.format == .markdown`; a `.system` theme is resolved to a concrete scheme by the preview (AppKit) and passed in. EPUB/MOBI get no attribute and keep following `prefers-color-scheme` (the `html[data-theme]` overrides in the CSS are scoped so they cannot touch them).
- `window.__ql` carries `theme` and `jsParse` alongside zoom/position/width. `ReaderAssets.js` reads `state.jsParse`: when false it never loads Mermaid/KaTeX, and it loads them only when `.mermaid` / `.math-inline,.math-block` are actually present, so EPUB/MOBI pages never fetch the 2.8 MB assets. Mermaid theme comes from `__ql.theme` (`dark`/`default`), not `prefers-color-scheme`.
- DjVu (`data-format="djvu"`): the reader's one format-specific *script*, emitted as `<script type="module" src="ekbres://assets/djvu-viewer.js">` after `ReaderAssets.js` (a module is deferred, so it runs once the DOM is there). A CBZ gets no script at all - its pages are `<img>`s the web view loads - and the two formats share one skin.
- The page-image skin (`html[data-format="djvu"], html[data-format="cbz"]`) is about the page box, not text: `content-visibility: visible` (every page's height is known from its `aspect-ratio`, so laying them all out is what makes the scrollbar and the reading fraction exact), a hidden `.page-no` heading per page (a real box for the position anchor, `clip-path`'d away - never `display: none`), a grey "desk" background so a white page has an edge, and `width: calc(100% * var(--page-zoom))` so A-/A+ scales the page. `--page-zoom` is set by `ReaderAssets.js` in `ekbSetZoom` - the one place that sees a zoom change - so every page-image format gets it without its own code.
- A DjVu page's script (`djvu-viewer.js`) fills the box with a canvas it decodes itself and adds `page-ready` / `page-failed`; a CBZ box already holds its `<img>`, which paints over the placeholder number by `z-index` with no script involved.

## ANTI-PATTERNS
- Writing in-body links as pre-prefixed anchors (`#ch0--toc7`) — `prefixAnchors` prefixes again → `ch0--ch0--toc7`, every click misses. In-body links are BARE (`#toc7`); sidebar hrefs (not run through prefixing) ARE prefixed. Two opposite rules — the easiest thing to get wrong.
- Letting a sidebar click scroll the sidebar list itself.
- Caching highlight positions (wrong once `content-visibility` skips layout).
- Resolving the highlight with `getElementById` instead of the shared `targetOf` (Calibre books with never-created anchors then never highlight).
- Scrolling sidebar items with `offsetTop` instead of rect-difference math — nested `position: relative` makes `offsetTop` relative to the wrong ancestor.
- Letting a zoom change affect images / sidebar / panel.
- Emitting `data-theme` for EPUB/MOBI, or loading Mermaid/KaTeX unconditionally: both would drag Markdown-only behaviour into the other formats.
- Putting a format's `<script src="ekbres://…">` inside a section's HTML: `rewriteLinks` rewrites every `src` attribute and `ekbres://` is not in its "external" list, so the URL would be passed to the book's resource provider and mangled. Format-level scripts are emitted by `build`, beside `ReaderAssets.js`.
- Hiding a format's position-anchor headings with `display: none`: the position tracking and the sidebar highlight measure real boxes (`getBoundingClientRect`), so a hidden heading has to stay laid out.

## NOTES
- Regexes are statically compiled and cached; `try!` is intentional for those compile-time constants.
- `ReaderAssets.js` builds the runtime chrome (zoom bar, scrollbar, resume pill); the TOC `<ul>` and `#content` are rendered Swift-side for a fast first paint.
- The vendored Mermaid/KaTeX are external appex resources, not Swift literals: the page requests them over `ekbres://assets/<bare filename>` and `ReaderSchemeHandler` serves them from `Bundle.main`. They ship only in the Markdown appex.
