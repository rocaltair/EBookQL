//
//  ReaderAssets.swift
//  EBookQLKit
//
//  The one stylesheet and the one script every format's preview uses. They are
//  kept as Swift string literals rather than bundle resources on purpose: the kit
//  is a *static* library, which cannot carry resources, and both reference
//  projects embed their page assets the same way.
//

import Foundation

enum ReaderAssets {

    /// Class prefix used for everything the reader injects, so the book's own
    /// markup can never collide with the chrome.
    static let css = """
    :root {
        color-scheme: light dark;
        --toc-width: 25%;
        --page-bg: #f7f7f8;
        --text-color: #1c1c1e;
        --toc-bg: #ececef;
        --toc-border: rgba(0, 0, 0, .14);
        --hover-bg: rgba(0, 0, 0, .07);
        --current-bg: rgba(0, 0, 0, .13);
        --accent: #0a84ff;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --page-bg: #202022;
            --text-color: #e8e8ea;
            --toc-bg: #2b2b2e;
            --toc-border: rgba(255, 255, 255, .16);
            --hover-bg: rgba(255, 255, 255, .08);
            --current-bg: rgba(255, 255, 255, .16);
        }
    }
    html, body { margin: 0; background: var(--page-bg); color: var(--text-color); }
    body { font: -apple-system-body; line-height: 1.6; }
    /* Layout is what costs: a 402-chapter book is a 12 MB single page and a document
       millions of pixels tall, and WebKit laid the whole thing out before it could
       paint the first screen (measured: 8.75 s of an 11.4 s preview). Skipping the
       sections that are not on screen takes that off the critical path. `auto <length>`
       means the browser keeps the real height once a section has been rendered, so
       scrolling back through a section does not jump. */
    .chapter {
        margin: 0 0 48px 0;
        content-visibility: auto;
        contain-intrinsic-size: auto 3000px;
    }
    .anchor-target { display: block; height: 0; overflow: hidden; }

    #content { padding: 28px 32px 60vh 32px; }
    body:not(.no-toc) #content { margin-inline-start: var(--toc-width); }

    #toc {
        position: fixed; inset-block: 0; inset-inline-start: 0; z-index: 1;
        width: var(--toc-width); box-sizing: border-box;
        /* The heading (title + text-size buttons + hide) must not scroll away with the
           entries, so the column is a flex stack: #toc-head stays put and only
           #toc-scroll gives. */
        display: flex; flex-direction: column; overflow: hidden;
        /* em, not px: the sidebar's own size never changes, so its padding should not
           either - only the book's text is scaled (see ekbSetZoom). */
        padding: .96em .64em 1.92em .64em;
        /* Opaque on purpose: a translucent sidebar lets the text selection painted
           underneath tint the whole column. */
        background: var(--toc-bg);
        border-inline-end: 1px solid var(--toc-border);
        font-size: 12.5px; line-height: 1.45;
        -webkit-user-select: none; user-select: none;
    }
    #toc-head {
        flex: 0 0 auto;
        display: flex; align-items: center; justify-content: space-between; gap: .48em;
        font-weight: 600; font-size: .88em; letter-spacing: .08em; text-transform: uppercase;
        opacity: .55; padding: .32em .64em .64em .64em;
    }
    /* Only the entries scroll; the heading above never moves. */
    #toc-scroll { flex: 1 1 auto; min-height: 0; overflow-y: auto; }
    #toc-head > span:first-child { flex: 1 1 auto; }
    #toc-zoom { display: flex; align-items: center; gap: .24em; text-transform: none; letter-spacing: 0; }
    #toc-zoom button, #toc-fold-toggle, #toc-hide, #toc-show {
        font: inherit; font-size: .88em; cursor: pointer; border: 1px solid var(--toc-border);
        background: var(--toc-bg); color: inherit; border-radius: .48em;
        padding: .08em .4em; opacity: .75;
    }
    #toc-zoom button:hover, #toc-fold-toggle:hover, #toc-hide:hover, #toc-show:hover { opacity: 1; background: var(--hover-bg); }
    #toc-zoom #zoom-level { min-width: 2.88em; text-align: center; font-variant-numeric: tabular-nums; }
    /* One button, two states: ▸▸ folds everything, ▾▾ opens everything. Kept narrow so
       title + A−/100%/A+ + this + hide all fit beside the title. */
    #toc-fold-toggle { padding: .08em .3em; font-size: .8em; letter-spacing: -.06em; }
    #toc-show {
        position: fixed; z-index: 1; top: .8em; inset-inline-start: .8em; display: none;
        font-size: 12.5px;
    }
    body.toc-collapsed #toc { display: none; }
    body.toc-collapsed #content { margin-inline-start: 0; }
    body.toc-collapsed #toc-show { display: block; }
    body.toc-collapsed #toc-resizer { display: none; }

    /* The divider between contents and text. Invisible until it is pointed at; the hit
       area is wider than the line so it does not have to be aimed at precisely. */
    #toc-resizer {
        position: fixed; inset-block: 0; z-index: 3; cursor: col-resize;
        inset-inline-start: calc(var(--toc-width) - 4px); width: 9px;
        background: transparent; touch-action: none;
    }
    #toc-resizer::after {
        content: ""; position: absolute; inset-block: 0; inset-inline-start: 4px;
        width: 1px; background: transparent;
    }
    #toc-resizer:hover::after,
    body.toc-resizing #toc-resizer::after { background: var(--accent); opacity: .7; }
    body.toc-resizing { cursor: col-resize; }
    body.toc-resizing #content { -webkit-user-select: none; user-select: none; }

    .toc-list { list-style: none; margin: 0; padding: 0; }
    .toc-list .toc-list { padding-inline-start: .96em; }
    .toc-item { position: relative; }
    .toc-item > a, .toc-item > .toc-label {
        display: block; padding: .24em .64em; border-radius: .48em;
        text-decoration: none; color: inherit; opacity: .8;
    }
    .toc-item > a:hover { background: var(--hover-bg); opacity: 1; }
    .toc-item.current > a { background: var(--current-bg); opacity: 1; font-weight: 600; }
    .toc-item.has-children > a, .toc-item.has-children > .toc-label { padding-inline-start: 1.2em; }
    .toc-toggle {
        position: absolute; inset-inline-start: 0; top: .24em;
        width: 1.04em; height: 1.2em; padding: 0; border: 0; border-radius: .24em;
        background: transparent; color: inherit; cursor: pointer; opacity: .5;
        font: inherit; font-size: .72em; line-height: 1.2em;
    }
    .toc-toggle:hover { opacity: 1; background: var(--hover-bg); }
    .toc-toggle::before { content: "▾"; }
    .toc-item.collapsed > .toc-toggle::before { content: "▸"; }
    .toc-item.has-children > .toc-label { opacity: .55; font-weight: 600; }
    .toc-item.collapsed > .toc-list { display: none; }
    .toc-note {
        margin: .32em .64em .8em; padding: .4em .5em; border-radius: .32em; font-size: .88em;
        background: rgba(255, 149, 0, .16); color: rgb(160, 90, 0);
    }

    /* The reader's own scroll indicator: WebKit gives the panel fade-away overlay
       scrollbars, and styling ::-webkit-scrollbar does not take over the root
       scroller here. */
    #ekb-scrollbar {
        position: fixed; inset-block: 0; right: 0; width: 13px; z-index: 6;
        background: transparent; border-left: 1px solid var(--toc-border);
    }
    #ekb-scrollbar-thumb {
        position: absolute; left: 2px; right: 2px; border-radius: 5px;
        background: rgba(128, 128, 128, .55);
    }
    #ekb-scrollbar:hover #ekb-scrollbar-thumb { background: rgba(90, 90, 90, .85); }

    #ekb-resume {
        position: fixed; left: 27%; bottom: 16px; z-index: 5;
        display: flex; align-items: center; gap: 10px; padding: 7px 12px;
        border-radius: 999px; background: rgba(60, 60, 67, .88); color: #fff;
        box-shadow: 0 2px 12px rgba(0, 0, 0, .25);
        font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 12.5px;
        transition: opacity .45s ease;
    }
    #ekb-resume.ekb-gone { opacity: 0; }
    #ekb-resume a { color: #8ab4ff; text-decoration: none; }
    #ekb-resume a:hover { text-decoration: underline; }

    img, svg, video, iframe { max-width: 100%; height: auto; }
    h1, h2, h3, h4 { line-height: 1.25; }
    blockquote {
        border-inline-start: 3px solid var(--toc-border); padding-inline-start: 12px;
        margin-inline: 0; opacity: .85;
    }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    pre, table { max-width: 100%; overflow-x: auto; }
    """

    /// Injected into every page. Talks to the extension over three script messages.
    static let js = """
    (function () {
        var state = window.__ql || {};
        var saved = state.position || null;
        var content = document.getElementById('content');
        if (!content) { return; }
        var scroller = document.scrollingElement || document.documentElement;

        var positionBridge = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ekbPosition;
        var zoomBridge = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ekbZoom;
        var uiBridge = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ekbUI;

        function send(bridge, message) { if (bridge) { bridge.postMessage(message); } }

        /* Where the time goes: WebKit's own view of this document, reported back so
           the extension's log can tell "our render" apart from "the page came up". */
        if (uiBridge) {
            try {
                document.addEventListener('DOMContentLoaded', function () {
                    uiBridge.postMessage({ phase: 'dom', ms: Math.round(performance.now()) });
                });
                window.addEventListener('load', function () {
                    uiBridge.postMessage({ phase: 'load', ms: Math.round(performance.now()) });
                });
            } catch (error) {}
        }

        /* ---------- text size ---------- */

        /* Only the book's text scales. The sidebar, the divider and the panel are chrome -
           narrowing or widening them because the reader asked for bigger letters moves
           something the reader had already set up. */
        window.ekbSetZoom = function (factor) {
            dropLayout();
            var level = document.getElementById('zoom-level');
            if (level) { level.textContent = Math.round(factor * 100) + '%'; }
            if (content) { content.style.fontSize = (factor * 100) + '%'; }
        };
        /* Applied here rather than by the host afterwards, so the first paint is right. */
        window.ekbSetZoom(state.zoom || 1);

        /* A click steps one level; holding a button keeps stepping, because Quick
           Look opens the file in its default app on a double-click anywhere in the
           panel, so fast clicking is not an option. */
        [['zoom-out', -1], ['zoom-level', 0], ['zoom-in', 1]].forEach(function (pair) {
            var button = document.getElementById(pair[0]);
            if (!button) { return; }
            var startTimer = null, repeatTimer = null;
            function stop() {
                if (startTimer) { clearTimeout(startTimer); startTimer = null; }
                if (repeatTimer) { clearInterval(repeatTimer); repeatTimer = null; }
            }
            button.addEventListener('pointerdown', function (event) {
                event.preventDefault();
                send(zoomBridge, { step: pair[1] });
                if (pair[1] === 0) { return; }
                startTimer = setTimeout(function () {
                    repeatTimer = setInterval(function () {
                        send(zoomBridge, { step: pair[1] });
                    }, 250);
                }, 450);
            });
            ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (name) {
                button.addEventListener(name, stop);
            });
        });

        /* Cmd + wheel, anywhere in the panel. */
        window.addEventListener('wheel', function (event) {
            if (!event.metaKey) { return; }
            event.preventDefault();
            send(zoomBridge, { step: event.deltaY < 0 ? 1 : -1 });
        }, { passive: false });

        /* ---------- sidebar ---------- */

        /* The element a sidebar link points at, or null when there is none.
           Some books name anchors that were never created - Calibre's converter did it for
           all 265 entries of one book - so a link whose anchor is missing inside a chapter
           falls back to the chapter element itself (its landing place is then the top of
           that chapter rather than a heading within it). Shared with the highlight, which
           would otherwise find no targets at all in such a book and never light anything. */
        function targetOf(link) {
            var href = link.getAttribute('href') || '';
            if (href.charAt(0) !== '#') { return null; }
            var element = document.getElementById(href.slice(1));
            if (element) { return element; }
            var match = /^ch(\\d+)/.exec(href.slice(1));
            return match ? document.getElementById('ch' + match[1]) : null;
        }

        var toc = document.getElementById('toc');
        var tocScroll = document.getElementById('toc-scroll');
        var hideButton = document.getElementById('toc-hide');
        var showButton = document.getElementById('toc-show');
        if (hideButton) {
            hideButton.addEventListener('click', function () {
                document.body.classList.add('toc-collapsed');
                dropLayout(); refreshScrollbar();
            });
        }
        if (showButton) {
            showButton.addEventListener('click', function () {
                document.body.classList.remove('toc-collapsed');
                dropLayout(); refreshScrollbar();
            });
        }

        if (toc) {
            toc.querySelectorAll('li.has-children > .toc-toggle').forEach(function (button) {
                button.addEventListener('click', function (event) {
                    event.preventDefault();
                    event.stopPropagation();
                    button.parentElement.classList.toggle('collapsed');
                    dropLayout();
                });
            });
            /* One button, two states: fold everything / open everything. The decision
               reads the list's real state on each click rather than tracking a cached
               flag - the highlight already re-opens a branch as the book scrolls, so a
               cached flag would drift out of sync with what is on screen. */
            var foldToggle = document.getElementById('toc-fold-toggle');
            function anyExpanded() {
                var items = toc.querySelectorAll('li.has-children');
                for (var i = 0; i < items.length; i++) {
                    if (!items[i].classList.contains('collapsed')) { return true; }
                }
                return false;
            }
            function reflectFoldState() {
                if (!foldToggle) { return; }
                var expanded = anyExpanded();
                foldToggle.textContent = expanded ? '▸▸' : '▾▾';
                foldToggle.title = expanded ? 'Fold all' : 'Unfold all';
            }
            function setAllCollapsed(collapsed) {
                toc.querySelectorAll('li.has-children').forEach(function (item) {
                    item.classList.toggle('collapsed', collapsed);
                });
                reflectFoldState();
            }
            if (foldToggle) {
                foldToggle.addEventListener('click', function () { setAllCollapsed(anyExpanded()); });
            }
            toc.querySelectorAll('li.has-children > a').forEach(function (link) {
                link.addEventListener('click', function () {
                    link.parentElement.classList.remove('collapsed');
                });
            });
            /* Top level open, everything nested folded. */
            toc.querySelectorAll('li.has-children').forEach(function (item) {
                if (item.parentElement.closest('li')) { item.classList.add('collapsed'); }
            });
            reflectFoldState();
            /* Clicking an entry must not scroll the list itself: WebKit scrolls a
               focused link into view, which hides the rest of the contents. */
            toc.addEventListener('mousedown', function (event) {
                var node = event.target;
                while (node && node !== toc) {
                    if (node.tagName === 'A') { event.preventDefault(); return; }
                    node = node.parentNode;
                }
            }, true);
            /* A stale contents list can name anchors that are not in the text at all
               (measured on one book: 265 of 265 entries point at ids that do not exist),
               which would make every entry do nothing. The href carries the chapter
               index, so such a link lands at the top of its chapter instead - and if
               even that is missing, the click is left alone. */
            toc.addEventListener('click', function (event) {
                var node = event.target;
                while (node && node !== toc && node.tagName !== 'A') { node = node.parentNode; }
                if (!node || node.tagName !== 'A') { return; }
                var href = node.getAttribute('href') || '';
                if (href.charAt(0) !== '#') { return; }
                var id = href.slice(1);
                if (document.getElementById(id)) { return; }
                var fallback = targetOf(node);
                if (!fallback) { return; }
                event.preventDefault();
                fallback.scrollIntoView();
            });
        }

        /* ---------- resizable divider ---------- */

        var resizer = document.getElementById('toc-resizer');
        if (resizer) {
            var root = document.documentElement;
            var MIN_WIDTH = 120;      /* narrower than this and the titles are unreadable */
            var RESERVED = 200;       /* keep this much for the text */
            var dragX = 0, dragWidth = 0, dragging = false;

            function applySidebarWidth(px) {
                root.style.setProperty('--toc-width', Math.round(px) + 'px');
            }
            function sidebarWidth() {
                return toc ? toc.getBoundingClientRect().width : 0;
            }
            /* The extension remembers the width per user; 25% of the panel otherwise. */
            if (state.sidebarWidth) { applySidebarWidth(state.sidebarWidth); }

            resizer.addEventListener('pointerdown', function (event) {
                if (!toc) { return; }
                event.preventDefault();
                dragging = true;
                dragX = event.clientX;
                dragWidth = sidebarWidth();
                document.body.classList.add('toc-resizing');
                try { resizer.setPointerCapture(event.pointerId); } catch (error) {}
            });

            resizer.addEventListener('pointermove', function (event) {
                if (!dragging) { return; }
                /* The divider sits on the sidebar's inner edge, which is the left in LTR
                   and the right in RTL, so the drag direction flips with it. */
                var rtl = getComputedStyle(root).direction === 'rtl';
                var delta = (event.clientX - dragX) * (rtl ? -1 : 1);
                var width = Math.min(Math.max(dragWidth + delta, MIN_WIDTH), window.innerWidth - RESERVED);
                applySidebarWidth(width);
            });

            /* Persisted once the drag ends, not on every move. */
            function endResize(event) {
                if (!dragging) { return; }
                dragging = false;
                document.body.classList.remove('toc-resizing');
                try { resizer.releasePointerCapture(event.pointerId); } catch (error) {}
                var width = Math.round(sidebarWidth());
                applySidebarWidth(width);
                send(uiBridge, { sidebarWidth: width });
                dropLayout();
                refreshScrollbar();
            }
            ['pointerup', 'pointercancel'].forEach(function (name) {
                resizer.addEventListener(name, endResize);
            });
        }

        /* ---------- reading position ---------- */

        var layout = null;
        function dropLayout() { layout = null; }
        window.addEventListener('resize', function () { dropLayout(); refreshScrollbar(); });

        function headings() {
            return content.querySelectorAll('section.chapter h1[id], section.chapter h2[id], section.chapter h3[id]');
        }

        /* One pass over the headings; reading a rect forces layout, so it is cached
           and dropped whenever the layout can have changed. */
        function measure() {
            if (layout !== null) { return layout; }
            var list = headings();
            var scroll = scroller.scrollTop;
            var offsets = new Array(list.length);
            for (var i = 0; i < list.length; i++) {
                offsets[i] = list[i].getBoundingClientRect().top + scroll;
            }
            layout = {
                list: list,
                offsets: offsets,
                height: Math.max(1, scroller.scrollHeight - scroller.clientHeight),
                bottom: scroller.scrollHeight
            };
            return layout;
        }

        /* A heading's section runs to the next heading, not to the height of the
           heading itself - that is what makes a fraction meaningful. */
        function spanAt(m, index) {
            var end = (index + 1 < m.offsets.length) ? m.offsets[index + 1] : m.bottom;
            return Math.max(1, end - m.offsets[index]);
        }

        function place() {
            var m = measure();
            var scroll = scroller.scrollTop;
            var anchor = '', sectionOffset = 0;
            for (var i = 0; i < m.offsets.length; i++) {
                if (m.offsets[i] > scroll + 2) { break; }
                anchor = m.list[i].id;
                sectionOffset = (scroll - m.offsets[i]) / spanAt(m, i);
            }
            sectionOffset = Math.min(1, Math.max(0, sectionOffset));
            return { anchor: anchor, sectionOffset: sectionOffset, fraction: scroll / m.height };
        }

        var armed = false, lastSent = 0, timer = null;
        function report() {
            refreshScrollbar();
            if (!armed || !positionBridge) { return; }
            var now = Date.now();
            if (now - lastSent >= 350) {
                lastSent = now;
                send(positionBridge, place());
                return;
            }
            clearTimeout(timer);
            timer = setTimeout(function () {
                lastSent = Date.now();
                send(positionBridge, place());
            }, 350);
        }
        window.addEventListener('scroll', report, { passive: true });

        var userTookOver = false;
        ['wheel', 'mousedown', 'keydown', 'touchstart'].forEach(function (name) {
            window.addEventListener(name, function () { userTookOver = true; }, { passive: true, capture: true });
        });

        function targetOffset() {
            if (!saved) { return 0; }
            var m = measure();
            if (saved.anchor) {
                for (var i = 0; i < m.list.length; i++) {
                    if (m.list[i].id === saved.anchor) {
                        return m.offsets[i] + (saved.sectionOffset || 0) * spanAt(m, i);
                    }
                }
            }
            if (typeof saved.scrollY === 'number' && saved.scrollY > 0) { return saved.scrollY; }
            return (saved.fraction || 0) * m.height;
        }

        /* A long book is still laying out when load fires, so keep applying the
           position as the layout settles - the last application wins. The reader's
           own scrolling always wins over ours.

           Prefer jumping to the anchor element itself: WebKit resolves the fragment
           against the real element (and renders a `content-visibility` section to do
           it), which is both simpler and more accurate than adding up measured
           offsets - those are only estimates for sections that have never been
           rendered. */
        function applyRestore() {
            if (!saved || userTookOver) { return; }
            dropLayout();

            if (saved.anchor) {
                var element = document.getElementById(saved.anchor);
                if (element) {
                    element.scrollIntoView(true);
                    var extra = (saved.sectionOffset || 0) * (element.getBoundingClientRect().height || 0);
                    if (extra > 1) { window.scrollBy(0, extra); }
                    return;
                }
            }

            var target = targetOffset();
            if (target <= 1) { return; }
            if (Math.abs(scroller.scrollTop - target) < 4) { return; }
            window.scrollTo(0, target);
        }
        [30, 200, 500, 1000, 1800, 2600].forEach(function (delay) {
            setTimeout(applyRestore, delay);
        });

        function showResumeHint(fraction) {
            if (fraction < 0.02) { return; }
            var pill = document.createElement('div');
            pill.id = 'ekb-resume';
            var label = document.createElement('span');
            label.textContent = 'Resumed at ' + Math.round(fraction * 100) + '%';
            var back = document.createElement('a');
            back.href = '#';
            back.textContent = 'top';
            back.addEventListener('click', function (event) {
                event.preventDefault();
                window.scrollTo({ top: 0, behavior: 'smooth' });
                pill.remove();
            });
            pill.appendChild(label);
            pill.appendChild(back);
            document.body.appendChild(pill);
            if (document.body.classList.contains('no-toc')) { pill.style.left = '26px'; }
            setTimeout(function () { pill.classList.add('ekb-gone'); }, 5000);
            setTimeout(function () { pill.remove(); }, 7000);
        }

        /* ---------- scroll indicator ---------- */

        var scrollbar = null, scrollbarThumb = null;
        function buildScrollbar() {
            scrollbar = document.createElement('div');
            scrollbar.id = 'ekb-scrollbar';
            scrollbarThumb = document.createElement('div');
            scrollbarThumb.id = 'ekb-scrollbar-thumb';
            scrollbar.appendChild(scrollbarThumb);
            document.body.appendChild(scrollbar);
            scrollbar.addEventListener('click', function (event) {
                var rect = scrollbar.getBoundingClientRect();
                var fraction = (event.clientY - rect.top) / Math.max(1, rect.height);
                window.scrollTo(0, fraction * Math.max(0, scroller.scrollHeight - scroller.clientHeight));
            });
        }
        function refreshScrollbar() {
            if (!scrollbar) { return; }
            var total = scroller.scrollHeight, view = scroller.clientHeight;
            if (total <= view + 8) { scrollbar.style.display = 'none'; return; }
            scrollbar.style.display = 'block';
            var height = Math.max(36, Math.round(scrollbar.clientHeight * view / total));
            var progress = scroller.scrollTop / Math.max(1, total - view);
            scrollbarThumb.style.height = height + 'px';
            scrollbarThumb.style.top = Math.round((scrollbar.clientHeight - height) * Math.min(1, Math.max(0, progress))) + 'px';
        }

        /* ---------- highlight the entry being read ---------- */

        var current = null;
        function updateCurrent() {
            if (!toc || !tocScroll) { return; }
            /* The entry to highlight is the last one whose target sits at or above the
               reading line. Read fresh on every call: a list of positions goes stale as
               sections below the fold get laid out, and a stale one highlights the wrong
               entry (or none) with nothing to show that it has. Each target is one rect
               read over a laid-out document, so this is cheap. */
            var scroll = scroller.scrollTop;
            var line = scroll + 100;
            var match = null, best = -Infinity;
            toc.querySelectorAll('a[href^="#"]').forEach(function (link) {
                var target = targetOf(link);
                if (!target) { return; }
                var at = target.getBoundingClientRect().top + scroll;
                if (at <= line && at > best) { best = at; match = link; }
            });
            if (current === match) { return; }
            if (current) { current.parentElement.classList.remove('current'); }

            /* The branches kept open for an entry: its own ancestors, up to the tree
               root. Used both to open the new entry's chain and to work out which
               branches the old entry was holding open on its own. */
            function ancestorsOf(element) {
                var out = [];
                for (var node = element.parentElement; node && node !== toc; node = node.parentElement) {
                    if (node.classList && node.classList.contains('toc-item')) { out.push(node); }
                }
                return out;
            }

            var previous = current;
            current = match;
            if (!current) { return; }

            var item = current.parentElement;
            var nowKeep = ancestorsOf(item);
            item.classList.add('current');
            /* Open the new entry's chain, or what is highlighted cannot be seen. */
            nowKeep.forEach(function (branch) { branch.classList.remove('collapsed'); });

            /* And fold back only what the previous entry was holding open on its own.
               The chain it shared with the new entry stays open; a branch the reader
               opened by hand and is still looking at is not touched. Strict follow-fold
               (collapse everything not in the current chain) was tried and reverted:
               it folded branches the reader had deliberately opened. */
            if (previous) {
                ancestorsOf(previous.parentElement).forEach(function (branch) {
                    if (nowKeep.indexOf(branch) === -1) { branch.classList.add('collapsed'); }
                });
            }
            reflectFoldState();
            /* Bring it into view. Measured against the scrolling list itself: offsetTop is
               relative to the nearest positioned ancestor, and `.toc-item` is positioned, so
               a nested entry's offsetTop is its distance from the entry above it, not from
               the list top. Compared against tocScroll.scrollTop, that number pins the list
               near its top while the highlighted entry sits hundreds of pixels below - on
               screen it looks like the list never follows the book. */
            var box = tocScroll.getBoundingClientRect();
            var top = item.getBoundingClientRect().top - box.top + tocScroll.scrollTop;
            if (top < tocScroll.scrollTop || top + item.offsetHeight > tocScroll.scrollTop + tocScroll.clientHeight) {
                tocScroll.scrollTop = Math.max(0, top - tocScroll.clientHeight / 3);
            }
        }

        var scheduled = false;
        window.addEventListener('scroll', function () {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(function () { scheduled = false; updateCurrent(); });
        }, { passive: true });

        /* ---------- start ---------- */

        buildScrollbar();
        refreshScrollbar();
        updateCurrent();
        if (document.readyState !== 'complete') {
            window.addEventListener('load', function () { applyRestore(); updateCurrent(); refreshScrollbar(); });
        }

        /* Recording only starts once the restore has settled, so the 0 a fresh page
           reports can never overwrite a real position. */
        setTimeout(function () {
            if (saved && !userTookOver) {
                var landed = place();
                if (landed.fraction >= 0.02) { showResumeHint(landed.fraction); }
                send(positionBridge, landed);
            }
            armed = true;
        }, 3000);
    })();
    """
}
