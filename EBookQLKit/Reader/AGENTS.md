# EBookQLKit/Reader

Turns a `Book` into one self-contained HTML page plus the reader chrome. `ReaderDocument.build` is the entry; `HTMLNormalizer` does the string surgery; `ReaderAssets` holds the entire CSS/JS.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| `Book` → HTML page + sidebar | ReaderDocument.swift:47 (`build`) |
| TOC tree from headings | ReaderDocument.swift:227 (`tocTree`) |
| Fallback / notice pages | ReaderDocument.swift:255 / :266 |
| Anchor prefix / link rewrite / body extract | HTMLNormalizer.swift:16 |
| Regex cache (compiled once) | HTMLNormalizer.swift:268 |
| Reader CSS + JS (string literals) | ReaderAssets.swift:17 (`css`) / :171 (`js`) |

## CONVENTIONS
- Per section: extract `<body>` → prefix anchors (`chN--…`) → rewrite `src`/`href` (cross-section → in-page anchor; resources → `ekbres://`) → wrap as `<section class="chapter" id="chN">`.
- `content-visibility: auto` (not two-phase injection) keeps big books fast; positions are re-measured each scroll because off-screen sections are not laid out.
- Text zoom scales only `#content` font-size — never `webView.pageZoom`. Images, sidebar and panel keep their size.
- Current-chapter highlight and sidebar clicks share one `targetOf(link)` resolver: try `id`, else fall back to `^ch(\d+)`; unresolved anchors degrade to the chapter, never a dead link.
- A book with no TOC adds `body.no-toc` so content is not pushed right.
- The sidebar is a flex column: `#toc-head` (title + text-size buttons + fold toggle + hide) never scrolls; only `#toc-scroll` (the note + list) does. The auto-follow in `updateCurrent` measures against `#toc-scroll`, not `#toc`.
- `#toc-fold-toggle` is ONE button with two states (▸▸ fold all / ▾▾ unfold all). It reads the list's live state (`anyExpanded()`) on every click instead of caching a flag — `updateCurrent` re-opens the highlighted branch on scroll, which would desync a cached flag. `reflectFoldState()` re-syncs the glyph/title from the DOM after any change.
- `updateCurrent` folds **only the branch the previous highlight was holding open on its own** (its exclusive ancestors), while opening the new entry's chain. Branches the reader opened by hand and is still looking at are left alone; the chain shared with the new entry stays open. Strict follow-fold (collapse everything not in the current chain) was tried and reverted — it folded branches the reader had deliberately opened. Only runs when the highlight actually changes (early `current === match` return).

## ANTI-PATTERNS
- Writing in-body links as pre-prefixed anchors (`#ch0--toc7`) — `prefixAnchors` prefixes again → `ch0--ch0--toc7`, every click misses. In-body links are BARE (`#toc7`); sidebar hrefs (not run through prefixing) ARE prefixed. Two opposite rules — the easiest thing to get wrong.
- Letting a sidebar click scroll the sidebar list itself.
- Caching highlight positions (wrong once `content-visibility` skips layout).
- Resolving the highlight with `getElementById` instead of the shared `targetOf` (Calibre books with never-created anchors then never highlight).
- Scrolling sidebar items with `offsetTop` instead of rect-difference math — nested `position: relative` makes `offsetTop` relative to the wrong ancestor.
- Letting a zoom change affect images / sidebar / panel.

## NOTES
- Regexes are statically compiled and cached; `try!` is intentional for those compile-time constants.
- `ReaderAssets.js` builds the runtime chrome (zoom bar, scrollbar, resume pill); the TOC `<ul>` and `#content` are rendered Swift-side for a fast first paint.
