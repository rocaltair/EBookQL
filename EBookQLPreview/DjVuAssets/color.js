// FGbz foreground colours (DjVuPalette). The actual compositing lives in
// render.js — this module only parses the palette. Implements the DjVu FGbz
// format, cross-referenced with the MIT-licensed DjvuNet.

import { ByteStream } from './bytestream.js';
import { bzzDecompress } from './bzz.js';

/**
 * Parse an FGbz chunk: a colour palette plus one palette-index per JB2 blit.
 * @returns {{palette:Array<[number,number,number]>, colordata:Int32Array|null}}
 */
export function parseFGbz(bytes) {
  const bs = new ByteStream(bytes);
  const version = bs.read8();
  if ((version & 0x7f) !== 0) throw new Error('FGbz: bad palette version');
  const palettesize = bs.read16();
  const palette = new Array(palettesize);
  for (let c = 0; c < palettesize; c++) {
    // stream order is B, G, R (the DjVu palette pixel byte order)
    const b = bs.read8(), g = bs.read8(), r = bs.read8();
    palette[c] = [r, g, b];
  }
  let colordata = null;
  if (version & 0x80) {
    const datasize = bs.read24();
    colordata = new Int32Array(datasize);
    const raw = bzzDecompress(new ByteStream(bytes, bs.pos));
    for (let d = 0; d < datasize; d++) colordata[d] = (raw[d * 2] << 8) | raw[d * 2 + 1];
  }
  return { palette, colordata };
}
