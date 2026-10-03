# Third-Party Notices — EBookQL DjVu Assets

This directory vendors the JavaScript DjVu decoder the EBookQL Quick Look
preview extension runs inside its network-less `WKWebView` (served through the
`ekbres://` scheme), plus `djvu-viewer.js`, which is EBookQL's own glue and not
vendored from anywhere.

| File | Upstream | Commit | License |
|------|----------|--------|---------|
| `iff.js`, `document.js`, `bytestream.js` | [DejaView](https://github.com/Alpaq92/dejaview) `src/` | `ae7aed2` (2026-06-26) | MIT |
| `zp.js`, `zp_table.js`, `bzz.js` | idem | idem | MIT |
| `jb2.js`, `mmr.js`, `mmr_tables.js` | idem | idem | MIT |
| `iw44.js`, `color.js`, `text.js`, `annotations.js`, `render.js` | idem | idem | MIT |
| `djvu-viewer.js` | EBookQL | — | MIT (same as EBookQL) |

All vendored files are upstream, byte for byte. Two upstream files are
deliberately not taken:

- `jpeg.js` + `src/jspeg/` — the pure-JavaScript JPEG decoder DejaView falls
  back to when the host has no `createImageBitmap`. A `WKWebView` has it, so
  `djvu-viewer.js` decodes `BGjp`/`FGjp` layers with the platform codec instead.
- `worker.js` and `viewer.js` — the upstream viewer's UI and its worker split.
  A page loaded from `file://` cannot start a worker (measured), so the glue
  decodes on the main thread, one page at a time.

The upstream `NOTICE` and `LICENSE` are shipped beside this file as
`NOTICE-dejaview` and `LICENSE-dejaview`.

---

## DejaView — MIT License

Source: https://github.com/Alpaq92/dejaview (commit `ae7aed2`)

```
MIT License

Copyright (c) 2026 Roman Chojnacki

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### What DejaView's decoder is built from

Summarised from its own `NOTICE` (shipped verbatim as `NOTICE-dejaview`):

- The DjVu container, ZP coder, JB2, IW44 and BZZ implement the **public DjVu
  format**; they were cross-referenced against
  [DjvuNet](https://github.com/DjvuNet/DjvuNet) (MIT), and the ZP adaptation
  table (`zp_table.js`) is taken from it.
- The MMR/G4 code tables (`mmr_tables.js`) are the public **ITU-T T.6 / T.4**
  standard codes.
- DjVuLibre (GPL) was used only as a *conformance test oracle* upstream — to
  encode sample files. No DjVuLibre code is included here, which is what keeps
  this side of EBookQL MIT-clean: the preview decodes DjVu with MIT code only.
  (EBookQL's own Swift reader *and* its JavaScript decoder can therefore stay
  under one licence. The one thing not done is a native decoder, which would
  have meant vendoring DjVuLibre.)

## EBookQL's own glue

`djvu-viewer.js` is written for this project: it fetches each page's bytes over
`ekbres://`, drives the vendored decoder, paints the result into the page's
canvas, and keeps the decoded canvases inside a memory budget. Its format facts
(the page source paths, the `djvu-ready` / `djvu-failed` frame classes, the
`--djvu-zoom` variable) are documented in `AGENTS.md` and in
`EBookQLKit/Backend/DjVu/`.
