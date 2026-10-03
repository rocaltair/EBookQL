// ZP coder — the adaptive binary arithmetic decoder (Bottou's ZP-coder) that
// underlies JB2, IW44 and BZZ. Implements the DjVu format's public ZP algorithm;
// the adaptation table is taken from the MIT-licensed DjvuNet (see src/zp_table.js)
// and the decode path was cross-referenced against DjvuNet's ZPCodec.cs (MIT).
//
// A "context" is a single byte (a state index 0..250). Because JS can't pass a
// reference to a number, contextual decoding takes (ctxArray, index): the byte
// at that index is read and adapted in place. Single contexts use a 1-element
// Uint8Array.

import { ZP_P, ZP_M, ZP_UP, ZP_DN } from './zp_table.js';

// ffzt[i] = number of leading 1-bits in the byte i (from bit 7 downward).
const ffzt = new Uint8Array(256);
for (let i = 0; i < 256; i++) {
  let n = 0;
  for (let j = i; j & 0x80; j = (j << 1) & 0xff) n++;
  ffzt[i] = n;
}

export class ZPDecoder {
  /** @param {import('./bytestream.js').ByteStream} stream */
  constructor(stream) {
    this.bs = stream;
    this.a = 0;
    this.code = 0;
    this.fence = 0;
    this.buffer = 0;   // unsigned 32-bit bit reservoir
    this.scount = 0;
    this.delay = 25;
    this.byte = 0;
    this._init();
  }

  _init() {
    this.a = 0;
    let b = this.bs.readByte();
    this.byte = b < 0 ? 0xff : b;
    this.code = this.byte << 8;
    b = this.bs.readByte();
    this.byte = b < 0 ? 0xff : b;
    this.code = this.code | this.byte;
    this.delay = 25;
    this.scount = 0;
    this.buffer = 0;
    this._preload();
    this.fence = this.code >= 0x8000 ? 0x7fff : this.code;
  }

  _preload() {
    while (this.scount <= 24) {
      let b = this.bs.readByte();
      if (b < 0) {
        b = 0xff;
        if (--this.delay < 1) throw new Error('ZP: unexpected end of data');
      }
      this.buffer = ((this.buffer << 8) | b) >>> 0;
      this.scount += 8;
    }
  }

  _ffz(x) {
    return x >= 0xff00 ? ffzt[x & 0xff] + 8 : ffzt[(x >> 8) & 0xff];
  }

  /** Adaptive decode using context byte ctx[i]; adapts that byte in place. */
  decode(ctx, i) {
    const state = ctx[i];
    const z = this.a + ZP_P[state];
    if (z <= this.fence) { this.a = z; return state & 1; }
    return this._decodeSub(ctx, i, state, z);
  }

  _decodeSub(ctx, i, state, z) {
    const bit = state & 1;
    // ZPCODER: avoid interval reversion
    const d = 0x6000 + ((z + this.a) >> 2);
    if (z > d) z = d;
    if (z > this.code) {
      // LPS branch
      z = 0x10000 - z;
      this.a += z;
      this.code += z;
      ctx[i] = ZP_DN[state];
      const shift = this._ffz(this.a);
      this.scount -= shift;
      this.a = (this.a << shift) & 0xffff;
      this.code = (((this.code << shift) & 0xffff) | ((this.buffer >>> this.scount) & ((1 << shift) - 1))) >>> 0;
      if (this.scount < 16) this._preload();
      this.fence = this.code >= 0x8000 ? 0x7fff : this.code;
      return bit ^ 1;
    }
    // MPS branch
    if (this.a >= ZP_M[state]) ctx[i] = ZP_UP[state];
    this.scount -= 1;
    this.a = (z << 1) & 0xffff;
    this.code = (((this.code << 1) & 0xffff) | ((this.buffer >>> this.scount) & 1)) >>> 0;
    if (this.scount < 16) this._preload();
    this.fence = this.code >= 0x8000 ? 0x7fff : this.code;
    return bit;
  }

  _decodeSubSimple(mps, z) {
    if (z > this.code) {
      // LPS
      z = 0x10000 - z;
      this.a += z;
      this.code += z;
      const shift = this._ffz(this.a);
      this.scount -= shift;
      this.a = (this.a << shift) & 0xffff;
      this.code = (((this.code << shift) & 0xffff) | ((this.buffer >>> this.scount) & ((1 << shift) - 1))) >>> 0;
      if (this.scount < 16) this._preload();
      this.fence = this.code >= 0x8000 ? 0x7fff : this.code;
      return mps ^ 1;
    }
    // MPS
    this.scount -= 1;
    this.a = (z << 1) & 0xffff;
    this.code = (((this.code << 1) & 0xffff) | ((this.buffer >>> this.scount) & 1)) >>> 0;
    if (this.scount < 16) this._preload();
    this.fence = this.code >= 0x8000 ? 0x7fff : this.code;
    return mps;
  }

  /** Pass-through (equiprobable, no context) decode. */
  decodePassThrough() {
    return this._decodeSubSimple(0, 0x8000 + (this.a >> 1));
  }

  /** IW44 equiprobable decode (different interval split). */
  IWdecoder() {
    return this._decodeSubSimple(0, 0x8000 + (((this.a + this.a + this.a)) >> 3));
  }
}
