//
//  djvu-viewer.js
//  EBookQLPreview (DjVuAssets)
//
//  The DjVu half of the reader page. A DjVu page is a scan, so the markup the backend
//  emits is an empty box of the right shape and this script fills it: it fetches the
//  page's bytes over `ekbres://djvu` and rasterises them in the page with the vendored
//  JavaScript decoder (`document.js`, `render.js` - see NOTICES.md).
//
//  Three things shape the code below:
//
//  * There is no worker. A `file://` page cannot start one (measured: SecurityError,
//    for a worker beside the page and for one on the custom scheme alike), so decoding
//    runs on the main thread. It is therefore done one page at a time, nearest-first,
//    with a yield between pages: ~50-120 ms for a 3492x5587 bilevel scan, and nothing
//    is decoded that the reader is not about to look at.
//  * Decoding is memory-heavy (a full-resolution page is ~78 MB of RGBA), so each page
//    is decoded at about twice its on-screen width and the canvases are trimmed to a
//    pixel budget as the reader scrolls away.
//  * The bytes come per page (`data-source="/page/12"`), so a 200-page book never has
//    more than one page's compressed bytes in memory. A document whose pages inherit a
//    shared dictionary has `data-source="/document"` for every page instead, and then
//    one document object is shared by all of them.
//

import { DjVuDoc } from './document.js';
import { renderPage } from './render.js';

(function () {
    var root = document.documentElement;
    if (root.getAttribute('data-format') !== 'djvu') { return; }

    var frames = Array.prototype.slice.call(
        document.querySelectorAll('.djvu-frame[data-source]'));
    if (!frames.length) { return; }

    /* Scheme + host the backend serves page bytes on. */
    var SCHEME = 'ekbres://djvu';

    /* Roughly 96 MB of canvas (4 bytes per pixel) at most, and never more than this
       many pages, however small they are. Both are generous for a Quick Look panel:
       the reader sees 2-3 pages at a time, and a page costs ~15 MB. */
    var PIXEL_BUDGET = 24e6;
    var MAX_KEPT = 10;

    /* How far outside the viewport a page is decoded before it is scrolled to. One
       viewport and a half each way keeps a fast flick ahead of the decoder. */
    var PREFETCH = '150% 0px 150% 0px';

    var documents = new Map();   // source path -> Promise (one buffer in flight/kept)
    var wanted = [];             // frames inside the prefetch window, nearest first
    var kept = [];               // decoded frames, oldest use first
    var running = false;

    /* ---------- zoom ---------- */

    /* The page box is sized in percent of the text column times this variable, so the
       reader's own A-/A+ scales the scan the way a viewer scales a page image - and a
       page decoded for a smaller box is re-decoded at the next size it is asked for. */
    setZoom((window.__ql && window.__ql.zoom) || 1);
    var innerSetZoom = window.ekbSetZoom;
    window.ekbSetZoom = function (factor) {
        if (typeof innerSetZoom === 'function') { innerSetZoom(factor); }
        setZoom(factor);
    };

    function setZoom(factor) {
        root.style.setProperty('--djvu-zoom', String(factor));
        for (var i = 0; i < frames.length; i++) {
            var entry = frames[i]._djvu;
            if (!entry || !entry.sub || entry.failed) { continue; }
            if (neededSubsample(frames[i], entry.pageWidth) < entry.sub) { release(frames[i]); }
        }
    }

    /* The integer subsample a page has to be decoded at to look sharp in this frame:
       one output pixel per device pixel, capped at 2x (a retina panel). */
    function neededSubsample(frame, pageWidth) {
        var ratio = Math.min(window.devicePixelRatio || 1, 2);
        var target = Math.max(320, frame.clientWidth * ratio);
        return Math.max(1, Math.round(pageWidth / target));
    }

    /* ---------- what to decode ---------- */

    var observer = new IntersectionObserver(function (entries) {
        for (var i = 0; i < entries.length; i++) {
            var frame = entries[i].target;
            var index = wanted.indexOf(frame);
            if (entries[i].isIntersecting) {
                if (index === -1) { wanted.push(frame); }
            } else if (index !== -1) {
                wanted.splice(index, 1);
            }
        }
        sortWanted();
        pump();
    }, { rootMargin: PREFETCH });

    for (var i = 0; i < frames.length; i++) { observer.observe(frames[i]); }
    window.addEventListener('scroll', sortWanted, { passive: true });

    /* Nearest to the reading line first, so a flick is followed in the order the reader
       is scrolling rather than in document order. */
    function sortWanted() {
        var line = window.innerHeight / 2;
        for (var i = 0; i < wanted.length; i++) {
            var frame = wanted[i];
            var box = frame.getBoundingClientRect();
            frame._distance = Math.abs(box.top + box.height / 2 - line);
        }
        wanted.sort(function (a, b) { return a._distance - b._distance; });
    }

    /* One page at a time, never re-entrant. */
    function pump() {
        if (running) { return; }
        var frame = nextFrame();
        if (!frame) { return; }
        running = true;
        decode(frame).catch(function (error) {
            fail(frame, error);
        }).then(function () {
            running = false;
            trim();
            setTimeout(pump, 0);
        });
    }

    function nextFrame() {
        for (var i = 0; i < wanted.length; i++) {
            var entry = wanted[i]._djvu;
            if (!entry) { return wanted[i]; }
            if (entry.failed) { continue; }
            if (!entry.canvas || entry.stale) { return wanted[i]; }
        }
        return null;
    }

    /* ---------- decoding ---------- */

    function decode(frame) {
        var index = Number(frame.getAttribute('data-page')) || 0;
        var source = frame.getAttribute('data-source');
        var local = source === '/document' ? index : 0;

        return documentFor(source).then(function (doc) {
            var layers = doc.decodePageLayers(local);
            return withNativeJpeg(layers).then(function (ready) {
                if (wanted.indexOf(frame) === -1) { return; }   // scrolled away
                var width = ready.info.width;
                var sub = width ? neededSubsample(frame, width) : 1;
                var composed = renderPage(ready, sub);
                paint(frame, composed, width, sub);
            });
        });
    }

    /* One buffer per source path. In page mode that is one page; in document mode the
       whole file is parsed once and shared, which is what the shared-dictionary case
       needs (`INCL` pages cannot be decoded on their own). */
    function documentFor(source) {
        var existing = documents.get(source);
        if (existing) { return existing; }
        var started = fetch(SCHEME + source).then(function (response) {
            if (!response.ok) { throw new Error('HTTP ' + response.status); }
            return response.arrayBuffer();
        }).then(function (buffer) {
            return new DjVuDoc(new Uint8Array(buffer));
        });
        documents.set(source, started);
        started.catch(function () { documents.delete(source); });
        return started;
    }

    /* `BGjp` / `FGjp` layers are plain JPEG, which this WebView decodes natively;
       `renderPage` only wants them in the shape the wavelet layers come in. */
    function withNativeJpeg(layers) {
        if (!layers.bgJpeg && !layers.fgJpeg) { return Promise.resolve(layers); }
        return Promise.all([
            layers.bgJpeg ? nativeJpeg(layers.bgJpeg) : Promise.resolve(null),
            layers.fgJpeg ? nativeJpeg(layers.fgJpeg) : Promise.resolve(null),
        ]).then(function (pixmaps) {
            if (pixmaps[0]) { layers.bg = { getPixmap: function () { return pixmaps[0]; } }; }
            if (pixmaps[1]) { layers.fgPixmap = { getPixmap: function () { return pixmaps[1]; } }; }
            return layers;
        });
    }

    function nativeJpeg(bytes) {
        var blob = new Blob([bytes], { type: 'image/jpeg' });
        return createImageBitmap(blob).then(function (bitmap) {
            var canvas = document.createElement('canvas');
            canvas.width = bitmap.width;
            canvas.height = bitmap.height;
            var context = canvas.getContext('2d');
            context.drawImage(bitmap, 0, 0);
            var image = context.getImageData(0, 0, bitmap.width, bitmap.height);
            if (bitmap.close) { bitmap.close(); }
            return { width: bitmap.width, height: bitmap.height, rgba: image.data };
        }).catch(function () { return null; });
    }

    function paint(frame, composed, pageWidth, sub) {
        var canvas = document.createElement('canvas');
        canvas.width = composed.width;
        canvas.height = composed.height;
        var context = canvas.getContext('2d');
        context.putImageData(
            new ImageData(composed.rgba, composed.width, composed.height), 0, 0);

        release(frame);
        frame.appendChild(canvas);
        frame.classList.add('djvu-ready');
        frame._djvu = {
            canvas: canvas, sub: sub, pageWidth: pageWidth, stale: false, failed: false,
            source: frame.getAttribute('data-source'),
            pixels: composed.width * composed.height,
        };
        kept.push(frame);
    }

    function fail(frame, error) {
        frame.classList.add('djvu-failed');
        frame._djvu = { failed: true };
        if (window.console) { console.warn('DjVu page could not be decoded', error); }
    }

    /* ---------- keeping memory bounded ---------- */

    /* Frees a frame's canvas (and its document, in page mode) but keeps the box: the
       height comes from `aspect-ratio`, so nothing moves and the page is decoded again
       the next time it is scrolled to. */
    function release(frame) {
        var entry = frame._djvu;
        if (!entry || !entry.canvas) { return; }
        var index = kept.indexOf(frame);
        if (index !== -1) { kept.splice(index, 1); }
        entry.canvas.width = 0;
        entry.canvas.height = 0;
        if (entry.canvas.parentNode) { entry.canvas.parentNode.removeChild(entry.canvas); }
        frame.classList.remove('djvu-ready');
        if (entry.source !== '/document') { documents.delete(entry.source); }
        frame._djvu = { stale: true };
    }

    function trim() {
        var pixels = 0;
        for (var i = 0; i < kept.length; i++) { pixels += kept[i]._djvu.pixels || 0; }
        /* Oldest use first: `kept` is in decode order, and `wanted` is what the reader
           can see, so anything in `kept` that is off screen goes before anything that
           is on it. */
        var order = kept.slice().sort(function (a, b) {
            return (wanted.indexOf(a) === -1 ? 0 : 1) - (wanted.indexOf(b) === -1 ? 0 : 1);
        });
        while (order.length && (kept.length > MAX_KEPT || pixels > PIXEL_BUDGET)) {
            var frame = order.shift();
            if (wanted.indexOf(frame) !== -1 && kept.length <= 2) { break; }
            pixels -= frame._djvu.pixels || 0;
            release(frame);
        }
    }
})();
