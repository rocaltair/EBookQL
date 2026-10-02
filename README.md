# EBookQL

Quick Look previews **and thumbnails** for EPUB, MOBI, AZW and AZW3 books on macOS —
select a book in the Finder, press **Space**, read it.

![screenshot](docs/screenshot.png)

One reader UI over two parsers (an EPUB one and a libmobi-backed MOBI one), so all four
formats look and behave the same: the same sidebar, the same controls, the same reading
position, the same thumbnail card.

## What you get

- **Quick Look preview** — a full window in the Finder's Quick Look panel: the book's own
  text in a readable column, its images, and a covering page instead of a blank panel.
- **Table of contents** — a folding tree in the sidebar. The chapter you are reading is
  highlighted as you scroll, the part it lives in unfolds itself, and the sidebar follows
  so the highlighted entry stays in view. Click to jump; the book's own internal links work
  too.
- **Picks the richer table of contents** — some books declare a good one in their container
  and some only mark up headings, so both are read and the one with more entries wins.
- **Reading position** — the panel comes back to where you stopped, per book, in a small
  SQLite file, with a "Resumed at NN%" pill that can send you back to the top.
- **Text size** — A− / 100% / A+ in the sidebar header, or ⌘ + two-finger scroll anywhere in
  the panel. Holding a button keeps stepping, because Quick Look opens the file in its
  default app on a double-click anywhere in the panel, so two quick clicks are not an
  option. Only the book's text scales: the sidebar, the images and the panel keep their size.
- **Resizable sidebar** — drag the divider; the width is remembered.
- **Thumbnails** — the Finder shows a card built from the book's own title, author and
  opening lines rather than a generic icon.
- **Large books stay responsive** — the book is one page, so sections below the fold are
  not laid out until they are needed.
- **No network** — the extensions are sandboxed, and the custom scheme that feeds images
  to the preview only ever serves the book being previewed.

## Install

### From the disk image

1. Open `EBookQL-0.1.0.dmg`.
2. Drag **EBookQL** onto the **Applications** folder in that window.
3. **Open EBookQL once.** That is what registers its two extensions — copying the app by
   itself registers nothing. The window reports whether they are live, and re-registers
   them on request.

Then select a book in the Finder and press Space.

If the window says an extension is *switched off*, turn it on in
**System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look**, then reopen the
Finder. EBookQL will not switch an extension back on behind your back.

### From source

```sh
brew install xcodegen
./install.sh              # build, install into /Applications, register both extensions
./install.sh status       # what is registered, and how the book UTIs resolve
./install.sh history      # the reading-position database
./install.sh uninstall
```

`install.sh` builds Release and signs everything "Sign to Run Locally", so no Apple
developer account is needed. If `xcode-select` points at the Command Line Tools, the
script points `DEVELOPER_DIR` at Xcode itself.

## Formats

| Format | Read by | Notes |
|---|---|---|
| `.epub` | the project's own ZIP + OPF/NCX reader | zipped `.epub` |
| `.mobi`, `.azw`, `.azw3` | [libmobi](https://github.com/bfabiszewski/libmobi), vendored | KF7 and KF8; images and the container's NCX table of contents are read from the file |

The MOBI family has no system-declared UTI, so the app exports one; the extensions also
declare the UTIs other readers export, because which declaration wins is not under the
extension's control.

## Requirements

- macOS 14.0 or later. Developed and tested on macOS 15.8 with Xcode 16.4.
- Universal: Apple silicon and Intel.
- Building from source needs Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen);
  `project.yml` is the source of truth and the `.xcodeproj` is generated.

## Known limitations

- **Very large MOBI bodies are cut at 8 MB of text.** Reference works can go past that; the
  preview says `Truncated preview: showing the first N MB of M MB`, and the entries beyond
  the cut stay in the sidebar as plain text rather than links. The alternative is a long
  first paint on every open.
- **Some Calibre conversions name anchors that were never created.** Those entries land at
  the top of their chapter instead of at a heading inside it.
- **A downloaded copy is quarantined.** The app is ad-hoc signed and not notarized, so a
  copy that arrives over the network will not open until you right-click it and choose
  Open. A disk image handed over locally has no such flag.
- **Quick Look picks one extension per type.** If another reader also previews the same
  formats, disable it while testing EBookQL.

## Licence

EBookQL is MIT licensed — see [LICENSE](LICENSE).

MOBI parsing is by **libmobi**, licensed LGPL-3.0-or-later and vendored under
`EBookQLKit/Vendor/libmobi` (licence text: that directory's `COPYING`; provenance and how it
is linked: `README-EBookQL.md` there). Note that the vendored copy comes from this author's
own MobiFile project rather than from a pristine upstream release. It is statically linked
into the extensions, so the vendored sources are the copy you can rebuild and relink
against. ZIPFoundation (MIT) is used for EPUB containers.
