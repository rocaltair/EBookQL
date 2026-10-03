# EBookQLKit

**Static library.** The entire format-neutral core: parsers, model, HTML synthesis, position store. Both appex targets depend on it; it depends on nothing app-level.

## STRUCTURE
```
EBookQLKit/
├── Model/Book.swift          # Book, BookMetadata, BookSection, TOCEntry, BookTarget, ReadingPosition
├── Backend/
│   ├── BookBackend.swift     # protocol + BookOpener dispatch + BookParseError + BookPath
│   ├── EPUB/EPUBBackend.swift
│   └── MOBI/MOBIBackend.swift
├── Reader/                   # ReaderDocument, HTMLNormalizer, ReaderAssets → see Reader/AGENTS.md
├── Store/ReadingPositionStore.swift
└── Vendor/libmobi/           # vendored C — never edit
```

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Model contract every backend must produce | Model/Book.swift:112 (`Book`) |
| Add a format backend | Backend/BookBackend.swift:49 (`BookOpener.backends`) |
| Path/anchor normalization shared by backends | Backend/BookBackend.swift:79 (`BookPath`) |
| SQLite schema / prune policy | Store/ReadingPositionStore.swift |
| Backend internals | Backend/AGENTS.md |

## CONVENTIONS
- Backends are pure parsing: `url → Book`, no UI/WebKit. They receive a `workDirectory` for scratch (EPUB unpacks text; MOBI does not).
- `Book.toc` may be empty — the renderer derives from headings. A backend that HAS a declared TOC sets `tocIsFallback: false`; a derived one sets `true`. Missing this flag regressed both formats (DESIGN.md §12.6).
- `BookSection.html` is `<body>` inner content; `basePath` / `sourcePath` drive relative-link + resource resolution.
- Resources are exposed via `ResourceProvider.url(for:relativeTo:)`, returning `file://` or `ekbres://`.
- Errors surface as `BookParseError` (`unsupportedFormat`/`containerNotFound`/`opfNotFound`/`malformed`/`io`/`encrypted`/`corrupt`); encrypted/corrupt become a notice page, never a decrypt.
- `openForThumbnail` must stay cheap: first section only, never the whole file in memory.
- libmobi is reached ONLY through `MobiShim.h` (module `MobiLib`); `MobiShim.c` is the only file that touches libmobi. Strings from `MobiBook*String` MUST be freed with `MobiBookFreeString`; `MobiBookResource` bytes MUST NOT be freed.
- `BookPath.normalize` / `splitFragment` / `decodedFragment` centralize href handling — use them instead of ad-hoc URL math.

## ANTI-PATTERNS
- `mobi_parse_rawml` → SIGSEGV (resource records have NULL data). Use `first_resource_record + uid`.
- Exposing `mobi.h` / `util.h` / `buffer.h` in `module.modulemap` → `typedef redefinition` in buffer.h.
- Building NCX TOC trees from level/rank → wrong depth (rank is a category, not depth). Use `parent` pointers; accept only `parent < selfIndex`; never drop empty-title nodes (splice children up).
- Forgetting the cross-format TOC-selection rule in a new backend.
- Touching `Vendor/libmobi/**`.

## NOTES
- `ReaderAssets` is the one place reader HTML/CSS/JS live (a static lib bundles no resources).
- `ReadingPositionStore` is a process-wide singleton; schema + path are in DESIGN.md §8.
