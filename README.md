# EBookQL

Quick Look previews **and thumbnails** for EPUB, MOBI, AZW and AZW3 books, and for
Markdown, on macOS. Select a book or a note in the Finder, press **Space**, read it.

![screenshot](docs/screenshot.png)

One reader UI over three parsers (an EPUB one, a libmobi-backed MOBI one, and a
JavaScriptCore + `marked` Markdown one), so every format looks and behaves the same: the
same sidebar, the same controls, the same reading position, the same thumbnail card.
Markdown brings its own math and diagrams, rendered entirely offline.

## What you get

- **Quick Look preview** — a full window in the Finder's Quick Look panel: the book's own
  text in a readable column, its images, and a covering page instead of a blank panel.
- **Markdown, with math and diagrams** — `.md`, `.markdown` and `.mdx` render as GFM.
  Inline and display LaTeX become real math via KaTeX, fenced `mermaid` blocks become
  diagrams, and heading ids keep `[text](#heading)` links working. Both libraries are
  bundled, so nothing is fetched from the network.
- **Table of contents** — a folding tree in the sidebar, which opens as a plain outline. The
  entry you are reading is highlighted as you scroll, its branch unfolds itself so the
  highlight is never hidden, and the sidebar follows to keep it in view. The branch you have
  left closes behind you — unless you switch that off with the toggle beside *fold all*, and
  then the tree only ever opens. Click to jump; the book's own internal links work too.
- **Picks the richer table of contents** — some books declare a good one in their container
  and some only mark up headings, so both are read and the one with more entries wins.
- **Reading position** — the panel comes back to where you stopped, per book, in a small
  SQLite file, with a "Resumed at NN%" pill that can send you back to the top.
- **Text size** — A− / 100% / A+ in the sidebar header, or ⌘ + two-finger scroll anywhere in
  the panel. Holding a button keeps stepping, because Quick Look opens the file in its
  default app on a double-click anywhere in the panel, so two quick clicks are not an
  option. Only the book's text scales: the sidebar, the images and the panel keep their size.
- **Resizable sidebar** — drag the divider; the width is remembered. It stops at the width
  its own header row still fits in, rather than squeezing the controls.
- **See where a link leads** — hover a link or an image and its real target appears in a
  strip at the foot of the page, the way a browser does. An in-page link names the entry it
  jumps to; an image shows its URL.
- **Thumbnails** — the Finder shows a card built from the book's own title, author and
  opening lines rather than a generic icon.
- **A configuration window** — the app itself is a settings window, in two tabs. *General*
  switches the two Markdown extensions on or off and reports what this Mac has actually
  registered, with the system's own extension pane one button away. *Markdown* holds the
  rendering choices: JavaScript or plain source, line numbers, System/Light/Dark, and
  whether Markdown previews may load remote images.
- **Large books stay responsive** — the book is one page, so sections below the fold are
  not laid out until they are needed.
- **No network by default** — the extensions are sandboxed, and the custom scheme only ever
  serves the book being previewed plus the extension's own bundled rendering assets. A
  remote (http/https) image is not fetched: in Markdown it is replaced by a placeholder
  naming its host unless you allow network images in the app's Markdown tab, and EPUB/MOBI
  previews never load one at all.

## Install

### From the disk image

1. Open `EBookQL-0.2.0.dmg`.
2. Drag **EBookQL** onto the **Applications** folder in that window.
3. **Open EBookQL once.** That is what registers its four extensions: copying the app by
   itself registers nothing. The window reports whether they are live, carries the
   Markdown settings, and re-registers everything on request.

Then select a book or a Markdown file in the Finder and press Space.

If the window says an extension is *switched off*, turn it on in
**System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look**, then reopen the
Finder. EBookQL will not switch an extension back on behind your back.

### From source

```sh
brew install xcodegen
./install.sh              # build, install into /Applications, register all four extensions
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
| `.md`, `.markdown`, `.mdx` | JavaScriptCore + embedded [marked](https://github.com/markedjs/marked) | GFM; front matter supplies title/author; LaTeX math and mermaid diagrams render offline |

The MOBI family has no system-declared UTI, so the app exports one; the extensions also
declare the UTIs other readers export, because which declaration wins is not under the
extension's control. `.md` and `.markdown` use the system's own
`net.daringfireball.markdown` type, and `.mdx` is EBookQL's own type conforming to it.

## Markdown

`.md`, `.markdown` and `.mdx` get the same reader as books. GitHub-flavored Markdown is
parsed by an embedded copy of `marked`, and the sidebar is derived from the headings it
generates, so `[text](#heading)` links keep working. Inline and display LaTeX (`$…$`,
`$$…$$`, `\(…\)`, `\[…\]`) is typeset with KaTeX, and fenced `mermaid` blocks become
diagrams. Both libraries are vendored and served through the extension's own scheme, so
math and diagrams work with no network at all.

The app window is where Markdown is configured, in its Markdown tab: render with JavaScript
or show the raw source, line numbers, System/Light/Dark, and whether a remote
http/https image may be loaded. Network images are off by default — until you turn them on, a
remote image appears as a placeholder naming its host. The settings travel from the
unsandboxed app into the sandboxed Markdown extension through a small JSON file in the
extension's own container. Only the Markdown extension reads them; EPUB/MOBI previews ignore
them, and never load a remote image.

With JavaScript rendering off, a file is shown as escaped source instead, which is handy for
inspecting the markup; math and diagrams then appear as their source text.

## Requirements

- macOS 14.0 or later. Developed and tested on macOS 15.8 with Xcode 16.4.
- Universal: Apple silicon and Intel.
- Building from source needs Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen);
  `project.yml` is the source of truth and the `.xcodeproj` is generated.

## While reading

![The chapter being read highlighted in the sidebar](docs/screenshot-chapter.png)

The chapter you are reading is highlighted in the table of contents as you scroll, and the
part it lives in unfolds itself so that entry stays in view; the toggle beside *fold all*
stops the tree closing anything behind you, if you would rather it only ever open. Hovering a
link or an image names its target in a strip at the foot of the page. In a bilingual edition
the book's own cross-links (here 英文 / 中文) work as well.

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
- **Markdown math and diagrams need JavaScript rendering.** Turn that setting off and you
  get the escaped source instead. MDX `import` / `export` lines are dropped and JSX
  components are not executed either way.
- **Remote images are opt-in, and Markdown only.** They stay off until you allow network
  images in the app's Markdown tab; while off, a remote image is a placeholder naming its
  host. Plain `http` needs that switch too — without it the transport itself refuses the
  load. EPUB/MOBI previews never load remote images, switch or no switch.
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

Markdown parsing embeds **marked** (MIT). The Markdown preview extension also bundles
**Mermaid** (`@mermaid-js/tiny` 12.1.0, MIT) and **KaTeX** 0.19.0 (MIT, with its fonts under
the SIL OFL 1.1) under `EBookQLPreview/ReaderAssets/`; the licence texts are in that
directory's `NOTICES.md`.
