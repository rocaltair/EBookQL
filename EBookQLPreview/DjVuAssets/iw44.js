// IW44 decoder — the continuous-tone (color/photo) wavelet layer of DjVu
// (BG44 background, FG44 foreground). Implements the DjVu IW44 wavelet format,
// cross-referenced with the MIT-licensed DjvuNet (Wavelet/).
//
// IW44 stores an image as a progressively-refined set of wavelet coefficients,
// organised into 32x32 blocks of 64 buckets x 16 coefficients, scanned in a
// zig-zag order across 10 frequency "bands". Coefficients are coded bit-plane
// by bit-plane (slices) on the ZP coder. Multiple BG44 chunks add more slices
// to the same coefficient map (progressive quality). After all chunks, an
// inverse wavelet transform reconstructs Y/Cb/Cr planes, then YCbCr->RGB.

import { ByteStream } from './bytestream.js';
import { ZPDecoder } from './zp.js';

// Zig-zag coefficient location within a 1024-entry lift block: deinterleave the
// bits of n into (x, y) (MSB-first over 5 iterations), location = y*32 + x.
const zigzagloc = (() => {
  const z = new Int16Array(1024);
  for (let n = 0; n < 1024; n++) {
    let x = 0, y = 0, m = n;
    for (let i = 0; i < 5; i++) {
      x = (x << 1) | (m & 1); m >>= 1;
      y = (y << 1) | (m & 1); m >>= 1;
    }
    z[n] = y * 32 + x;
  }
  return z;
})();

const iw_quant = [
  0x004000,
  0x008000, 0x008000, 0x010000,
  0x010000, 0x010000, 0x020000,
  0x020000, 0x020000, 0x040000,
  0x040000, 0x040000, 0x080000,
  0x040000, 0x040000, 0x080000,
];
const iw_shift = 6;
const iw_round = 1 << (iw_shift - 1);

const bandbuckets = [
  { start: 0, size: 1 },
  { start: 1, size: 1 }, { start: 2, size: 1 }, { start: 3, size: 1 },
  { start: 4, size: 4 }, { start: 8, size: 4 }, { start: 12, size: 4 },
  { start: 16, size: 16 }, { start: 32, size: 16 }, { start: 48, size: 16 },
];

// coefficient states
const ZERO = 1, ACTIVE = 2, NEW = 4, UNK = 8;

// ---- block / map -----------------------------------------------------------

class Block {
  constructor() { this.buckets = new Array(64).fill(null); }
  data(n) { return this.buckets[n]; }
  dataAlloc(n) { return this.buckets[n] || (this.buckets[n] = new Int16Array(16)); }
  writeLiftblock(coeff, bmin = 0, bmax = 64) {
    coeff.fill(0);
    let n = bmin << 4;
    for (let n1 = bmin; n1 < bmax; n1++) {
      const d = this.buckets[n1];
      if (!d) { n += 16; } else {
        for (let n2 = 0; n2 < 16; n2++, n++) coeff[zigzagloc[n]] = d[n2];
      }
    }
  }
}

class Map {
  constructor(w, h) {
    this.iw = w;
    this.ih = h;
    this.bw = (w + 31) & ~31;
    this.bh = (h + 31) & ~31;
    this.nb = (this.bw * this.bh) / 1024;
    this.blocks = new Array(this.nb);
    for (let i = 0; i < this.nb; i++) this.blocks[i] = new Block();
  }

  // Reconstruct an Int8Array plane (signed samples, top-down row-major, iw*ih).
  imagePlane(fast = 0) {
    const { bw, bh, iw, ih } = this;
    const data16 = new Int16Array(bw * bh);
    const lift = new Int16Array(1024);
    let blockIdx = 0;
    for (let i = 0; i < bh; i += 32) {
      for (let j = 0; j < bw; j += 32) {
        this.blocks[blockIdx++].writeLiftblock(lift);
        for (let ii = 0; ii < 32; ii++) {
          const dst = (i + ii) * bw + j;
          const src = ii * 32;
          for (let jj = 0; jj < 32; jj++) data16[dst + jj] = lift[src + jj];
        }
      }
    }
    if (fast) {
      backward(data16, iw, ih, bw, 32, 2);
      for (let i = 0; i < bh; i += 2) {
        for (let j = 0; j < bw; j += 2) {
          const p = i * bw + j;
          data16[p + bw] = data16[p + bw + 1] = data16[p + 1] = data16[p];
        }
      }
    } else {
      backward(data16, iw, ih, bw, 32, 1);
    }
    const out = new Int8Array(iw * ih);
    for (let i = 0; i < ih; i++) {
      const prow = i * bw;
      const orow = i * iw;
      for (let j = 0; j < iw; j++) {
        let x = (data16[prow + j] + iw_round) >> iw_shift;
        if (x < -128) x = -128; else if (x > 127) x = 127;
        out[orow + j] = x;
      }
    }
    return out;
  }
}

// ---- inverse wavelet filters ----------------------------------------------

function filterBv(arr, p0, w, h0, rowsize, scale) {
  let y = 0;
  const s = scale * rowsize;
  const s3 = s + s + s;
  const h = (((h0 - 1) / scale) | 0) + 1;
  let p = p0;
  while (y - 3 < h) {
    // 1-Lifting (predict)
    {
      let q = p;
      const e = q + w;
      if (y >= 3 && y + 3 < h) {
        while (q < e) {
          const a = arr[q - s] + arr[q + s];
          const b = arr[q - s3] + arr[q + s3];
          arr[q] -= ((a * 9 - b + 16) >> 5);
          q += scale;
        }
      } else if (y < h) {
        let q1 = (y + 1 < h) ? q + s : -1;
        let q3 = (y + 3 < h) ? q + s3 : -1;
        if (y >= 3) {
          while (q < e) {
            const a = arr[q - s] + (q1 >= 0 ? arr[q1] : 0);
            const b = arr[q - s3] + (q3 >= 0 ? arr[q3] : 0);
            arr[q] -= ((a * 9 - b + 16) >> 5);
            q += scale; if (q1 >= 0) q1 += scale; if (q3 >= 0) q3 += scale;
          }
        } else if (y >= 1) {
          while (q < e) {
            const a = arr[q - s] + (q1 >= 0 ? arr[q1] : 0);
            const b = (q3 >= 0 ? arr[q3] : 0);
            arr[q] -= ((a * 9 - b + 16) >> 5);
            q += scale; if (q1 >= 0) q1 += scale; if (q3 >= 0) q3 += scale;
          }
        } else {
          while (q < e) {
            const a = (q1 >= 0 ? arr[q1] : 0);
            const b = (q3 >= 0 ? arr[q3] : 0);
            arr[q] -= ((a * 9 - b + 16) >> 5);
            q += scale; if (q1 >= 0) q1 += scale; if (q3 >= 0) q3 += scale;
          }
        }
      }
    }
    // 2-Interpolation (update)
    {
      let q = p - s3;
      const e = q + w;
      if (y >= 6 && y < h) {
        while (q < e) {
          const a = arr[q - s] + arr[q + s];
          const b = arr[q - s3] + arr[q + s3];
          arr[q] += ((a * 9 - b + 8) >> 4);
          q += scale;
        }
      } else if (y >= 3) {
        let q1 = (y - 2 < h) ? q + s : q - s;
        while (q < e) {
          const a = arr[q - s] + arr[q1];
          arr[q] += ((a + 1) >> 1);
          q += scale; q1 += scale;
        }
      }
    }
    y += 2;
    p += s + s;
  }
}

function filterBh(arr, p0, w, h, rowsize0, scale) {
  let y = 0;
  const s = scale;
  const s3 = s + s + s;
  const rowsize = rowsize0 * scale;
  let p = p0;
  while (y < h) {
    let q = p;
    const e = p + w;
    let a0 = 0, a1 = 0, a2 = 0, a3 = 0, b0 = 0, b1 = 0, b2 = 0, b3 = 0;
    if (q < e) { // x=0
      if (q + s < e) a2 = arr[q + s];
      if (q + s3 < e) a3 = arr[q + s3];
      b2 = b3 = arr[q] - (((a1 + a2) * 9 - a0 - a3 + 16) >> 5);
      arr[q] = b3;
      q += s + s;
    }
    if (q < e) { // x=2
      a0 = a1; a1 = a2; a2 = a3;
      if (q + s3 < e) a3 = arr[q + s3];
      b3 = arr[q] - (((a1 + a2) * 9 - a0 - a3 + 16) >> 5);
      arr[q] = b3;
      q += s + s;
    }
    if (q < e) { // x=4
      b1 = b2; b2 = b3; a0 = a1; a1 = a2; a2 = a3;
      if (q + s3 < e) a3 = arr[q + s3];
      b3 = arr[q] - (((a1 + a2) * 9 - a0 - a3 + 16) >> 5);
      arr[q] = b3;
      arr[q - s3] = arr[q - s3] + ((b1 + b2 + 1) >> 1);
      q += s + s;
    }
    while (q + s3 < e) { // generic
      a0 = a1; a1 = a2; a2 = a3; a3 = arr[q + s3];
      b0 = b1; b1 = b2; b2 = b3;
      b3 = arr[q] - (((a1 + a2) * 9 - a0 - a3 + 16) >> 5);
      arr[q] = b3;
      arr[q - s3] = arr[q - s3] + (((b1 + b2) * 9 - b0 - b3 + 8) >> 4);
      q += s + s;
    }
    while (q < e) { // w-3 <= x < w
      a0 = a1; a1 = a2; a2 = a3; a3 = 0;
      b0 = b1; b1 = b2; b2 = b3;
      b3 = arr[q] - (((a1 + a2) * 9 - a0 - a3 + 16) >> 5);
      arr[q] = b3;
      arr[q - s3] = arr[q - s3] + (((b1 + b2) * 9 - b0 - b3 + 8) >> 4);
      q += s + s;
    }
    while (q - s3 < e) { // w <= x < w+3
      b0 = b1; b1 = b2; b2 = b3;
      if (q - s3 >= p) arr[q - s3] = arr[q - s3] + ((b1 + b2 + 1) >> 1);
      q += s + s;
    }
    y += scale;
    p += rowsize;
  }
}

function backward(arr, w, h, rowsize, begin, end) {
  for (let scale = begin >> 1; scale >= end; scale >>= 1) {
    filterBv(arr, 0, w, h, rowsize, scale);
    filterBh(arr, 0, w, h, rowsize, scale);
  }
}

// ---- per-plane codec -------------------------------------------------------

class Codec {
  constructor(map) {
    this.map = map;
    this.curband = 0;
    this.curbit = 1;
    this.quant_hi = new Int32Array(10);
    this.quant_lo = new Int32Array(16);
    // quant_lo: 4x q[0], 4x q[1], 4x q[2], 4x q[3]
    let i = 0, qi = 0;
    for (; i < 4;) this.quant_lo[i++] = iw_quant[qi++];     // q[0..3] -> first 4
    for (let j = 0; j < 4; j++) this.quant_lo[i++] = iw_quant[qi];
    qi++;
    for (let j = 0; j < 4; j++) this.quant_lo[i++] = iw_quant[qi];
    qi++;
    for (let j = 0; j < 4; j++) this.quant_lo[i++] = iw_quant[qi];
    qi++;
    this.quant_hi[0] = 0;
    for (let j = 1; j < 10; j++) this.quant_hi[j] = iw_quant[qi++];
    // contexts
    this.ctxStart = new Uint8Array(32);
    this.ctxBucket = [];
    for (let k = 0; k < 10; k++) this.ctxBucket.push(new Uint8Array(8));
    this.ctxMant = new Uint8Array(1);
    this.ctxRoot = new Uint8Array(1);
    // working state
    this.coeffstate = new Int8Array(256);
    this.bucketstate = new Int8Array(16);
  }

  isNullSlice(bit, band) {
    if (band === 0) {
      let isNull = 1;
      for (let i = 0; i < 16; i++) {
        const t = this.quant_lo[i];
        this.coeffstate[i] = ZERO;
        if (t > 0 && t < 0x8000) { this.coeffstate[i] = UNK; isNull = 0; }
      }
      return isNull;
    }
    const t = this.quant_hi[band];
    return (t > 0 && t < 0x8000) ? 0 : 1;
  }

  codeSlice(zp) {
    if (this.curbit < 0) return 0;
    if (!this.isNullSlice(this.curbit, this.curband)) {
      const fbucket = bandbuckets[this.curband].start;
      const nbucket = bandbuckets[this.curband].size;
      for (let blockno = 0; blockno < this.map.nb; blockno++) {
        this.decodeBuckets(zp, this.curbit, this.curband, this.map.blocks[blockno], fbucket, nbucket);
      }
    }
    return this.finishCodeSlice();
  }

  finishCodeSlice() {
    this.quant_hi[this.curband] >>= 1;
    if (this.curband === 0) for (let i = 0; i < 16; i++) this.quant_lo[i] >>= 1;
    if (++this.curband >= bandbuckets.length) {
      this.curband = 0;
      this.curbit += 1;
      if (this.quant_hi[bandbuckets.length - 1] === 0) { this.curbit = -1; return 0; }
    }
    return 1;
  }

  decodePrepare(fbucket, nbucket, blk) {
    let bbstate = 0;
    const cs = this.coeffstate;
    if (fbucket) {
      for (let buckno = 0; buckno < nbucket; buckno++) {
        const cbase = buckno * 16;
        let bstatetmp = 0;
        const pcoeff = blk.data(fbucket + buckno);
        if (!pcoeff) {
          bstatetmp = UNK;
        } else {
          for (let i = 0; i < 16; i++) {
            let cstatetmp = UNK;
            if (pcoeff[i]) cstatetmp = ACTIVE;
            cs[cbase + i] = cstatetmp;
            bstatetmp |= cstatetmp;
          }
        }
        this.bucketstate[buckno] = bstatetmp;
        bbstate |= bstatetmp;
      }
    } else {
      const pcoeff = blk.data(0);
      if (!pcoeff) {
        bbstate = UNK;
      } else {
        for (let i = 0; i < 16; i++) {
          let cstatetmp = cs[i];
          if (cstatetmp !== ZERO) {
            cstatetmp = UNK;
            if (pcoeff[i]) cstatetmp = ACTIVE;
          }
          cs[i] = cstatetmp;
          bbstate |= cstatetmp;
        }
      }
      this.bucketstate[0] = bbstate;
    }
    return bbstate;
  }

  decodeBuckets(zp, bit, band, blk, fbucket, nbucket) {
    let bbstate = this.decodePrepare(fbucket, nbucket, blk);
    const cs = this.coeffstate;
    const bs = this.bucketstate;
    // root bit
    if ((nbucket < 16) || (bbstate & ACTIVE)) {
      bbstate |= NEW;
    } else if (bbstate & UNK) {
      if (zp.decode(this.ctxRoot, 0)) bbstate |= NEW;
    }
    // bucket bits
    if (bbstate & NEW) {
      for (let buckno = 0; buckno < nbucket; buckno++) {
        if (bs[buckno] & UNK) {
          let ctx = 0;
          if (band > 0) {
            const k = (fbucket + buckno) << 2;
            const b = blk.data(k >> 4);
            if (b) {
              const kk = k & 0xf;
              if (b[kk]) ctx += 1;
              if (b[kk + 1]) ctx += 1;
              if (b[kk + 2]) ctx += 1;
              if (ctx < 3 && b[kk + 3]) ctx += 1;
            }
          }
          if (bbstate & ACTIVE) ctx |= 4;
          if (zp.decode(this.ctxBucket[band], ctx)) bs[buckno] |= NEW;
        }
      }
    }
    // newly active coefficients (with sign)
    if (bbstate & NEW) {
      let thres = this.quant_hi[band];
      for (let buckno = 0; buckno < nbucket; buckno++) {
        const cbase = buckno * 16;
        if (bs[buckno] & NEW) {
          let pcoeff = blk.data(fbucket + buckno);
          if (!pcoeff) {
            pcoeff = blk.dataAlloc(fbucket + buckno);
            if (fbucket === 0) {
              for (let i = 0; i < 16; i++) if (cs[cbase + i] !== ZERO) cs[cbase + i] = UNK;
            } else {
              for (let i = 0; i < 16; i++) cs[cbase + i] = UNK;
            }
          }
          let gotcha = 0;
          const maxgotcha = 7;
          for (let i = 0; i < 16; i++) if (cs[cbase + i] & UNK) gotcha += 1;
          for (let i = 0; i < 16; i++) {
            if (cs[cbase + i] & UNK) {
              if (band === 0) thres = this.quant_lo[i];
              let ctx = (gotcha >= maxgotcha) ? maxgotcha : gotcha;
              if (bs[buckno] & ACTIVE) ctx |= 8;
              if (zp.decode(this.ctxStart, ctx)) {
                cs[cbase + i] |= NEW;
                const halfthres = thres >> 1;
                const coeff = thres + halfthres - (halfthres >> 2);
                pcoeff[i] = zp.IWdecoder() ? -coeff : coeff;
              }
              if (cs[cbase + i] & NEW) gotcha = 0;
              else if (gotcha > 0) gotcha -= 1;
            }
          }
        }
      }
    }
    // mantissa refinement of already-active coefficients
    if (bbstate & ACTIVE) {
      let thres = this.quant_hi[band];
      for (let buckno = 0; buckno < nbucket; buckno++) {
        const cbase = buckno * 16;
        if (bs[buckno] & ACTIVE) {
          const pcoeff = blk.data(fbucket + buckno);
          for (let i = 0; i < 16; i++) {
            if (cs[cbase + i] & ACTIVE) {
              let coeff = pcoeff[i];
              if (coeff < 0) coeff = -coeff;
              if (band === 0) thres = this.quant_lo[i];
              if (coeff <= 3 * thres) {
                coeff = coeff + (thres >> 2);
                if (zp.decode(this.ctxMant, 0)) coeff = coeff + (thres >> 1);
                else coeff = coeff - thres + (thres >> 1);
              } else {
                if (zp.IWdecoder()) coeff = coeff + (thres >> 1);
                else coeff = coeff - thres + (thres >> 1);
              }
              pcoeff[i] = pcoeff[i] > 0 ? coeff : -coeff;
            }
          }
        }
      }
    }
  }
}

// ---- IW44 image (accumulates chunks, produces a pixmap) --------------------

export class IW44Image {
  constructor() {
    this.ymap = null; this.cbmap = null; this.crmap = null;
    this.ycodec = null; this.cbcodec = null; this.crcodec = null;
    this.cslice = 0; this.cserial = 0;
    this.crcb_delay = 10; this.crcb_half = 0;
    this.width = 0; this.height = 0;
  }

  /** Decode one BG44/FG44 chunk payload (Uint8Array), refining the image. */
  decodeChunk(bytes) {
    this._pixmap = null; // a new chunk refines the image; drop the cached pixmap
    const bs = new ByteStream(bytes);
    const serial = bs.read8();
    const slices = bs.read8();
    if (serial !== this.cserial) throw new Error('IW44: wrong chunk serial');
    const nslices = this.cslice + slices;
    if (this.cserial === 0) {
      const major = bs.read8();
      const minor = bs.read8();
      const w = bs.read16();
      const h = bs.read16();
      let crcbdelay = 0;
      if ((major & 0x7f) === 1 && minor >= 2) crcbdelay = bs.read8();
      this.width = w; this.height = h;
      this.crcb_delay = 0; this.crcb_half = 0;
      if (minor >= 2) this.crcb_delay = crcbdelay & 0x7f;
      if (minor >= 2) this.crcb_half = (crcbdelay & 0x80) ? 0 : 1;
      if (major & 0x80) this.crcb_delay = -1;
      this.ymap = new Map(w, h);
      this.ycodec = new Codec(this.ymap);
      if (this.crcb_delay >= 0) {
        this.cbmap = new Map(w, h); this.crmap = new Map(w, h);
        this.cbcodec = new Codec(this.cbmap); this.crcodec = new Codec(this.crmap);
      }
    }
    const zp = new ZPDecoder(new ByteStream(bytes, bs.pos));
    let flag = 1;
    while (flag && this.cslice < nslices) {
      flag = this.ycodec.codeSlice(zp);
      if (this.crcodec && this.cbcodec && this.crcb_delay <= this.cslice) {
        flag |= this.cbcodec.codeSlice(zp);
        flag |= this.crcodec.codeSlice(zp);
      }
      this.cslice++;
    }
    this.cserial += 1;
    return nslices;
  }

  /** Reconstruct the image as RGBA (Uint8ClampedArray, length w*h*4). */
  getPixmap() {
    if (this._pixmap) return this._pixmap; // reconstruction is expensive; cache it
    if (!this.ymap) return null;
    const w = this.ymap.iw, h = this.ymap.ih;
    const Y = this.ymap.imagePlane(0);
    let Cb = null, Cr = null;
    if (this.crmap && this.cbmap && this.crcb_delay >= 0) {
      Cb = this.cbmap.imagePlane(this.crcb_half);
      Cr = this.crmap.imagePlane(this.crcb_half);
    }
    const rgba = new Uint8ClampedArray(w * h * 4);
    const n = w * h;
    for (let i = 0; i < n; i++) {
      const y = Y[i];
      let R, G, B;
      if (Cb) {
        const b = Cb[i], r = Cr[i];
        const t1 = b >> 2;
        const t2 = r + (r >> 1);
        const t3 = y + 128 - t1;
        R = y + 128 + t2;
        G = t3 - (t2 >> 1);
        B = t3 + (b << 1);
      } else {
        R = G = B = 127 - y;
      }
      const o = i * 4;
      rgba[o] = R; rgba[o + 1] = G; rgba[o + 2] = B; rgba[o + 3] = 255;
    }
    this._pixmap = { width: w, height: h, rgba };
    return this._pixmap;
  }
}

/** Decode a sequence of IW44 chunk payloads into one image. */
export function decodeIW44(chunks) {
  const img = new IW44Image();
  for (const c of chunks) img.decodeChunk(c);
  return img;
}
