# EBookQLPreview/DjVuAssets

The DjVu page renderer: the vendored JavaScript decoder plus the reader's own glue. It ships ONLY in `EBookQLPreview.appex` (no other appex can be handed a `.djvu`), copied flat into the appex bundle root, where `ekbres://assets/<file>` finds a file by bare name and the modules can still `import` each other by relative path.

## WHERE TO LOOK
| File | Role |
|------|------|
| `djvu-viewer.js` | the reader's glue (ours): fetch each page, decode it, paint it into the frame, keep memory bounded |
| `iff.js` / `document.js` | container (FORM/DJVM/DIRM/INCL), page enumeration, per-page layer assembly |
| `zp.js` / `zp_table.js` / `bzz.js` | the ZP arithmetic coder and BZZ (DIRM, TXTz, ANTz) |
| `jb2.js` / `mmr.js` / `mmr_tables.js` | the bilevel mask: JB2, and MMR/G4 fax |
| `iw44.js` | the background/foreground wavelet images |
| `color.js` / `text.js` / `annotations.js` | FGbz palette, hidden text zones, ANT annotations |
| `render.js` | the layer compositor (background under the mask, box-filter anti-aliasing) |
| `NOTICE-dejaview` / `LICENSE-dejaview` | upstream provenance + MIT text (a payload, ships in the bundle) |
| `NOTICES.md` | the notice EBookQL ships, as the other asset folders do |

Everything except `djvu-viewer.js` is DejaView, unmodified (see NOTICES.md for the commit). `src/jspeg/` and `jpeg.js` are deliberately NOT vendored: they are the pure-JS JPEG fallback for environments without `createImageBitmap`, and a `WKWebView` has it - `djvu-viewer.js` decodes `BGjp`/`FGjp` layers natively instead.

## CONVENTIONS
- Loaded as ONE module from the page: `ReaderDocument.build` emits `<script type="module" src="ekbres://assets/djvu-viewer.js">` for a `.djvu` book, and only for one. The vendored modules are imported from there, so the bundle must keep them side by side (flat).
- Page bytes come over the same scheme: `ekbres://djvu/page/<index>` (one page, stand-alone) or `ekbres://djvu/document` (the whole file, for a document whose pages inherit a shared dictionary).
- Decoding runs on the MAIN thread. A `file://` page cannot create a worker - measured: `SecurityError` for a worker beside the page and for one on the custom scheme - so pages are decoded one at a time, nearest-first, with a yield between them.
- Decoded canvases are bounded (a pixel budget and a page count) and freed for pages the reader has scrolled away from; the page box keeps its height from `aspect-ratio`, so nothing moves when a page is dropped or re-decoded.
- The page box's classes and the zoom variable are shared with the CBZ format: `.page-frame`, `page-ready`, `page-failed`, `.page-no`, `--page-zoom`. `--page-zoom` is set by `ReaderAssets.js`'s `ekbSetZoom` (the reader's own script, the only place that sees a zoom change), not here - a page-image format must not grow its own zoom wiring.
- A page that cannot be decoded gets `page-failed` on its box and stays a labelled empty box. Never a blank page, never a silent retry loop.

## ANTI-PATTERNS
- Editing the vendored files. If upstream needs to move, re-copy the whole set and update NOTICES.md.
- Renaming a vendored file: the module specifiers inside DejaView are relative (`./bzz.js`), and flattening the bundle root is what keeps them valid.
- Adding these files to `EBookQLMarkdownPreview.appex` (or to the static kit, which carries no resources at all).
- Serving a book page through `ReaderSchemeHandler` without `Access-Control-Allow-Origin`: an `<img>` load succeeds without it but a `fetch()` does not, and every page here is fetched.
- Assuming a worker: anything that needs one has to be reshaped to run on the main thread.

## NOTES
- Measured (this library's own scans, 3492x5587 bilevel, Release build, WKWebView): ~50-120 ms to decode + composite one page at full resolution, ~15 MB of canvas per page at the subsample the reader picks (about twice the on-screen width).
- `ReaderSchemeHandler.bundledAsset(at:)` resolves by `lastPathComponent`, so a subdirectory in this folder would not be served.
