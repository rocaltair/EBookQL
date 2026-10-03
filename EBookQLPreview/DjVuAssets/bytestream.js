// Minimal byte reader over a Uint8Array, with big- and little-endian helpers
// and zero-copy sub-streams. Used by the IFF parser and as the input to the
// ZP arithmetic decoder.

export class ByteStream {
  /**
   * @param {Uint8Array} bytes backing buffer
   * @param {number} start absolute offset that this stream treats as logical 0
   * @param {number} length logical length in bytes
   */
  constructor(bytes, start = 0, length = bytes.length - start) {
    this.bytes = bytes;
    this.start = start;
    this.length = length;
    this.pos = 0;
  }

  get size() { return this.length; }
  get remaining() { return this.length - this.pos; }
  eof() { return this.pos >= this.length; }

  /** Next byte, or -1 past end-of-stream (the ZP coder relies on this). */
  readByte() {
    return this.pos < this.length ? this.bytes[this.start + this.pos++] : -1;
  }

  read8() { return this.readByte(); }

  read16() { // big-endian
    const a = this.readByte(), b = this.readByte();
    return ((a << 8) | b) >>> 0;
  }

  read24() { // big-endian
    const a = this.readByte(), b = this.readByte(), c = this.readByte();
    return ((a << 16) | (b << 8) | c) >>> 0;
  }

  read32() { // big-endian, unsigned
    const a = this.readByte(), b = this.readByte(), c = this.readByte(), d = this.readByte();
    return ((a << 24) | (b << 16) | (c << 8) | d) >>> 0;
  }

  read16le() {
    const a = this.readByte(), b = this.readByte();
    return ((b << 8) | a) >>> 0;
  }

  /** Read n bytes as a Latin-1 string (used for 4CCs and ASCII ids). */
  readStringLatin1(n) {
    let s = '';
    for (let i = 0; i < n; i++) s += String.fromCharCode(this.readByte());
    return s;
  }

  /** Read a NUL-terminated Latin-1 string. */
  readCString() {
    let s = '';
    for (;;) {
      const b = this.readByte();
      if (b <= 0) break;
      s += String.fromCharCode(b);
    }
    return s;
  }

  /** Zero-copy view of n bytes at the current position; advances position. */
  readBytes(n) {
    const off = this.start + this.pos;
    this.pos += n;
    return this.bytes.subarray(off, off + n);
  }

  seek(p) { this.pos = p; }
  skip(n) { this.pos += n; }
}
