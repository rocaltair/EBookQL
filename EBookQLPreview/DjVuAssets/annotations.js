// Annotations (ANTa / ANTz). The payload is a sequence of S-expressions
// (background colour, metadata, hyperlink mapareas, view mode/zoom). For the
// reader we expose the raw text plus a few useful extracted hints; full
// maparea/hyperlink handling can be layered on later.

import { ByteStream } from './bytestream.js';
import { bzzDecompress } from './bzz.js';

const utf8 = new TextDecoder('utf-8', { fatal: false });

export function parseAnnotations(chunk) {
  const raw = chunk.id === 'ANTz' ? bzzDecompress(new ByteStream(chunk.bytes)) : chunk.bytes;
  const text = utf8.decode(raw);

  let background = null;
  const bg = text.match(/\(\s*background\s+#?([0-9A-Fa-f]{6})\s*\)/);
  if (bg) background = '#' + bg[1];

  let zoom = null;
  const zm = text.match(/\(\s*zoom\s+([a-z0-9]+)\s*\)/);
  if (zm) zoom = zm[1];

  const metadata = {};
  const meta = text.match(/\(\s*metadata\b([\s\S]*?)\)\s*$/m);
  if (meta) {
    const re = /\(\s*([\w-]+)\s+"((?:[^"\\]|\\.)*)"\s*\)/g;
    let m;
    while ((m = re.exec(meta[1]))) metadata[m[1]] = m[2];
  }

  return { text, background, zoom, metadata };
}
