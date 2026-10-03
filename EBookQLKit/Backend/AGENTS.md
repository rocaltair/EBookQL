# EBookQLKit/Backend

Six parsers behind one protocol. `BookOpener.backend(for:)` picks by file extension; `BookBackend.open(_:workDirectory:)` returns a `Book`. Markdown uses the `markdownRendering` overload to pick rendered HTML vs raw source; FictionBook uses the facade's `contentsFromText:` overload to decide whether a title-less book may have its contents guessed (the app's FB2 tab, on by default).

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Protocol, dispatch, path helpers | BookBackend.swift:34 / :58 (dispatch) / :96 (`BookPath`) |
| EPUB (ZIP + OPF/NCX, EPUB3 nav) | EPUB/EPUBBackend.swift:21 |
| FB2 (FictionBook XML, inline base64 images) | FB2/FB2Backend.swift:22 / FB2/FB2Document.swift:24 |
| FB2 contents guessed from the text | FB2/FB2Document.swift `promotedContents` |
| MOBI/AZW/AZW3 (libmobi, KF7 + KF8) | MOBI/MOBIBackend.swift:22 |
| DjVu container: chunk tree, DIRM, outline, metadata | DjVu/DjVuStructure.swift:19 |
| DjVu `Book` + page bytes over `ekbres://djvu` | DjVu/DjVuBackend.swift:19 / `DjVuResourceProvider` |
| ZP coder + BZZ (DIRM/NAVM/TXTz/ANTz) | DjVu/DjVuBZZ.swift:19 + DjVu/DjVuZPTable.swift |
| What DjVu and CBZ share (page-image books) | PageImageBook.swift:26 |
| CBZ archive: pages, order, image headers | CBZ/CBZDocument.swift:50 / :221 (`CBZImageHeader`) |
| CBZ `Book` + page bytes over `ekbres://cbz` | CBZ/CBZBackend.swift:24 / :149 (`CBZResourceProvider`) |
| `ComicInfo.xml` manifest (title, writer, bookmarks) | CBZ/CBZComicInfo.swift:13 |
| Markdown (.md/.markdown/.mdx) | Markdown/MarkdownBackend.swift:19 |
| Markdown → HTML via JavaScriptCore | Markdown/MarkdownRenderer.swift:17 |
| marked UMD + bootstrap (Swift literals) | Markdown/MarkdownAssets.swift:17 |
| C↔Swift boundary | ../Vendor/libmobi/MobiShim.h |

## CONVENTIONS
- EPUB: books up to ~512 MB are read into memory (physical-memory/4 floor); larger ones stream from the archive. Only text (`xhtml/html/opf/ncx/xml/css`) is unpacked to the work dir; images/fonts stay in the archive and are served via `ekbres://`.
- EPUB TOC: EPUB3 `nav` first, NCX fallback; the richer of declared-vs-heading-derived wins.
- MOBI: the whole book is one section; headings produce the TOC. KF8 `kindle:pos:fid:…:off:…` and KF7 `filepos=…` links are rewritten to in-page anchors in the same pass as the sidebar anchors.
- Markdown: the whole file is ONE section (`id "md"`); `toc = []` and `tocIsFallback: false` on purpose, because the renderer's heading-derived sidebar is always clickable. UTF-8 read, isoLatin1 fallback. Optional `---…---` YAML front matter feeds only title/author; title priority is front matter, then first rendered `<h1>`, then filename; `contentBytes` is the UTF-8 byte count. No scratch directory is used.
- FB2: the whole book is one section, same as MOBI (annotations live in a second `<body>` and would lose their anchors across sections). `<title>` → `<h1>`–`<h3>` by section depth, so the heading derivation *is* the TOC; `toc = []`, `tocIsFallback: false`. Entities are fixed up but bare `<` / unclosed tags still fail honestly to the notice page.
- FB2 without any `<title>` (what the common converters produce): the parse records each section's start offset, depth, paragraph count and first paragraph, and `promotedContents` guesses headings from that - section's first paragraph = its title, self-declaring lines ("Part II", "Chapter 4") = h1/h2, and (only if those found < 3) a whole-paragraph bold line = h2. Both the setting and the sidebar note are part of the contract: `Book.tocNote` must say the contents were guessed, because a guessed list that looks like the book's own structure is a fake affordance. A book that *has* `<title>` elements is never guessed at.
- Resource URLs: `ekbres://local/…` (unpacked / in-memory archive), `ekbres://mobi/<uid>` (libmobi resource) and `ekbres://fb2/<image-id>` (inline base64). Markdown reads no book resources (its Mermaid/KaTeX assets belong to the appex, not the book).
- DjVu is a page-image format, so it is the one backend that decodes nothing: `DjVuStructure` reads the container (chunk tree, `DIRM` directory, `NAVM` outline, `ANTz` metadata; `INI`/`INFO` page sizes) and the page images are handed over as bytes - `ekbres://djvu/page/<index>` (a page's own `FORM:DJVU`, wrapped in the `AT&T` magic so it parses as a stand-alone file) or `ekbres://djvu/document` (the whole file) when a page inherits a shared dictionary via `INCL`. `EBookQLPreview/DjVuAssets/` rasterises them in the web view; JB2/IW44 have no system decoder and are not worth a second implementation.
- DjVu `Book`: one section per page (hidden `<h1 id="page-N">` for a real reading-position anchor, then `div.djvu-frame[data-page][data-label][data-source]` with the page's `aspect-ratio` so the height is reserved before anything is decoded); `sourcePath` = the directory id (`00000002.djvu`) or `page-N`, which is also what outline targets resolve to.
- DjVu TOC: the file's own `NAVM` outline wins and sets `tocIsFallback: false`; a bookmark fragment is a page number (`#3`, one-based) or a component name, and an unresolvable one degrades to a non-clickable label. With no outline, a *page list* stands in, with `tocIsFallback: true` **and** `tocNote` - the entries are page numbers, not the book's contents, and the sidebar has to say so. One page means no sidebar at all.
- DjVu labels: a directory title that is not just the component's file name (`p1.djvu`, `00000001.djvu`), else the page number (see `DjVuFileNames.looksLikeFileName`).
- DjVu refuses honestly rather than half-rendering: the indirect (multi-file) flavour throws - its pages are sibling files the sandbox cannot read - and a damaged `DIRM` costs the contents, not the preview.
- BZZ is needed for `DIRM`/`NAVM`/`ANTz` (writers always compress those four) and is the only compression implemented here; `DjVuBZZ` is a line-by-line port of the JavaScript decoder, checked byte-for-byte against it on real `DIRM`/`NAVM` payloads.
- CBZ (and DjVu, which shares it) is a **page-image book**: `PageImageBook` owns what both formats do identically - one section per page, a hidden `<h1 class="page-no">` for the reading anchor, the page box (`page-frame`, `aspect-ratio` from the page's own size, `data-label`, `data-source`), the contents rule (declared outline wins, else a page list with `tocNote`, else no sidebar for one page) and the `pageListNote` string. A new page-image format should reach for it rather than repeat it.
- CBZ: pages are the ZIP's image entries, sorted in **reading order** (digit runs compare as numbers, so `page9` < `page10`; an archive's own order is not a promise), with `__MACOSX/`, `._*`, `.DS_Store` excluded. Each page's pixel size comes from its own image header (PNG/GIF/JPEG/WebP/BMP, parsed here) read from a **prefix** of the entry - only enough of the file is inflated to reach the header. `ComicInfo.xml` (ComicRack's manifest) supplies title (`Series #Number`, else `Title`), author (`Writer`) and per-page **bookmarks**, which are the declared TOC; its `Image` attribute is a page index, but a file name is accepted because writers do that too. Pages in folders become one TOC level per folder, because 600 pages named `001`-`050` sixteen times is not navigation.
- CBZ pages are plain `<img loading="lazy" decoding="async">` inside their box: nothing is decoded in Swift and no script is shipped for them, so the web view fetches and decompresses exactly the pages near the viewport (`ekbres://cbz/page/<index>`, one entry at a time, on the scheme handler's serial queue - the same convention as the EPUB provider).
- CBZ image headers: `CBZImageHeader` reads PNG/GIF/JPEG/WebP/BMP itself (ImageIO is not used: the data is deliberately a truncated prefix). The JPEG path also reads the EXIF **orientation** (0x0112) and swaps the sides for 5-8, because WebKit applies orientation when it draws the image (measured: `naturalWidth` of an orientation-6 JPEG comes back rotated) - a box sized from the raw frame header would clip the page.
- `Archive.extract`'s consumer cannot stop early (it returns Void), so `CBZDocument.prefix` aborts by throwing from inside it, with `skipCRC32: true`. Nothing is left half-read: the next extract seeks first.
- Keep parsing deterministic and side-effect free apart from the work directory.

## ANTI-PATTERNS
- Calling `mobi_parse_rawml`.
- Reading the whole book for a thumbnail (use `openForThumbnail`: in-memory limit 0, one section).
- Building the NCX tree by level instead of parent pointers, or skipping empty-title entries.
- Emitting already-prefixed anchors for in-body links — the renderer prefixes unconditionally.
- Forgetting `tocIsFallback` on the chosen TOC.
- Sharing one `JSContext` across parses (JavaScriptCore is not thread-safe) or parsing Markdown by hand in Swift instead of through the embedded `marked` in `MarkdownRenderer`.
- Guessing FB2 contents for a book that has `<title>` elements, or mixing guessed entries into a declared/heading-derived TOC (`titles == 0` is the only gate that matters).
- Shipping a guessed FB2 TOC without `Book.tocNote`: the sidebar has to say the entries were guessed.
- Editing backslash-heavy Swift string literals through a tool that doubles backslashes: the FB2 regexes are raw strings (`#"…"#`) for that reason, and a doubled `\s` silently matches a literal backslash.
- Giving a Markdown book a declared TOC (`tocIsFallback: true`): its heading ids are the contract.
- Decoding a DjVu page in Swift: there is no system decoder, and JB2/IW44 is a project of its own - the reader's page decodes it in the web view (see EBookQLPreview/DjVuAssets/).
- Serving a whole document's bytes for a normal DjVu (bounded memory is the point of the per-page route), or a page's own bytes for a document whose pages carry `INCL` (they cannot be decoded without the shared dictionary).
- Reading the whole file for a DjVu thumbnail: `openForThumbnail` reads `DjVuStructureReader.headerBytes` and gets the count and the metadata from the directory.
- A DjVu page list without `tocNote`, or with `tocIsFallback: false`.
- Repeating the page-image plumbing per format: sections, the page box and the contents rule belong to `PageImageBook`.
- Trusting a ZIP's entry order for a CBZ page sequence, or inflating a whole entry to find its image header.
- Claiming `.cbr`/`.cbt` (RAR/TAR): neither is a ZIP, and neither is read here.

## NOTES
- Long MOBI bodies are truncated at 8 MB of text (`Book.truncatedAt`); sidebar entries past the cut become non-clickable labels.
- FB2 reuses that 8 MB markup budget and caps inline images at 64 MB; measured on the two real title-less books, the guess costs +0.2 s on a 2.4 MB file (0.70 s → 0.91 s parse+build) and yields a two-level tree both times.
- Encrypted / corrupt / unsupported MOBI errors go through the shared notice page — never crash.
- Markdown fidelity (in the `bootstrapJS`): GFM; GitHub-style heading `id`s; mermaid code fences become `<pre class="mermaid">`; `$…$` / `\(…\)` become `.math-inline`, `$$…$$` / `\[…\]` become `.math-block`; math inside code fences/inline code is left alone; `$5 and $10` is not read as math; MDX lone `import`/`export` lines are dropped.
- With `markdownRendering == false` the backend returns the escaped raw source in `<pre class="markdown-source">` and never touches JavaScriptCore.
