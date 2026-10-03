# EBookQLKit/Backend/Markdown

The Markdown backend: `md` / `markdown` / `mdx` → `Book`. One section, no declared TOC, rendered through JavaScriptCore. EBookQLKit is a static library, so the parser is a Swift string literal here, not a bundle resource.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Parse file → `Book` (front matter, title, raw-source mode) | MarkdownBackend.swift:19 |
| Render markdown via JavaScriptCore | MarkdownRenderer.swift:17 |
| marked UMD + bootstrap as string literals | MarkdownAssets.swift:17 (`markedJS`) / :108 (`bootstrapJS`) |

## CONVENTIONS
- The whole file is ONE `BookSection` (`id "md"`); `toc = []` and `tocIsFallback = false` on purpose. The renderer derives the sidebar from marked's GitHub-style heading ids, so `[x](#slug)` survives the reader's `chN--` anchor prefixing.
- UTF-8 read with an isoLatin1 fallback; `contentBytes` is the UTF-8 byte count.
- Optional leading `---…---` YAML front matter feeds ONLY title/author; anything richer than `key: value` is ignored, and an unclosed block is left in the body. Title priority: front matter, then first rendered `<h1>`, then filename.
- `MarkdownRenderer.html(from:)` builds a FRESH `JSContext` per call (JavaScriptCore is not thread-safe), evaluates `marked` 18.0.14 then the bootstrap, and calls `globalThis.renderMarkdown`. Any failure throws `BookParseError.malformed`.
- `markdownRendering == false` skips JavaScriptCore and returns the escaped raw source inside `<pre class="markdown-source">`.
- Fidelity: GFM; slug heading `id`s; mermaid fences → `<pre class="mermaid">` (escaped); `$…$` / `\(…\)` → `.math-inline`; `$$…$$` / `\[…\]` → `.math-block`; math inside code fences/inline code is NOT extracted; `$5 and $10` is not misread as math; MDX lone `import` / `export` lines are dropped.

## ANTI-PATTERNS
- Sharing one `JSContext` between parses.
- Declaring a TOC, or setting `tocIsFallback: true`, for Markdown.
- Hand-rolling a Markdown parser instead of using `MarkdownRenderer` and the embedded marked.
- Treating front matter as body content: it is metadata only and is stripped before rendering.

## NOTES
- The reader's Markdown fidelity contract lives in `bootstrapJS`; the `markedJS` literal is verbatim `lib/marked.umd.js` (46,891 bytes, MIT).
- Mermaid/KaTeX are NOT here. This backend emits `pre.mermaid` / `.math-inline` / `.math-block`; the Markdown appex's vendored assets render them in the page.
