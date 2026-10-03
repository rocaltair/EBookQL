# EBookQLPreview/ReaderAssets

Vendored, offline assets for Markdown rendering: the diagrams and math the reader page loads over `ekbres://assets/`. They ship ONLY in `EBookQLMarkdownPreview.appex`, never in the shared EPUB/MOBI appex.

## WHERE TO LOOK
| File | Upstream | Version | Role |
|------|----------|---------|------|
| mermaid.min.js | @mermaid-js/tiny | 12.1.0 | mermaid fences (`pre.mermaid`) |
| katex.min.js | katex | 0.19.0 | inline/display math (`.math-inline` / `.math-block`) |
| katex.min.css | katex | 0.19.0 | KaTeX styles; all 20 woff2 fonts inlined as base64 (no `url(fonts/)`) |
| NOTICES.md | | | MIT + SIL OFL 1.1 licence texts |

## CONVENTIONS
- Served by `ReaderSchemeHandler` from `Bundle.main` under the reserved `assets` host and a bare filename: `ekbres://assets/mermaid.min.js`, `katex.min.js`, `katex.min.css`.
- These are external files, not Swift literals, because a static library (EBookQLKit) cannot carry resources. The Markdown preview target copies them into its resources phase.
- The page loads them only when `jsParse` is on AND the matching selector exists, so an EPUB/MOBI page never fetches them.
- `mermaid.min.js` is the tiny build: no mindmap/architecture, no elkjs (avoids EPL-2.0 and a second KaTeX copy); no dynamic imports and no network.

## ANTI-PATTERNS
- Adding this folder to `EBookQLPreview.appex` (the shared EPUB/MOBI extension). It is excluded there on purpose.
- Referencing an asset by a path below the bundle root: the handler takes only `lastPathComponent`.
- Editing the vendored files beyond the documented banner comment and inlined fonts; see NOTICES.md.

## NOTES
- Bundle lookup is by bare filename: `ReaderSchemeHandler.bundledAsset(at:)` resolves `Bundle.main.url(forResource:withExtension:)`.
- A missing or failing asset leaves the raw TeX / mermaid source visible; nothing throws and the page is never blanked.
