// MMR (CCITT Group 4 / T.6) bilevel decoder for the Smmr mask chunk — the
// fax-style alternative to JB2. Implements CCITT Group 4 (ITU-T T.6) 2D coding;
// DjvuNet has no MMR decoder, so this is grounded in the ITU-T T.6 standard.
// Produces a top-origin mask (1 = ink), the same orientation render.js expects.

import { ByteStream } from './bytestream.js';
import { MR_CODES, W_CODES, B_CODES } from './mmr_tables.js';

// 2D modes
const P = 0, H = 1, V0 = 2, VR1 = 3, VR2 = 4, VR3 = 5, VL1 = 6, VL2 = 7, VL3 = 8;

// Variable-length bit source: peek() exposes the next code bits in the high
// bits of a 32-bit word; shift(n) consumes n bits.
class VLSource {
  constructor(bs, striped) {
    this.bs = bs;
    this.codeword = 0;
    this.lowbits = 32;
    this.readmax = striped ? bs.read32() : -1;
    this.preload();
  }
  preload() {
    while (this.lowbits >= 8) {
      if (this.readmax === 0) break;
      const b = this.bs.readByte();
      if (b < 0) break;
      if (this.readmax > 0) this.readmax--;
      this.lowbits -= 8;
      this.codeword = (this.codeword | (b << this.lowbits)) >>> 0;
    }
  }
  peek() { return this.codeword >>> 0; }
  shift(n) {
    this.codeword = (this.codeword << n) >>> 0;
    this.lowbits += n;
    if (this.lowbits >= 16) this.preload();
  }
  nextstripe() {
    while (this.readmax > 0) { if (this.bs.readByte() < 0) break; this.readmax--; }
    this.readmax = this.bs.read32();
    this.codeword = 0;
    this.lowbits = 32;
    this.preload();
  }
}

// Prefix-lookup table over codes left-aligned in `nbits` bits.
class VLTable {
  constructor(codes, nbits) {
    this.codes = codes;
    this.shift = 32 - nbits;
    let ncodes = 0;
    while (codes[ncodes][1] !== 0) ncodes++;
    this.ncodes = ncodes;
    this.index = new Int32Array(1 << nbits).fill(ncodes);
    for (let i = 0; i < ncodes; i++) {
      const c = codes[i][0], b = codes[i][1];
      let n = c + (1 << (nbits - b));
      while (--n >= c) this.index[n] = i;
    }
  }
  decode(src) {
    const code = this.codes[this.index[src.peek() >>> this.shift]];
    src.shift(code[1]);
    return code[2];
  }
}

class MMRScanner {
  constructor(src, width, height, rowsperstrip) {
    this.src = src;
    this.width = width;
    this.height = height;
    this.rowsperstrip = rowsperstrip;
    this.lineno = 0;
    this.striplineno = 0;
    this.cur = new Int32Array(width + 8);
    this.prev = new Int32Array(width + 8);
    this.cur[0] = this.prev[0] = width;
    this.mr = new VLTable(MR_CODES, 7);
    this.wt = new VLTable(W_CODES, 13);
    this.bt = new VLTable(B_CODES, 13);
  }

  // Decode one scanline into `this.cur`; returns the number of runs, or -1 at end.
  scanruns() {
    const width = this.width;
    if (this.lineno >= this.height) return -1;
    if (this.striplineno === this.rowsperstrip) {
      this.striplineno = 0;
      this.cur[0] = this.prev[0] = width;
      this.src.nextstripe();
    }
    // swap run buffers (prev = the line we just produced)
    const prev = this.cur;
    const cur = this.prev;
    this.prev = prev;
    this.cur = cur;
    const src = this.src;

    let a0color = false, a0 = 0, rle = 0;
    let pri = 0, xri = 0;
    let b1 = prev[pri++];
    while (a0 < width) {
      const c = this.mr.decode(src);
      if (c === P) {
        b1 += prev[pri++];
        rle += b1 - a0;
        a0 = b1;
        b1 += prev[pri++];
      } else if (c === H) {
        const t1 = a0color ? this.bt : this.wt;
        let inc;
        do { inc = t1.decode(src); a0 += inc; rle += inc; } while (inc >= 64);
        cur[xri++] = rle; rle = 0;
        const t2 = a0color ? this.wt : this.bt;
        do { inc = t2.decode(src); a0 += inc; rle += inc; } while (inc >= 64);
        cur[xri++] = rle; rle = 0;
      } else if (c >= V0 && c <= VL3) {
        let inc;
        switch (c) {
          case V0: inc = b1; b1 += prev[pri++]; break;
          case VR3: inc = b1 + 3; b1 += prev[pri++]; break;
          case VR2: inc = b1 + 2; b1 += prev[pri++]; break;
          case VR1: inc = b1 + 1; b1 += prev[pri++]; break;
          case VL3: inc = b1 - 3; b1 -= prev[--pri]; break;
          case VL2: inc = b1 - 2; b1 -= prev[--pri]; break;
          case VL1: inc = b1 - 1; b1 -= prev[--pri]; break;
        }
        cur[xri++] = inc + rle - a0;
        a0 = inc;
        rle = 0;
        a0color = !a0color;
      } else {
        // EOFB (000000000001000000000001) -> rest of the image is blank
        src.preload();
        const m = src.peek();
        if ((m & 0xffffff00) === 0x00100100) { this.lineno = this.height; return -1; }
        throw new Error('MMR: unsupported code (uncompressed mode?)');
      }
      // advance b1 to the next changing element past a0 on the reference line
      for (; b1 <= a0 && b1 < width; pri += 2) b1 += prev[pri] + prev[pri + 1];
    }
    if (rle > 0 && this.mr.decode(src) !== V0) throw new Error('MMR: bad terminator');
    if (rle > 0) cur[xri++] = rle;
    if (a0 > width) { // tolerate slightly over-long lines
      while (a0 > width && xri > 0) a0 -= cur[--xri];
      if (a0 < width) cur[xri++] = width - a0;
    }
    cur[xri] = 0;
    cur[xri + 1] = 0;
    this.lineno++;
    this.striplineno++;
    return xri;
  }
}

/**
 * Decode an Smmr chunk to a bilevel mask.
 * @returns {{width:number, height:number, data:Uint8Array}} top-origin, 1=ink
 */
export function decodeMMR(bytes) {
  const bs = new ByteStream(bytes);
  const magic = bs.read32();
  if ((magic & 0xfffffffc) >>> 0 !== 0x4d4d5200) throw new Error('MMR: bad header');
  const invert = (magic & 1) ? 1 : 0;
  const striped = (magic & 2) ? 1 : 0;
  const width = bs.read16();
  const height = bs.read16();
  if (width <= 0 || height <= 0) throw new Error('MMR: bad dimensions');
  const rowsperstrip = striped ? bs.read16() : height;
  const src = new VLSource(bs, striped);
  const scan = new MMRScanner(src, width, height, rowsperstrip);

  const data = new Uint8Array(width * height);
  for (let row = 0; row < height; row++) {
    const nruns = scan.scanruns();
    if (nruns < 0) break; // EOFB: remaining rows stay 0
    const runs = scan.cur;
    let color = invert ? 1 : 0; // ink flag for the first (white) run
    let x = 0;
    for (let k = 0; k < nruns && x < width; k++) {
      const len = runs[k];
      if (color && len > 0) {
        const off = row * width + x;
        for (let j = 0; j < len && x + j < width; j++) data[off + j] = 1;
      }
      x += len;
      color ^= 1;
    }
  }
  return { width, height, data };
}
