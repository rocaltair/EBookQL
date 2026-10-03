// JB2 decoder — the bilevel (black/white) layer of DjVu (the Sjbz mask and
// Djbz shared dictionaries). Implements the DjVu JB2 format, cross-referenced
// with the MIT-licensed DjvuNet (JB2/JB2Codec.cs).
//
// JB2 codes a page as a dictionary of small bitmaps ("shapes") plus a list of
// "blits" that stamp shapes onto the page at given positions. Shapes are coded
// either directly (arithmetic coding with a 10-pixel neighbourhood context) or
// by refinement against a similar earlier shape (11-pixel cross-coding context).
// All bits ride on the ZP coder; multi-valued numbers use an adaptive
// binary-decision tree (CodeNum).

import { ByteStream } from './bytestream.js';
import { ZPDecoder } from './zp.js';

const utf8 = new TextDecoder('utf-8', { fatal: false });

// Record types
const START_OF_DATA = 0;
const NEW_MARK = 1;
const NEW_MARK_LIBRARY_ONLY = 2;
const NEW_MARK_IMAGE_ONLY = 3;
const MATCHED_REFINE = 4;
const MATCHED_REFINE_LIBRARY_ONLY = 5;
const MATCHED_REFINE_IMAGE_ONLY = 6;
const MATCHED_COPY = 7;
const NON_MARK_DATA = 8;
const REQUIRED_DICT_OR_RESET = 9;
const PRESERVED_COMMENT = 10;
const END_OF_DATA = 11;

const BIGPOSITIVE = 262142;
const BIGNEGATIVE = -262143;
const CELLCHUNK = 20000;
const CELLEXTRA = 500;

// A bilevel bitmap with a zero border, stored bottom-up (row 0 = bottom),
// matching the DjVu bitmap convention (row 0 = bottom) used by JB2 contexts.
export class Bitmap {
  constructor(rows = 0, cols = 0, border = 0) { this.init(rows, cols, border); }

  init(rows, cols, border) {
    this.h = rows;
    this.w = cols;
    this.border = border;
    this.stride = cols + 2 * border;
    this.data = new Uint8Array(this.stride * (rows + 2 * border));
    return this;
  }

  // Index into data of column 0 of row y (y measured from the bottom).
  rowOffset(y) { return (y + this.border) * this.stride + this.border; }

  get(x, y) { return this.data[this.rowOffset(y) + x]; }
  set(x, y, v) { this.data[this.rowOffset(y) + x] = v; }

  // Ensure the border is at least n pixels on every side (grows if needed).
  minborder(n) {
    if (this.border >= n) return;
    const nstride = this.w + 2 * n;
    const ndata = new Uint8Array(nstride * (this.h + 2 * n));
    for (let y = 0; y < this.h; y++) {
      const src = this.rowOffset(y);
      const dst = (y + n) * nstride + n;
      for (let x = 0; x < this.w; x++) ndata[dst + x] = this.data[src + x];
    }
    this.border = n;
    this.stride = nstride;
    this.data = ndata;
  }
}

class JB2Decoder {
  constructor(zp, inheritedDict = null) {
    this.zp = zp;
    this.inheritedDict = inheritedDict;
    // Inherited shapes are used only if the stream codes an inherited-shape
    // count (REQUIRED_DICT_OR_RESET); a dictionary passed in is otherwise
    // ignored — matching the reference decoders. Set in codeInheritedShapeCount.
    this.inheritedShapes = 0;

    // Number-coder decision-tree cells (node 0 is a dummy)
    const cap = CELLCHUNK + CELLEXTRA;
    this.bitcells = new Uint8Array(cap);
    this.leftcell = new Int32Array(cap);
    this.rightcell = new Int32Array(cap);
    this.cellCap = cap;
    this.curNcell = 1;

    // Named numeric contexts (each holds a tree-node index)
    this.dist_comment_byte = new Int32Array(1);
    this.dist_comment_length = new Int32Array(1);
    this.dist_record_type = new Int32Array(1);
    this.dist_match_index = new Int32Array(1);
    this.abs_loc_x = new Int32Array(1);
    this.abs_loc_y = new Int32Array(1);
    this.abs_size_x = new Int32Array(1);
    this.abs_size_y = new Int32Array(1);
    this.image_size_dist = new Int32Array(1);
    this.inherited_shape_count_dist = new Int32Array(1);
    this.rel_loc_x_current = new Int32Array(1);
    this.rel_loc_x_last = new Int32Array(1);
    this.rel_loc_y_current = new Int32Array(1);
    this.rel_loc_y_last = new Int32Array(1);
    this.rel_size_x = new Int32Array(1);
    this.rel_size_y = new Int32Array(1);

    // Single-bit contexts
    this.dist_refinement_flag = new Uint8Array(1);
    this.offset_type_dist = new Uint8Array(1);

    // Bitmap pixel contexts
    this.bitdist = new Uint8Array(1024);
    this.cbitdist = new Uint8Array(2048);

    // Shapes / blits / library
    this.shapes = [];   // decoded shapes (not counting inherited): {bits, parent}
    this.blits = [];    // {left, bottom, shapeno}
    this.lib2shape = [];
    this.shape2lib = [];
    this.libinfo = [];  // {left, top, right, bottom}

    // Location state
    this.last_left = 0;
    this.last_row_left = 0;
    this.last_row_bottom = 0;
    this.last_right = 0;
    this.last_bottom = 0;
    this.short_list = [0, 0, 0];
    this.short_list_pos = 0;
    this.gotstartrecordp = 0;

    this.image_columns = 0;
    this.image_rows = 0;
    this.refinementp = false;
    this.comment = '';
  }

  get shapeCount() { return this.inheritedShapes + this.shapes.length; }

  getShape(i) {
    return i < this.inheritedShapes ? this.inheritedDict.getShape(i) : this.shapes[i - this.inheritedShapes];
  }

  addShape(shape) {
    this.shapes.push(shape);
    return this.inheritedShapes + this.shapes.length - 1;
  }

  // ---- number coding -------------------------------------------------------

  growCells() {
    const n = this.cellCap + CELLCHUNK;
    const b = new Uint8Array(n); b.set(this.bitcells); this.bitcells = b;
    const l = new Int32Array(n); l.set(this.leftcell); this.leftcell = l;
    const r = new Int32Array(n); r.set(this.rightcell); this.rightcell = r;
    this.cellCap = n;
  }

  // Decode a number in [low, high] using the decision tree rooted at the given
  // named context slot. curKind: 2=named, 0=leftcell, 1=rightcell.
  codeNum(low, high, namedSlot) {
    let cutoff = 0;
    let negative = false;
    let curKind = 2;
    let curIdx = 0;
    let phase = 1;
    let range = -1; // 0xffffffff
    while (range !== 1) {
      let node = curKind === 0 ? this.leftcell[curIdx] : curKind === 1 ? this.rightcell[curIdx] : namedSlot[0];
      if (!node) {
        if (this.curNcell >= this.cellCap) this.growCells();
        node = this.curNcell++;
        this.bitcells[node] = 0;
        this.leftcell[node] = 0;
        this.rightcell[node] = 0;
        if (curKind === 0) this.leftcell[curIdx] = node;
        else if (curKind === 1) this.rightcell[curIdx] = node;
        else namedSlot[0] = node;
      }
      let decision;
      if (low >= cutoff) decision = true;
      else if (high >= cutoff) decision = this.zp.decode(this.bitcells, node) !== 0;
      else decision = false;
      curKind = decision ? 1 : 0;
      curIdx = node;
      switch (phase) {
        case 1:
          negative = !decision;
          if (negative) { const t = -low - 1; low = -high - 1; high = t; }
          phase = 2; cutoff = 1;
          break;
        case 2:
          if (!decision) {
            phase = 3;
            range = (cutoff + 1) >> 1;
            if (range === 1) cutoff = 0;
            else cutoff -= range >> 1;
          } else {
            cutoff += cutoff + 1;
          }
          break;
        case 3:
          range >>= 1;
          if (range !== 1) {
            if (!decision) cutoff -= range >> 1;
            else cutoff += range >> 1;
          } else if (!decision) {
            cutoff--;
          }
          break;
      }
    }
    return negative ? -cutoff - 1 : cutoff;
  }

  getDiff(slot) { return this.codeNum(BIGNEGATIVE, BIGPOSITIVE, slot); }

  resetNumcoder() {
    for (const s of [this.dist_comment_byte, this.dist_comment_length, this.dist_record_type,
      this.dist_match_index, this.abs_loc_x, this.abs_loc_y, this.abs_size_x, this.abs_size_y,
      this.image_size_dist, this.inherited_shape_count_dist, this.rel_loc_x_current,
      this.rel_loc_x_last, this.rel_loc_y_current, this.rel_loc_y_last, this.rel_size_x, this.rel_size_y]) {
      s[0] = 0;
    }
    this.curNcell = 1;
  }

  // ---- short list (median tracker for vertical position) -------------------

  fillShortList(v) { this.short_list[0] = this.short_list[1] = this.short_list[2] = v; this.short_list_pos = 0; }

  updateShortList(v) {
    if (++this.short_list_pos === 3) this.short_list_pos = 0;
    const s = this.short_list;
    s[this.short_list_pos] = v;
    return (s[0] >= s[1])
      ? ((s[0] > s[2]) ? ((s[1] >= s[2]) ? s[1] : s[2]) : s[0])
      : ((s[0] < s[2]) ? ((s[1] >= s[2]) ? s[2] : s[1]) : s[0]);
  }

  // ---- library -------------------------------------------------------------

  initLibrary() {
    const n = this.inheritedShapes;
    for (let i = 0; i < n; i++) {
      this.shape2lib[i] = i;
      this.lib2shape[i] = i;
      this.libinfo[i] = this.inheritedDict.boundingBox(i);
    }
  }

  addLibrary(shapeno, shape) {
    const libno = this.lib2shape.length;
    this.lib2shape[libno] = shapeno;
    this.shape2lib[shapeno] = libno;
    this.libinfo[libno] = computeBoundingBox(shape.bits);
    return libno;
  }

  boundingBox(shapeno) { return computeBoundingBox(this.getShape(shapeno).bits); }

  // ---- value coding --------------------------------------------------------

  codeRecordType() { return this.codeNum(START_OF_DATA, END_OF_DATA, this.dist_record_type); }

  codeMatchIndex() {
    return this.codeNum(0, this.lib2shape.length - 1, this.dist_match_index);
  }

  codeImageSizeImage() {
    this.image_columns = this.codeNum(0, BIGPOSITIVE, this.image_size_dist);
    this.image_rows = this.codeNum(0, BIGPOSITIVE, this.image_size_dist);
    if (!this.image_columns || !this.image_rows) throw new Error('JB2: zero image dimension');
    this.last_left = 1 + this.image_columns;
    this.last_row_left = 0;
    this.last_row_bottom = this.image_rows;
    this.last_right = 0;
    this.fillShortList(this.last_row_bottom);
    this.gotstartrecordp = 1;
  }

  codeImageSizeDict() {
    const w = this.codeNum(0, BIGPOSITIVE, this.image_size_dist);
    const h = this.codeNum(0, BIGPOSITIVE, this.image_size_dist);
    if (w || h) throw new Error('JB2: bad dict image size');
    this.last_left = 1;
    this.last_row_left = 0;
    this.last_row_bottom = 0;
    this.last_right = 0;
    this.fillShortList(0);
    this.gotstartrecordp = 1;
  }

  codeEventualLosslessRefinement() {
    this.refinementp = this.zp.decode(this.dist_refinement_flag, 0) !== 0;
  }

  codeInheritedShapeCount() {
    const size = this.codeNum(0, BIGPOSITIVE, this.inherited_shape_count_dist);
    if (size > 0 && !this.inheritedDict) throw new Error('JB2: inherited dictionary required');
    if (size > 0 && this.inheritedDict && size !== this.inheritedDict.shapeCount) {
      throw new Error('JB2: bad inherited dictionary');
    }
    this.inheritedShapes = size;
  }

  codeComment() {
    const size = this.codeNum(0, BIGPOSITIVE, this.dist_comment_length);
    const buf = new Uint8Array(size);
    for (let i = 0; i < size; i++) buf[i] = this.codeNum(0, 255, this.dist_comment_byte);
    this.comment = utf8.decode(buf);
  }

  codeAbsoluteMarkSize(bm, border) {
    const xsize = this.codeNum(0, BIGPOSITIVE, this.abs_size_x);
    const ysize = this.codeNum(0, BIGPOSITIVE, this.abs_size_y);
    if (xsize !== (xsize & 0xffff) || ysize !== (ysize & 0xffff)) throw new Error('JB2: bad mark size');
    bm.init(ysize, xsize, border);
  }

  codeRelativeMarkSize(bm, cw, ch, border) {
    const xdiff = this.codeNum(BIGNEGATIVE, BIGPOSITIVE, this.rel_size_x);
    const ydiff = this.codeNum(BIGNEGATIVE, BIGPOSITIVE, this.rel_size_y);
    const xsize = cw + xdiff;
    const ysize = ch + ydiff;
    if (xsize !== (xsize & 0xffff) || ysize !== (ysize & 0xffff)) throw new Error('JB2: bad relative mark size');
    bm.init(ysize, xsize, border);
  }

  codeAbsoluteLocation(jblt, rows, columns) {
    if (!this.gotstartrecordp) throw new Error('JB2: no start record');
    const left = this.codeNum(1, this.image_columns, this.abs_loc_x);
    const top = this.codeNum(1, this.image_rows, this.abs_loc_y);
    jblt.bottom = top - rows + 1 - 1;
    jblt.left = left - 1;
  }

  codeRelativeLocation(jblt, rows, columns) {
    if (!this.gotstartrecordp) throw new Error('JB2: no start record');
    let bottom, left, top, right;
    const newRow = this.zp.decode(this.offset_type_dist, 0);
    if (newRow) {
      const xDiff = this.getDiff(this.rel_loc_x_last);
      const yDiff = this.getDiff(this.rel_loc_y_last);
      left = this.last_row_left + xDiff;
      top = this.last_row_bottom + yDiff;
      right = left + columns - 1;
      bottom = top - rows + 1;
      this.last_left = this.last_row_left = left;
      this.last_right = right;
      this.last_bottom = this.last_row_bottom = bottom;
      this.fillShortList(bottom);
    } else {
      const xDiff = this.getDiff(this.rel_loc_x_current);
      const yDiff = this.getDiff(this.rel_loc_y_current);
      left = this.last_right + xDiff;
      bottom = this.last_bottom + yDiff;
      right = left + columns - 1;
      top = bottom + rows - 1;
      this.last_left = left;
      this.last_right = right;
      this.last_bottom = this.updateShortList(bottom);
    }
    jblt.bottom = bottom - 1;
    jblt.left = left - 1;
  }

  // ---- bitmap coding -------------------------------------------------------

  codeBitmapDirectly(bm) {
    bm.minborder(3);
    const data = bm.data;
    const w = bm.w;
    const bitdist = this.bitdist;
    const zp = this.zp;
    for (let dy = bm.h - 1; dy >= 0; dy--) {
      const up0 = bm.rowOffset(dy);
      const up1 = bm.rowOffset(dy + 1);
      const up2 = bm.rowOffset(dy + 2);
      for (let dx = 0; dx < w; dx++) {
        const context =
          (data[up2 + dx - 1] << 9) | (data[up2 + dx] << 8) | (data[up2 + dx + 1] << 7) |
          (data[up1 + dx - 2] << 6) | (data[up1 + dx - 1] << 5) | (data[up1 + dx] << 4) |
          (data[up1 + dx + 1] << 3) | (data[up1 + dx + 2] << 2) |
          (data[up0 + dx - 2] << 1) | (data[up0 + dx - 1]);
        data[up0 + dx] = zp.decode(bitdist, context);
      }
    }
  }

  codeBitmapByCrossCoding(bm, cbm, libno) {
    const cw = cbm.w;
    const dw = bm.w;
    const dh = bm.h;
    const ch = cbm.h;
    const l = this.libinfo[libno];
    const xd2c = ((dw >> 1) - dw + 1) - (((l.right - l.left + 1) >> 1) - l.right);
    const yd2c = ((dh >> 1) - dh + 1) - (((l.top - l.bottom + 1) >> 1) - l.top);
    if (xd2c < -15 || xd2c > 15 || yd2c < -15 || yd2c > 15) throw new Error('JB2: bad cross-coding offset');
    bm.minborder(2);
    // Enough border on the reference to cover the centred read window.
    const need = Math.max(1 - xd2c, xd2c + dw + 1 - cw, 1 - yd2c, dh + yd2c + 1 - ch, 2);
    cbm.minborder(need);

    const bd = bm.data;
    const cd = cbm.data;
    const cbitdist = this.cbitdist;
    const zp = this.zp;
    let dy = dh - 1;
    let cy = dy + yd2c;
    while (dy >= 0) {
      const up1 = bm.rowOffset(dy + 1);
      const up0 = bm.rowOffset(dy);
      const xup1 = cbm.rowOffset(cy + 1) + xd2c;
      const xup0 = cbm.rowOffset(cy) + xd2c;
      const xdn1 = cbm.rowOffset(cy - 1) + xd2c;
      for (let dx = 0; dx < dw; dx++) {
        const context =
          (bd[up1 + dx - 1] << 10) | (bd[up1 + dx] << 9) | (bd[up1 + dx + 1] << 8) |
          (bd[up0 + dx - 1] << 7) |
          (cd[xup1 + dx] << 6) |
          (cd[xup0 + dx - 1] << 5) | (cd[xup0 + dx] << 4) | (cd[xup0 + dx + 1] << 3) |
          (cd[xdn1 + dx - 1] << 2) | (cd[xdn1 + dx] << 1) | (cd[xdn1 + dx + 1]);
        bd[up0 + dx] = zp.decode(cbitdist, context);
      }
      dy--; cy--;
    }
  }

  // ---- record loop ---------------------------------------------------------

  decodeImage() {
    let rectype;
    do { rectype = this.codeRecordImage(); } while (rectype !== END_OF_DATA);
    if (!this.gotstartrecordp) throw new Error('JB2: no start record');
  }

  decodeDict() {
    let rectype;
    do { rectype = this.codeRecordDict(); } while (rectype !== END_OF_DATA);
    if (!this.gotstartrecordp) throw new Error('JB2: no start record');
  }

  codeRecordImage() {
    const rectype = this.codeRecordType();
    let bm = null;
    let cbm = null;
    let shape = null;
    let match;
    const jblt = { left: 0, bottom: 0, shapeno: 0 };

    // Pre-coding: allocate a shape for shape-bearing records
    switch (rectype) {
      case NEW_MARK: case NEW_MARK_LIBRARY_ONLY: case NEW_MARK_IMAGE_ONLY:
      case MATCHED_REFINE: case MATCHED_REFINE_LIBRARY_ONLY: case MATCHED_REFINE_IMAGE_ONLY:
      case NON_MARK_DATA:
        shape = { bits: new Bitmap(), parent: rectype === NON_MARK_DATA ? -2 : -1 };
        bm = shape.bits;
        break;
    }

    switch (rectype) {
      case START_OF_DATA:
        this.codeImageSizeImage();
        this.codeEventualLosslessRefinement();
        this.initLibrary();
        break;
      case NEW_MARK:
        this.codeAbsoluteMarkSize(bm, 4);
        this.codeBitmapDirectly(bm);
        this.codeRelativeLocation(jblt, bm.h, bm.w);
        break;
      case NEW_MARK_LIBRARY_ONLY:
        this.codeAbsoluteMarkSize(bm, 4);
        this.codeBitmapDirectly(bm);
        break;
      case NEW_MARK_IMAGE_ONLY:
        this.codeAbsoluteMarkSize(bm, 3);
        this.codeBitmapDirectly(bm);
        this.codeRelativeLocation(jblt, bm.h, bm.w);
        break;
      case MATCHED_REFINE: {
        match = this.codeMatchIndex();
        const parent = this.lib2shape[match];
        shape.parent = parent;
        cbm = this.getShape(parent).bits;
        const l = this.libinfo[match];
        this.codeRelativeMarkSize(bm, l.right - l.left + 1, l.top - l.bottom + 1, 4);
        this.codeBitmapByCrossCoding(bm, cbm, match);
        this.codeRelativeLocation(jblt, bm.h, bm.w);
        break;
      }
      case MATCHED_REFINE_LIBRARY_ONLY: {
        match = this.codeMatchIndex();
        const parent = this.lib2shape[match];
        shape.parent = parent;
        cbm = this.getShape(parent).bits;
        const l = this.libinfo[match];
        this.codeRelativeMarkSize(bm, l.right - l.left + 1, l.top - l.bottom + 1, 4);
        break;
      }
      case MATCHED_REFINE_IMAGE_ONLY: {
        match = this.codeMatchIndex();
        const parent = this.lib2shape[match];
        shape.parent = parent;
        cbm = this.getShape(parent).bits;
        const l = this.libinfo[match];
        this.codeRelativeMarkSize(bm, l.right - l.left + 1, l.top - l.bottom + 1, 4);
        this.codeBitmapByCrossCoding(bm, cbm, match);
        this.codeRelativeLocation(jblt, bm.h, bm.w);
        break;
      }
      case MATCHED_COPY: {
        match = this.codeMatchIndex();
        jblt.shapeno = this.lib2shape[match];
        bm = this.getShape(jblt.shapeno).bits;
        const l = this.libinfo[match];
        jblt.left += l.left;
        jblt.bottom += l.bottom;
        this.codeRelativeLocation(jblt, l.top - l.bottom + 1, l.right - l.left + 1);
        jblt.left -= l.left;
        jblt.bottom -= l.bottom;
        break;
      }
      case NON_MARK_DATA:
        this.codeAbsoluteMarkSize(bm, 3);
        this.codeBitmapDirectly(bm);
        this.codeAbsoluteLocation(jblt, bm.h, bm.w);
        break;
      case PRESERVED_COMMENT:
        this.codeComment();
        break;
      case REQUIRED_DICT_OR_RESET:
        if (!this.gotstartrecordp) this.codeInheritedShapeCount();
        else this.resetNumcoder();
        break;
      case END_OF_DATA:
        break;
      default:
        throw new Error('JB2: unknown record type ' + rectype);
    }

    // Post-coding
    let shapeno = -1;
    switch (rectype) {
      case NEW_MARK: case NEW_MARK_LIBRARY_ONLY: case NEW_MARK_IMAGE_ONLY:
      case MATCHED_REFINE: case MATCHED_REFINE_LIBRARY_ONLY: case MATCHED_REFINE_IMAGE_ONLY:
      case NON_MARK_DATA:
        shapeno = this.addShape(shape);
        this.shape2lib[shapeno] = -1;
        break;
    }
    switch (rectype) {
      case NEW_MARK: case NEW_MARK_LIBRARY_ONLY: case MATCHED_REFINE: case MATCHED_REFINE_LIBRARY_ONLY:
        this.addLibrary(shapeno, shape);
        break;
    }
    switch (rectype) {
      case NEW_MARK: case NEW_MARK_IMAGE_ONLY: case MATCHED_REFINE: case MATCHED_REFINE_IMAGE_ONLY:
      case NON_MARK_DATA:
        jblt.shapeno = shapeno;
        this.blits.push({ left: jblt.left, bottom: jblt.bottom, shapeno: jblt.shapeno });
        break;
      case MATCHED_COPY:
        this.blits.push({ left: jblt.left, bottom: jblt.bottom, shapeno: jblt.shapeno });
        break;
    }
    return rectype;
  }

  codeRecordDict() {
    const rectype = this.codeRecordType();
    let bm = null;
    let shape = null;

    switch (rectype) {
      case NEW_MARK_LIBRARY_ONLY: case MATCHED_REFINE_LIBRARY_ONLY:
        shape = { bits: new Bitmap(), parent: -1 };
        bm = shape.bits;
        break;
    }

    switch (rectype) {
      case START_OF_DATA:
        this.codeImageSizeDict();
        this.codeEventualLosslessRefinement();
        this.initLibrary();
        break;
      case NEW_MARK_LIBRARY_ONLY:
        this.codeAbsoluteMarkSize(bm, 4);
        this.codeBitmapDirectly(bm);
        break;
      case MATCHED_REFINE_LIBRARY_ONLY: {
        const match = this.codeMatchIndex();
        const parent = this.lib2shape[match];
        shape.parent = parent;
        const cbm = this.getShape(parent).bits;
        const l = this.libinfo[match];
        this.codeRelativeMarkSize(bm, l.right - l.left + 1, l.top - l.bottom + 1, 4);
        this.codeBitmapByCrossCoding(bm, cbm, match);
        break;
      }
      case PRESERVED_COMMENT:
        this.codeComment();
        break;
      case REQUIRED_DICT_OR_RESET:
        if (!this.gotstartrecordp) this.codeInheritedShapeCount();
        else this.resetNumcoder();
        break;
      case END_OF_DATA:
        break;
      default:
        throw new Error('JB2(dict): unexpected record type ' + rectype);
    }

    switch (rectype) {
      case NEW_MARK_LIBRARY_ONLY: case MATCHED_REFINE_LIBRARY_ONLY: {
        const shapeno = this.addShape(shape);
        this.addLibrary(shapeno, shape);
        break;
      }
    }
    return rectype;
  }

  // ---- rendering -----------------------------------------------------------

  // Render all blits to a top-origin bilevel mask (1 = foreground ink).
  renderMask() {
    const W = this.image_columns;
    const H = this.image_rows;
    const mask = new Uint8Array(W * H);
    for (const blt of this.blits) {
      const bm = this.getShape(blt.shapeno).bits;
      const sw = bm.w;
      const sh = bm.h;
      const left = blt.left;
      const bottom = blt.bottom;
      for (let sy = 0; sy < sh; sy++) {
        const iy = bottom + sy;
        if (iy < 0 || iy >= H) continue;
        const moff = (H - 1 - iy) * W; // flip to top-origin
        const roff = bm.rowOffset(sy);
        for (let sx = 0; sx < sw; sx++) {
          if (bm.data[roff + sx]) {
            const ix = left + sx;
            if (ix >= 0 && ix < W) mask[moff + ix] = 1;
          }
        }
      }
    }
    return { width: W, height: H, mask };
  }
}

// Bounding box (inclusive indices of set pixels) of a shape bitmap.
function computeBoundingBox(bm) {
  const w = bm.w;
  const h = bm.h;
  let right, top, left, bottom;
  for (right = w - 1; right >= 0; right--) {
    let found = false;
    for (let y = 0; y < h; y++) if (bm.get(right, y)) { found = true; break; }
    if (found) break;
  }
  for (top = h - 1; top >= 0; top--) {
    let found = false;
    const off = bm.rowOffset(top);
    for (let x = 0; x < w; x++) if (bm.data[off + x]) { found = true; break; }
    if (found) break;
  }
  for (left = 0; left <= right; left++) {
    let found = false;
    for (let y = 0; y < h; y++) if (bm.get(left, y)) { found = true; break; }
    if (found) break;
  }
  for (bottom = 0; bottom <= top; bottom++) {
    let found = false;
    const off = bm.rowOffset(bottom);
    for (let x = 0; x < w; x++) if (bm.data[off + x]) { found = true; break; }
    if (found) break;
  }
  return { left, top, right, bottom };
}

/** Decode an Sjbz mask. Returns the JB2Decoder (use .renderMask()). */
export function decodeJB2Image(bytes, inheritedDict = null) {
  const dec = new JB2Decoder(new ZPDecoder(new ByteStream(bytes)), inheritedDict);
  dec.decodeImage();
  return dec;
}

/** Decode a Djbz shared shape dictionary. Returns the JB2Decoder. */
export function decodeJB2Dict(bytes, inheritedDict = null) {
  const dec = new JB2Decoder(new ZPDecoder(new ByteStream(bytes)), inheritedDict);
  dec.decodeDict();
  return dec;
}
