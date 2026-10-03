// Composite decoded page layers to RGBA at a chosen subsample (1 = full page
// resolution, 2 = half, ...). The foreground mask is anti-aliased by box-filter
// coverage so downscaled text stays crisp. No full-resolution intermediate.

/**
 * @param {object} layers from DjVuDoc.decodePageLayers
 * @param {number} subsample integer >=1; output is ceil(W/subsample) x ceil(H/subsample)
 */
export function renderPage(layers, subsample = 1) {
  const { info, jb2, mask, bg, fgbz, fgPixmap } = layers;
  const W = info.width;
  const H = info.height;
  const outW = Math.max(1, Math.ceil(W / subsample));
  const outH = Math.max(1, Math.ceil(H / subsample));
  const rgba = new Uint8ClampedArray(outW * outH * 4);

  // --- background (or white paper) ---
  if (bg) {
    const pm = bg.getPixmap();
    const sxb = pm.width / W;
    const syb = pm.height / H;
    for (let oy = 0; oy < outH; oy++) {
      const by = Math.min(pm.height - 1, ((oy * subsample) * syb) | 0);
      const brow = by * pm.width;
      let o = oy * outW * 4;
      for (let ox = 0; ox < outW; ox++) {
        const bx = Math.min(pm.width - 1, ((ox * subsample) * sxb) | 0);
        const bi = (brow + bx) * 4;
        rgba[o++] = pm.rgba[bi]; rgba[o++] = pm.rgba[bi + 1]; rgba[o++] = pm.rgba[bi + 2]; rgba[o++] = 255;
      }
    }
  } else {
    rgba.fill(255);
  }

  if (!jb2 && !mask) return { width: outW, height: outH, rgba };

  // --- foreground mask, with anti-aliased coverage ---
  const n = outW * outH;
  const cov = new Uint16Array(n);
  const rsum = new Uint32Array(n);
  const gsum = new Uint32Array(n);
  const bsum = new Uint32Array(n);
  const area = subsample * subsample;

  const palette = fgbz && fgbz.palette;
  const colordata = fgbz && fgbz.colordata;
  const fgpm = fgPixmap ? fgPixmap.getPixmap() : null;
  const fgsx = fgpm ? fgpm.width / W : 0;
  const fgsy = fgpm ? fgpm.height / H : 0;

  if (jb2) {
    // JB2: stamp each shape (bottom-origin blits) in its palette/FG44 colour.
    const blits = jb2.blits;
    for (let bi = 0; bi < blits.length; bi++) {
      const blt = blits[bi];
      let r = 0, g = 0, b = 0;
      let perPixel = false;
      if (palette && colordata && bi < colordata.length) {
        const c = palette[colordata[bi]];
        if (c) { r = c[0]; g = c[1]; b = c[2]; }
      } else if (fgpm) {
        perPixel = true;
      }
      const bm = jb2.getShape(blt.shapeno).bits;
      const sw = bm.w, sh = bm.h, left = blt.left, bottom = blt.bottom;
      for (let sy = 0; sy < sh; sy++) {
        const iy = bottom + sy;
        if (iy < 0 || iy >= H) continue;
        const fy = H - 1 - iy; // top-origin full-res row
        const oy = (fy / subsample) | 0;
        const roff = bm.rowOffset(sy);
        const orow = oy * outW;
        for (let sx = 0; sx < sw; sx++) {
          if (!bm.data[roff + sx]) continue;
          const ix = left + sx;
          if (ix < 0 || ix >= W) continue;
          if (perPixel) {
            const fx = Math.min(fgpm.width - 1, (ix * fgsx) | 0);
            const fyy = Math.min(fgpm.height - 1, (fy * fgsy) | 0);
            const fi = (fyy * fgpm.width + fx) * 4;
            r = fgpm.rgba[fi]; g = fgpm.rgba[fi + 1]; b = fgpm.rgba[fi + 2];
          }
          const idx = orow + ((ix / subsample) | 0);
          cov[idx]++; rsum[idx] += r; gsum[idx] += g; bsum[idx] += b;
        }
      }
    }
  } else if (mask) {
    // MMR: a full-page, top-origin ink mask. Colour from FG44 if present, else black.
    const md = mask.data, mw = mask.width, mh = mask.height;
    for (let y = 0; y < mh; y++) {
      const oy = (y / subsample) | 0;
      const orow = oy * outW;
      const mrow = y * mw;
      for (let x = 0; x < mw; x++) {
        if (!md[mrow + x]) continue;
        let r = 0, g = 0, b = 0;
        if (fgpm) {
          const fx = Math.min(fgpm.width - 1, (x * fgsx) | 0);
          const fyy = Math.min(fgpm.height - 1, (y * fgsy) | 0);
          const fi = (fyy * fgpm.width + fx) * 4;
          r = fgpm.rgba[fi]; g = fgpm.rgba[fi + 1]; b = fgpm.rgba[fi + 2];
        }
        const idx = orow + ((x / subsample) | 0);
        cov[idx]++; rsum[idx] += r; gsum[idx] += g; bsum[idx] += b;
      }
    }
  }

  for (let i = 0; i < n; i++) {
    const c = cov[i];
    if (!c) continue;
    const a = c / area; // coverage fraction in [0,1]
    const inv = 1 - a;
    const o = i * 4;
    rgba[o] = (rsum[i] / c) * a + rgba[o] * inv;
    rgba[o + 1] = (gsum[i] / c) * a + rgba[o + 1] * inv;
    rgba[o + 2] = (bsum[i] / c) * a + rgba[o + 2] * inv;
  }

  return { width: outW, height: outH, rgba };
}

/** Pick an integer subsample so the rendered page is about targetW px wide. */
export function subsampleForWidth(pageWidth, targetW) {
  return Math.max(1, Math.round(pageWidth / Math.max(1, targetW)));
}
