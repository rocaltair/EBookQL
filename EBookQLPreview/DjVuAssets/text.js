// Hidden text layer (TXTa / TXTz). Produces the UTF-8 page text plus a tree of
// zones (page > column > region > paragraph > line > word > character), each
// with a bounding box in DjVu image coordinates (origin at the bottom-left).
// Implements the DjVu hidden-text (TXTa/TXTz) format.

import { ByteStream } from './bytestream.js';
import { bzzDecompress } from './bzz.js';

const utf8 = new TextDecoder('utf-8', { fatal: false });

export const ZoneType = {
  PAGE: 1, COLUMN: 2, REGION: 3, PARAGRAPH: 4, LINE: 5, WORD: 6, CHARACTER: 7,
};
const { PAGE, PARAGRAPH, LINE } = ZoneType;
export const ZONE_NAMES = ['', 'page', 'column', 'region', 'paragraph', 'line', 'word', 'character'];

function decodeZone(bs, parent, prev) {
  const ztype = bs.read8();
  if (ztype < PAGE || ztype > ZoneType.CHARACTER) throw new Error('TXT: corrupt zone type');
  let x = bs.read16() - 0x8000;
  let y = bs.read16() - 0x8000;
  const width = bs.read16() - 0x8000;
  const height = bs.read16() - 0x8000;
  let textStart = bs.read16() - 0x8000;
  const textLength = bs.read24();
  if (prev) {
    if (ztype === PAGE || ztype === PARAGRAPH || ztype === LINE) {
      x = x + prev.xmin;
      y = prev.ymin - (y + height);
    } else {
      x = x + prev.xmax;
      y = y + prev.ymin;
    }
    textStart += prev.textStart + prev.textLength;
  } else if (parent) {
    x = x + parent.xmin;
    y = parent.ymax - (y + height);
    textStart += parent.textStart;
  }
  const zone = {
    type: ztype,
    xmin: x, ymin: y, xmax: x + width, ymax: y + height,
    textStart, textLength,
    children: [],
  };
  const size = bs.read24();
  let prevChild = null;
  for (let i = 0; i < size; i++) {
    const z = decodeZone(bs, zone, prevChild);
    zone.children.push(z);
    prevChild = z;
  }
  return zone;
}

/**
 * Parse a TXTa/TXTz chunk.
 * @returns {{text:string, page:object|null}} full text + zone tree (or null)
 */
export function parseText(chunk) {
  const raw = chunk.id === 'TXTz' ? bzzDecompress(new ByteStream(chunk.bytes)) : chunk.bytes;
  const bs = new ByteStream(raw);
  const textsize = bs.read24();
  const textBytes = raw.subarray(bs.pos, bs.pos + textsize);
  bs.skip(textsize);
  const text = utf8.decode(textBytes);
  let page = null;
  if (bs.remaining >= 1) {
    const version = bs.read8();
    if (version === 1) page = decodeZone(bs, null, null);
  }
  return { text, page };
}

/** Collect all zones of a given type into a flat array. */
export function collectZones(page, type, out = []) {
  if (!page) return out;
  if (page.type === type) out.push(page);
  for (const c of page.children) collectZones(c, type, out);
  return out;
}

/** The substring of `text` covered by a zone. */
export function zoneText(text, zone) {
  return text.substring(zone.textStart, zone.textStart + zone.textLength);
}
