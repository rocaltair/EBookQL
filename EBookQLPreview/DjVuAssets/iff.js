// DjVu IFF container parser: "AT&T" magic, FORM chunk tree, DJVU/DJVM
// documents, page enumeration, and the (uncompressed) INFO chunk.
//
// DIRM (the multi-page directory) is BZZ-compressed for component names and is
// parsed in dirm.js once the BZZ decoder exists. For a *bundled* DJVM we can
// enumerate pages directly from the chunk tree, which is enough to render.

import { ByteStream } from './bytestream.js';

const CONTAINER = new Set(['FORM', 'LIST', 'PROP', 'CAT ']);

function fourcc(u8, off) {
  return String.fromCharCode(u8[off], u8[off + 1], u8[off + 2], u8[off + 3]);
}

export class Chunk {
  constructor(id, isForm, formType, bytes, start, length) {
    this.id = id;             // 4-char id; 'FORM' for containers
    this.isForm = isForm;
    this.formType = formType; // 'DJVU' | 'DJVM' | 'DJVI' | 'THUM' (forms only)
    this.bytes = bytes;       // Uint8Array of payload; for forms it INCLUDES
                              //   the leading 4-byte secondary type
    this.start = start;       // absolute offset of payload in the file buffer
    this.length = length;     // declared payload length
    this.children = [];
  }

  get name() { return this.isForm ? `${this.id}:${this.formType}` : this.id; }
  child(id) { return this.children.find((c) => c.id === id) || null; }
  childForm(formType) {
    return this.children.find((c) => c.isForm && c.formType === formType) || null;
  }
  childrenWith(id) { return this.children.filter((c) => c.id === id); }
  /** Payload of a leaf chunk as a ByteStream. */
  stream() { return new ByteStream(this.bytes); }
}

function parseChunks(u8, start, end) {
  const chunks = [];
  let p = start;
  while (p + 8 <= end) {
    const id = fourcc(u8, p);
    const size = ((u8[p + 4] << 24) | (u8[p + 5] << 16) | (u8[p + 6] << 8) | u8[p + 7]) >>> 0;
    const dataStart = p + 8;
    const dataEnd = Math.min(dataStart + size, end);
    if (CONTAINER.has(id)) {
      const formType = fourcc(u8, dataStart);
      const c = new Chunk(id, true, formType, u8.subarray(dataStart, dataEnd), dataStart, size);
      c.children = parseChunks(u8, dataStart + 4, dataEnd);
      chunks.push(c);
    } else {
      chunks.push(new Chunk(id, false, null, u8.subarray(dataStart, dataEnd), dataStart, size));
    }
    p = dataStart + size;
    if (size & 1) p++; // IFF chunks are padded to an even length
  }
  return chunks;
}

export class DjVuDocument {
  /** @param {Uint8Array} u8 entire file */
  constructor(u8) {
    this.bytes = u8;
    if (u8.length < 12 || fourcc(u8, 0) !== 'AT&T') {
      throw new Error('Not a DjVu file (missing "AT&T" magic)');
    }
    const top = parseChunks(u8, 4, u8.length);
    if (!top.length || !top[0].isForm) throw new Error('Missing top-level FORM');
    this.form = top[0];
    this.type = this.form.formType;
    this.pages = [];       // FORM:DJVU chunks, in document order
    this.components = [];   // FORM:DJVU + FORM:DJVI (for INCL / shared dicts)
    this.thumbnails = [];
    this.dirm = null;

    if (this.type === 'DJVM') {
      this.dirm = this.form.child('DIRM');
      for (const c of this.form.children) {
        if (!c.isForm) continue;
        if (c.formType === 'DJVU') { this.pages.push(c); this.components.push(c); }
        else if (c.formType === 'DJVI') this.components.push(c);
        else if (c.formType === 'THUM') this.thumbnails.push(c);
      }
    } else if (this.type === 'DJVU') {
      this.pages.push(this.form);
      this.components.push(this.form);
    } else {
      throw new Error('Unsupported top-level form: ' + this.type);
    }
  }

  get pageCount() { return this.pages.length; }
}

/** Decode the (uncompressed) INFO chunk per the DjVu format. */
export function parseInfo(chunk) {
  const b = chunk.bytes;
  const size = b.length;
  let width = 0, height = 0, version = 24, dpi = 300, gamma = 2.2, flags = 0;
  if (size >= 2) width = (b[0] << 8) | b[1];
  if (size >= 4) height = (b[2] << 8) | b[3];
  if (size >= 5) version = b[4];
  if (size >= 6 && b[5] !== 0xff) version = (b[5] << 8) | b[4];
  if (size >= 8 && b[7] !== 0xff) dpi = (b[7] << 8) | b[6]; // little-endian
  if (size >= 9) gamma = 0.1 * b[8];
  if (size >= 10) flags = b[9];
  if (gamma < 0.3) gamma = 0.3;
  if (gamma > 5.0) gamma = 5.0;
  if (dpi < 25 || dpi > 6000) dpi = 300;
  let orientation = 0; // 0:none 1:ccw90 2:180 3:cw90
  switch (flags & 0x7) {
    case 6: orientation = 1; break;
    case 2: orientation = 2; break;
    case 5: orientation = 3; break;
    default: orientation = 0; break;
  }
  return { width, height, version, dpi, gamma, orientation };
}
