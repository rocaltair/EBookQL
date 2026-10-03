# EBookQLKit/Backend

Two parsers behind one protocol. `BookOpener.backend(for:)` picks by file extension; `BookBackend.open(_:workDirectory:)` returns a `Book`.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Protocol, dispatch, path helpers | BookBackend.swift:34 / :49 / :79 |
| EPUB (ZIP + OPF/NCX, EPUB3 nav) | EPUB/EPUBBackend.swift:21 |
| MOBI/AZW/AZW3 (libmobi, KF7 + KF8) | MOBI/MOBIBackend.swift:22 |
| C↔Swift boundary | ../Vendor/libmobi/MobiShim.h |

## CONVENTIONS
- EPUB: books up to ~512 MB are read into memory (physical-memory/4 floor); larger ones stream from the archive. Only text (`xhtml/html/opf/ncx/xml/css`) is unpacked to the work dir; images/fonts stay in the archive and are served via `ekbres://`.
- EPUB TOC: EPUB3 `nav` first, NCX fallback; the richer of declared-vs-heading-derived wins.
- MOBI: the whole book is one section; headings produce the TOC. KF8 `kindle:pos:fid:…:off:…` and KF7 `filepos=…` links are rewritten to in-page anchors in the same pass as the sidebar anchors.
- Resource URLs: `ekbres://local/…` (unpacked / in-memory archive) and `ekbres://mobi/<uid>` (libmobi resource).
- Keep parsing deterministic and side-effect free apart from the work directory.

## ANTI-PATTERNS
- Calling `mobi_parse_rawml`.
- Reading the whole book for a thumbnail (use `openForThumbnail`: in-memory limit 0, one section).
- Building the NCX tree by level instead of parent pointers, or skipping empty-title entries.
- Emitting already-prefixed anchors for in-body links — the renderer prefixes unconditionally.
- Forgetting `tocIsFallback` on the chosen TOC.

## NOTES
- Long MOBI bodies are truncated at 8 MB of text (`Book.truncatedAt`); sidebar entries past the cut become non-clickable labels.
- Encrypted / corrupt / unsupported MOBI errors go through the shared notice page — never crash.
