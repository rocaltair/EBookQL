# App icon

`EBookQLApp/AppIcon.icns` is what ships (referenced by `CFBundleIconFile` in
`EBookQLApp/Info.plist`). It is **generated**, not drawn by hand.

## Where it came from

A local render by `mimg` (MLX/mflux on the GPU), then cut to the macOS icon shape by
`make_icon.py` in this directory.

```sh
export CONDA_NO_PLUGINS=true
~/bin/mimg -m klein -S 1024x1024 -s 4 -N 4 -o cand.png \
"full-bleed square app icon, background is a deep indigo to violet gradient filling the whole canvas edge to edge, centred in the middle one open book with crisp blank cream pages and a slim silver magnifying glass tilted over the right page, flat vector illustration, bold simple geometric shapes, thick clean outlines, soft drop shadow under the book, generous empty space around the subject, no text, no letters, no words, no writing on the pages, no posters, plain background"
```

`-N 4` writes four variations of that prompt (`cand_01..04.png`, seeds +0..+3); the one
kept is `AppIcon-source.png` — the fourth, `seed=1349281998`, chosen for having the
cleanest outlines and the most even margins, which is what survives at 16 px.

Then, with a Python that has Pillow (`~/.local/share/uv/tools/mflux/bin/python`):

```sh
python3 make_icon.py AppIcon-source.png out      # -> out/AppIcon.icns + out/icon-1024.png
cp out/AppIcon.icns ../EBookQLApp/AppIcon.icns
```

## Why the script exists

macOS icons are not a full-bleed square: the artwork sits in a rounded body of **824 px
inside the 1024 px canvas** (100 px of margin all round) with a corner radius of about
**184**. Pasting the raw render in edge to edge makes it visibly larger and squarer than
every system icon beside it. The script masks that shape (drawn 4× and shrunk, so the
curve has no jaggies), then emits the ten sizes the `.icns` wants — 16/32/128/256/512
each at 1× and 2× — via `iconutil`.

Notes for a re-render:

- Keep the artwork **free of any lettering**: these models invent garbled text wherever a
  prop implies writing, and the prompt's "no text" prefix alone does not prevent it. Blank
  pages are part of the prompt for that reason.
- `mfimg` never overwrites: a re-run into an existing filename lands in `<name>_1.png`, so
  `rm` the target first.
- The subject is left at its rendered size and only the corners are masked — the script
  does not zoom, so a re-render keeps the margins the model produced.
