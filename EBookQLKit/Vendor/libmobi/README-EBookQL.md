# libmobi as vendored here

This directory is **libmobi** by Bartek Fabiszewski — <http://www.fabiszewski.net>,
<https://github.com/bfabiszewski/libmobi> — used by EBookQL to parse MOBI, AZW and AZW3
(KF7 and KF8) books. It is licensed under the **GNU Lesser General Public License, either
version 3 or any later version**: the licence text is `COPYING` here, and `COPYING.GPL-3.0`
is the GPL version 3 text that the LGPL incorporates by reference.

## This copy is not a pristine upstream release

It was taken from the author's own **MobiFile** project (`MobiFile/lib/`) and is byte for
byte identical to that copy. It was **not** compared successfully against any upstream
tag — `read.c` differs from upstream v0.7, v0.8, v0.9, v0.10, v0.11 and v0.12 alike (about
750 lines each), and the differences are not cosmetic: the buffer API is `buffer_init` /
`buffer_free` where upstream spells it `mobi_buffer_init` / `mobi_buffer_free`. So this is a
**modified or repackaged variant whose upstream version is not recorded anywhere**; treat it
as modified, which is what the LGPL asks a redistributor to disclose.

If a clean provenance is wanted, replace the library files below with a pinned upstream
release and rebuild — the public API EBookQL uses (`mobi_parse_index`,
`mobi_get_indxentry_tagvalue`, `mobi_get_cncx_string`, `mobi_get_fileversion`, …) is the same
across those versions. `MobiShim.c` is the only place EBookQL touches the library.

## Which files are whose

- **libmobi's own**: every `.c` and `.h` here except the three below, plus `COPYING`.
- **EBookQL's**: `MobiShim.h`, `MobiShim.c` (the thin C boundary Swift sees instead of the
  library's headers) and `module.modulemap`. These are not part of libmobi and are covered by
  EBookQL's own MIT licence.

## How it is linked, and why that matters

The library is compiled into `EBookQLKit`, which is a **static** library linked into both
extensions (`EBookQLPreview.appex`, `EBookQLThumbnail.appex`) — an ad-hoc-signed appex
cannot load an embedded dynamic framework. The LGPL's relinking requirement is met by the
sources being right here: rebuild against a modified or replacement copy of libmobi with

```sh
./install.sh            # regenerates the project with xcodegen and rebuilds from these sources
```

If you replace these files, keep the licence text alongside them.
