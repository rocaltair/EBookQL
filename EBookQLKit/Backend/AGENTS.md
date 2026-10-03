# EBookQLKit/Backend

Three parsers behind one protocol. `BookOpener.backend(for:)` picks by file extension; `BookBackend.open(_:workDirectory:)` returns a `Book`. Markdown uses the `markdownRendering` overload to pick rendered HTML vs raw source.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Protocol, dispatch, path helpers | BookBackend.swift:34 / :58 (dispatch) / :96 (`BookPath`) |
| EPUB (ZIP + OPF/NCX, EPUB3 nav) | EPUB/EPUBBackend.swift:21 |
| MOBI/AZW/AZW3 (libmobi, KF7 + KF8) | MOBI/MOBIBackend.swift:22 |
| Markdown (.md/.markdown/.mdx) | Markdown/MarkdownBackend.swift:19 |
| Markdown → HTML via JavaScriptCore | Markdown/MarkdownRenderer.swift:17 |
| marked UMD + bootstrap (Swift literals) | Markdown/MarkdownAssets.swift:17 |
| C↔Swift boundary | ../Vendor/libmobi/MobiShim.h |

## CONVENTIONS
- EPUB: books up to ~512 MB are read into memory (physical-memory/4 floor); larger ones stream from the archive. Only text (`xhtml/html/opf/ncx/xml/css`) is unpacked to the work dir; images/fonts stay in the archive and are served via `ekbres://`.
- EPUB TOC: EPUB3 `nav` first, NCX fallback; the richer of declared-vs-heading-derived wins.
- MOBI: the whole book is one section; headings produce the TOC. KF8 `kindle:pos:fid:…:off:…` and KF7 `filepos=…` links are rewritten to in-page anchors in the same pass as the sidebar anchors.
- Markdown: the whole file is ONE section (`id "md"`); `toc = []` and `tocIsFallback: false` on purpose, because the renderer's heading-derived sidebar is always clickable. UTF-8 read, isoLatin1 fallback. Optional `---…---` YAML front matter feeds only title/author; title priority is front matter, then first rendered `<h1>`, then filename; `contentBytes` is the UTF-8 byte count. No scratch directory is used.
- Resource URLs: `ekbres://local/…` (unpacked / in-memory archive) and `ekbres://mobi/<uid>` (libmobi resource). Markdown reads no book resources (its Mermaid/KaTeX assets belong to the appex, not the book).
- Keep parsing deterministic and side-effect free apart from the work directory.

## ANTI-PATTERNS
- Calling `mobi_parse_rawml`.
- Reading the whole book for a thumbnail (use `openForThumbnail`: in-memory limit 0, one section).
- Building the NCX tree by level instead of parent pointers, or skipping empty-title entries.
- Emitting already-prefixed anchors for in-body links — the renderer prefixes unconditionally.
- Forgetting `tocIsFallback` on the chosen TOC.
- Sharing one `JSContext` across parses (JavaScriptCore is not thread-safe) or parsing Markdown by hand in Swift instead of through the embedded `marked` in `MarkdownRenderer`.
- Giving a Markdown book a declared TOC (`tocIsFallback: true`): its heading ids are the contract.

## NOTES
- Long MOBI bodies are truncated at 8 MB of text (`Book.truncatedAt`); sidebar entries past the cut become non-clickable labels.
- Encrypted / corrupt / unsupported MOBI errors go through the shared notice page — never crash.
- Markdown fidelity (in the `bootstrapJS`): GFM; GitHub-style heading `id`s; mermaid code fences become `<pre class="mermaid">`; `$…$` / `\(…\)` become `.math-inline`, `$$…$$` / `\[…\]` become `.math-block`; math inside code fences/inline code is left alone; `$5 and $10` is not read as math; MDX lone `import`/`export` lines are dropped.
- With `markdownRendering == false` the backend returns the escaped raw source in `<pre class="markdown-source">` and never touches JavaScriptCore.
