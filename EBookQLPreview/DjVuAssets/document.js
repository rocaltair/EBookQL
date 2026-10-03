// High-level DjVu document API: parses the container, the DIRM multi-page
// directory, resolves INCL shared components (shared JB2 dictionaries), and
// assembles a page's decoded layers (mask, background, foreground, text).

import { DjVuDocument as Container, parseInfo } from './iff.js';
import { ByteStream } from './bytestream.js';
import { bzzDecompress } from './bzz.js';
import { decodeJB2Image, decodeJB2Dict } from './jb2.js';
import { decodeIW44 } from './iw44.js';
import { decodeMMR } from './mmr.js';
import { parseFGbz } from './color.js';
import { parseText } from './text.js';
import { parseAnnotations } from './annotations.js';

const utf8 = new TextDecoder('utf-8', { fatal: false });

// DIRM file-type flags
const TYPE_MASK = 0x3f;
const T_PAGE = 1;
const HAS_NAME = 0x80;
const HAS_TITLE = 0x40;

function parseDIRM(chunk) {
  const bs = new ByteStream(chunk.bytes);
  let ver = bs.read8();
  const bundled = (ver & 0x80) !== 0;
  ver &= 0x7f;
  const nfiles = bs.read16();
  const files = [];
  for (let i = 0; i < nfiles; i++) {
    const f = { offset: 0, size: 0, flags: 0, id: '', name: '', title: '', type: 0 };
    if (bundled) { f.offset = bs.read32(); if (ver === 0) f.size = bs.read24(); }
    files.push(f);
  }
  const raw = bzzDecompress(new ByteStream(chunk.bytes, bs.pos));
  const rs = new ByteStream(raw);
  if (ver > 0) for (const f of files) f.size = rs.read24();
  for (const f of files) f.flags = rs.read8();
  // Remaining bytes are NUL-separated id [name] [title] per file.
  let p = rs.pos;
  const readCStr = () => {
    const start = p;
    while (p < raw.length && raw[p] !== 0) p++;
    const s = utf8.decode(raw.subarray(start, p));
    p++;
    return s;
  };
  for (const f of files) {
    f.id = readCStr();
    f.name = (f.flags & HAS_NAME) ? readCStr() : f.id;
    f.title = (f.flags & HAS_TITLE) ? readCStr() : f.id;
    f.type = f.flags & TYPE_MASK;
  }
  return { bundled, ver, files };
}

function inclId(chunk) {
  return utf8.decode(chunk.bytes).replace(/[\s\0]+$/g, '').trim();
}

export class DjVuDoc {
  constructor(u8) {
    this.container = new Container(u8);
    this.id2form = new Map();
    this.pageForms = [];
    this.titles = [];

    if (this.container.type === 'DJVM' && this.container.dirm) {
      const dirm = parseDIRM(this.container.dirm);
      this.dirm = dirm;
      // Components (FORM children) are listed in the same order as DIRM files.
      const comps = this.container.form.children.filter(
        (c) => c.isForm && (c.formType === 'DJVU' || c.formType === 'DJVI' || c.formType === 'THUM'));
      for (let i = 0; i < dirm.files.length && i < comps.length; i++) {
        this.id2form.set(dirm.files[i].id, comps[i]);
        if (dirm.files[i].type === T_PAGE) {
          this.pageForms.push(comps[i]);
          this.titles.push(dirm.files[i].title || dirm.files[i].name);
        }
      }
      // Fallback if directory and tree disagree.
      if (!this.pageForms.length) {
        this.pageForms = this.container.pages;
        this.titles = this.pageForms.map((_, i) => `Page ${i + 1}`);
      }
    } else {
      this.pageForms = this.container.pages;
      this.titles = this.pageForms.map((_, i) => `Page ${i + 1}`);
    }
  }

  get pageCount() { return this.pageForms.length; }

  // Build the shared (inherited) JB2 dictionary for a component, following its
  // INCL references recursively. Returns a JB2 dict decoder or null.
  _buildInheritedDict(form, seen = new Set()) {
    let parent = null;
    for (const incl of form.childrenWith('INCL')) {
      const id = inclId(incl);
      if (seen.has(id)) continue;
      seen.add(id);
      const comp = this.id2form.get(id);
      if (!comp) continue;
      const grandparent = this._buildInheritedDict(comp, seen);
      const djbz = comp.child('Djbz');
      parent = djbz ? decodeJB2Dict(djbz.bytes, grandparent || parent) : (grandparent || parent);
    }
    return parent;
  }

  /** Fast: decode only the hidden text layer of a page (no image decode). */
  decodePageText(index) {
    const form = this.pageForms[index];
    if (!form) return { text: '', page: null };
    const txtChunk = form.child('TXTz') || form.child('TXTa');
    return txtChunk ? parseText(txtChunk) : { text: '', page: null };
  }

  /** Page dimensions without decoding images (from INFO). */
  pageInfo(index) {
    const form = this.pageForms[index];
    return form && form.child('INFO') ? parseInfo(form.child('INFO')) : null;
  }

  /** Decode all layers of a page (codecs run here; compositing is in render.js). */
  decodePageLayers(index) {
    const form = this.pageForms[index];
    if (!form) throw new Error('page out of range: ' + index);
    const info = parseInfo(form.child('INFO'));

    // Bilevel mask: JB2 (Sjbz, may inherit a shared Djbz) or MMR/G4 (Smmr).
    const sjbz = form.child('Sjbz');
    const smmr = form.child('Smmr');
    let jb2 = null, mask = null;
    if (sjbz) {
      let inherited = this._buildInheritedDict(form);
      // A page (or its INCLs) may also carry its shape dictionary inline as a
      // Djbz chunk in the same form; that dictionary applies to this Sjbz.
      const ownDjbz = form.child('Djbz');
      if (ownDjbz) inherited = decodeJB2Dict(ownDjbz.bytes, inherited);
      jb2 = decodeJB2Image(sjbz.bytes, inherited);
      if (!info.width || !info.height) { info.width = jb2.image_columns; info.height = jb2.image_rows; }
    } else if (smmr) {
      mask = decodeMMR(smmr.bytes);
      if (!info.width || !info.height) { info.width = mask.width; info.height = mask.height; }
    }

    const bgChunks = form.childrenWith('BG44');
    const bg = bgChunks.length ? decodeIW44(bgChunks.map((c) => c.bytes)) : null;

    const fgChunk = form.child('FGbz');
    const fgbz = fgChunk ? parseFGbz(fgChunk.bytes) : null;

    const fg44 = form.childrenWith('FG44');
    const fgPixmap = fg44.length ? decodeIW44(fg44.map((c) => c.bytes)) : null;

    // JPEG layers (BGjp/FGjp) are decoded with the browser's native codec in
    // the worker; here we just surface the raw bytes when no wavelet layer wins.
    const bgjp = form.child('BGjp');
    const fgjp = form.child('FGjp');
    const bgJpeg = (!bg && bgjp) ? bgjp.bytes : null;
    const fgJpeg = (!fgPixmap && fgjp) ? fgjp.bytes : null;

    const txtChunk = form.child('TXTz') || form.child('TXTa');
    const text = txtChunk ? parseText(txtChunk) : { text: '', page: null };

    const antChunk = form.child('ANTz') || form.child('ANTa');
    const annotations = antChunk ? parseAnnotations(antChunk) : null;

    return { index, info, jb2, mask, bg, fgbz, fgPixmap, bgJpeg, fgJpeg, text, annotations };
  }
}
