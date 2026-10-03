// BZZ decompressor — ZP-coded Burrows-Wheeler entropy coder used for DIRM
// component names, TXTz hidden text, and ANTz annotations. Implements the DjVu
// format's public BZZ algorithm, cross-referenced against the MIT-licensed
// DjvuNet (Compression/BSInputStream.cs).

import { ZPDecoder } from './zp.js';

const MAXBLOCK = 4096;
const FREQMAX = 4;
const CTXIDS = 3;

function decodeRaw(zp, bits) {
  let n = 1;
  const m = 1 << bits;
  while (n < m) n = (n << 1) | zp.decodePassThrough();
  return n - m;
}

// Mirrors C decode_binary(zp, ptr, bits): ctx=ptr-1; n=1; while(n<m) decoder(ctx[n]).
function decodeBinary(zp, ctx, ptr, bits) {
  let n = 1;
  const m = 1 << bits;
  const base = ptr - 1;
  while (n < m) { const b = zp.decode(ctx, base + n); n = (n << 1) | b; }
  return n - m;
}

// Decode one BZZ block; returns a Uint8Array of the reconstructed bytes, or
// null for the terminating empty block.
function decodeBlock(zp, ctx) {
  const size = decodeRaw(zp, 24);
  if (!size) return null;
  if (size > MAXBLOCK * 1024) throw new Error('BZZ: corrupt block size');

  const data = new Uint8Array(size);

  // Estimation speed
  let fshift = 0;
  if (zp.decodePassThrough()) { fshift += 1; if (zp.decodePassThrough()) fshift += 1; }

  // Quasi-MTF table
  const mtf = new Uint8Array(256);
  for (let i = 0; i < 256; i++) mtf[i] = i;
  const freq = new Uint32Array(FREQMAX);
  let fadd = 4;

  let mtfno = 3;
  let markerpos = -1;

  for (let i = 0; i < size; i++) {
    let ctxid = CTXIDS - 1;
    if (ctxid > mtfno) ctxid = mtfno;
    let cx = 0;
    let decoded = true;
    if (zp.decode(ctx, cx + ctxid)) { mtfno = 0; data[i] = mtf[0]; }
    else {
      cx += CTXIDS;
      if (zp.decode(ctx, cx + ctxid)) { mtfno = 1; data[i] = mtf[1]; }
      else {
        cx += CTXIDS;
        if (zp.decode(ctx, cx)) { mtfno = 2 + decodeBinary(zp, ctx, cx + 1, 1); data[i] = mtf[mtfno]; }
        else { cx += 1 + 1;
        if (zp.decode(ctx, cx)) { mtfno = 4 + decodeBinary(zp, ctx, cx + 1, 2); data[i] = mtf[mtfno]; }
        else { cx += 1 + 3;
        if (zp.decode(ctx, cx)) { mtfno = 8 + decodeBinary(zp, ctx, cx + 1, 3); data[i] = mtf[mtfno]; }
        else { cx += 1 + 7;
        if (zp.decode(ctx, cx)) { mtfno = 16 + decodeBinary(zp, ctx, cx + 1, 4); data[i] = mtf[mtfno]; }
        else { cx += 1 + 15;
        if (zp.decode(ctx, cx)) { mtfno = 32 + decodeBinary(zp, ctx, cx + 1, 5); data[i] = mtf[mtfno]; }
        else { cx += 1 + 31;
        if (zp.decode(ctx, cx)) { mtfno = 64 + decodeBinary(zp, ctx, cx + 1, 6); data[i] = mtf[mtfno]; }
        else { cx += 1 + 63;
        if (zp.decode(ctx, cx)) { mtfno = 128 + decodeBinary(zp, ctx, cx + 1, 7); data[i] = mtf[mtfno]; }
        else { mtfno = 256; data[i] = 0; markerpos = i; decoded = false; }
        }}}}}}
      }
    }
    if (!decoded) continue;

    // Rotate MTF according to empirical frequencies
    fadd = fadd + (fadd >> fshift);
    if (fadd > 0x10000000) {
      fadd >>= 24;
      freq[0] >>>= 24; freq[1] >>>= 24; freq[2] >>>= 24; freq[3] >>>= 24;
    }
    let fc = fadd >>> 0;
    if (mtfno < FREQMAX) fc = (fc + freq[mtfno]) >>> 0;
    let k = mtfno;
    for (; k >= FREQMAX; k--) mtf[k] = mtf[k - 1];
    for (; k > 0 && fc >= freq[k - 1]; k--) { mtf[k] = mtf[k - 1]; freq[k] = freq[k - 1]; }
    mtf[k] = data[i];
    freq[k] = fc;
  }

  // Reconstruct via inverse Burrows-Wheeler transform
  if (markerpos < 1 || markerpos >= size) throw new Error('BZZ: corrupt (markerpos)');
  const posn = new Uint32Array(size);
  const count = new Int32Array(256);
  for (let i = 0; i < markerpos; i++) {
    const c = data[i];
    posn[i] = ((c << 24) | (count[c] & 0xffffff)) >>> 0;
    count[c]++;
  }
  for (let i = markerpos + 1; i < size; i++) {
    const c = data[i];
    posn[i] = ((c << 24) | (count[c] & 0xffffff)) >>> 0;
    count[c]++;
  }
  let last = 1;
  for (let i = 0; i < 256; i++) { const tmp = count[i]; count[i] = last; last += tmp; }
  let i = 0;
  last = size - 1;
  while (last > 0) {
    const n = posn[i];
    const c = n >>> 24;
    data[--last] = c;
    i = count[c] + (n & 0xffffff);
  }
  if (i !== markerpos) throw new Error('BZZ: corrupt (reconstruction)');

  return data.subarray(0, size - 1); // last byte is the (consumed) marker slot
}

/** Decompress a whole BZZ stream into one Uint8Array. */
export function bzzDecompress(byteStream) {
  const zp = new ZPDecoder(byteStream);
  const ctx = new Uint8Array(300);
  const blocks = [];
  let total = 0;
  for (;;) {
    const block = decodeBlock(zp, ctx);
    if (!block) break;
    blocks.push(block);
    total += block.length;
  }
  const out = new Uint8Array(total);
  let o = 0;
  for (const b of blocks) { out.set(b, o); o += b.length; }
  return out;
}
