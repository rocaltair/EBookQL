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
    /* A markdown book may force a concrete scheme: the reader's Settings choice wins
       over the system. Scoped to the data-theme attribute, which only a markdown page
       sets, so an EPUB/MOBI page (no attribute) is untouched and keeps following the
       media query above. Attribute selector outranks :root, so the forced palette wins. */
    html[data-theme="dark"] {
        color-scheme: dark;
        --page-bg: #202022;
        --text-color: #e8e8ea;
        --toc-bg: #2b2b2e;
        --toc-border: rgba(255, 255, 255, .16);
        --hover-bg: rgba(255, 255, 255, .08);
        --current-bg: rgba(255, 255, 255, .16);
    }
    html[data-theme="light"] {
        color-scheme: light;
        --page-bg: #f7f7f8;
        --text-color: #1c1c1e;
        --toc-bg: #ececef;
        --toc-border: rgba(0, 0, 0, .14);
        --hover-bg: rgba(0, 0, 0, .07);
        --current-bg: rgba(0, 0, 0, .13);
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
    #toc-zoom button, #toc-fold-toggle, #toc-fold-follow, #toc-hide, #toc-show {
        font: inherit; font-size: .88em; cursor: pointer; border: 1px solid var(--toc-border);
        background: var(--toc-bg); color: inherit; border-radius: .48em;
        padding: .08em .4em; opacity: .75;
    }
    #toc-zoom button:hover, #toc-fold-toggle:hover, #toc-fold-follow:hover, #toc-hide:hover, #toc-show:hover { opacity: 1; background: var(--hover-bg); }
    #toc-zoom #zoom-level { min-width: 2.88em; text-align: center; font-variant-numeric: tabular-nums; }
    /* One button, two states: ▸▸ folds everything, ▾▾ opens everything. Kept narrow so
       title + A−/100%/A+ + this + the auto-fold switch + hide all fit beside the title. */
    #toc-fold-toggle { padding: .08em .3em; font-size: .8em; letter-spacing: -.06em; }
    /* The auto-fold mode, drawn as a switch instead of a third triangle: the head
       already spends ▸/▾ on folding, so a glyph here would be read as another fold
       button. A track and a knob also need no glyph the system font might lack. */
    #toc-fold-follow {
        flex: 0 0 auto; position: relative; box-sizing: border-box;
        width: 1.8em; height: 1em; padding: 0; border-radius: .5em; opacity: .8;
    }
    #toc-fold-follow::after {
        content: ""; position: absolute; top: 50%; inset-inline-start: .12em;
        width: .6em; height: .6em; margin-block-start: -.3em; border-radius: 50%;
        background: currentColor; opacity: .4;
        transition: inset-inline-start .12s ease, background .12s ease, opacity .12s ease;
    }
    #toc-fold-follow[aria-pressed="true"] {
        background: var(--accent); border-color: var(--accent);
    }
    #toc-fold-follow[aria-pressed="true"]:hover { background: var(--accent); }
    #toc-fold-follow[aria-pressed="true"]::after {
        inset-inline-start: calc(100% - .72em); background: #fff; opacity: 1;
    }
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

    /* Where a link or an image really leads, along the foot of the text column -
       Chrome's status bubble. Never hit-tested: a strip that can take the hover away
       from the link under it makes the link flicker, which is exactly what the strip
       exists to avoid. */
    #ekb-status {
        position: fixed; z-index: 4; display: none;
        inset-block-end: 12px; inset-inline-start: calc(var(--toc-width) + 14px);
        max-width: min(68ch, calc(100% - var(--toc-width) - 60px));
        padding: 3px 9px; border-radius: 6px;
        background: rgba(60, 60, 67, .92); color: #fff;
        font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
        font-size: 11.5px; line-height: 1.5;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        pointer-events: none; -webkit-user-select: none; user-select: none;
    }
    #ekb-status.ekb-on { display: block; }
    body.toc-collapsed #ekb-status { inset-inline-start: 14px; max-width: calc(100% - 60px); }

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

    /* Markdown-derived content: TeX and Mermaid diagrams, rendered in place by the
       reader bootstrap from the vendored assets. Until (or unless) that succeeds the
       raw markup stays on screen, so the unrendered forms keep a readable look. */
    .math-block { display: block; text-align: center; overflow-x: auto; margin: 1em 0; }
    .math-inline { white-space: nowrap; }
    .mermaid { text-align: center; margin: 1em 0; }
    /* Mermaid marks an element it has replaced with data-processed; only the source
       that is still waiting to render gets the code-block treatment. */
    pre.mermaid:not([data-processed]) {
        text-align: start; padding: .6em .8em; border-radius: .4em; overflow-x: auto;
        background: var(--hover-bg); font-size: .92em; opacity: .75;
    }

    /* GitHub-flavored Markdown skin. Scoped to html[data-format="markdown"], which
       ReaderDocument emits for a markdown book only, so no rule below can reach an
       EPUB/MOBI page. Fonts apply to #content alone; the chrome is left as it was. */
    html[data-format="markdown"] {
        --gh-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        --gh-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
        background: var(--gh-canvas);
        color: var(--gh-text);
    }
    html[data-format="markdown"][data-theme="light"] {
        color-scheme: light;
        --gh-canvas: #ffffff;
        --gh-subtle: #f6f8fa;
        --gh-border: #d0d7de;
        --gh-text: #1f2328;
        --gh-muted: #57606a;
        --gh-accent: #0969da;
        --gh-code-bg: rgba(175, 184, 193, .2);
        --page-bg: #ffffff;
        --text-color: #1f2328;
    }
    html[data-format="markdown"][data-theme="dark"] {
        color-scheme: dark;
        --gh-canvas: #0d1117;
        --gh-subtle: #161b22;
        --gh-border: #30363d;
        --gh-text: #e6edf3;
        --gh-muted: #8b949e;
        --gh-accent: #2f81f7;
        --gh-code-bg: rgba(110, 118, 129, .4);
        --page-bg: #0d1117;
        --text-color: #e6edf3;
    }
    html[data-format="markdown"] #content {
        font-family: var(--gh-sans);
        line-height: 1.5;
    }
    html[data-format="markdown"] #content p { margin: 0 0 16px; }
    html[data-format="markdown"] #content .chapter > :first-child { margin-top: 0; }

    /* Tables: collapsed hairlines, a header row like a heading, zebra body rows, and a
       wide table scrolling inside its own box instead of stretching the page. */
    html[data-format="markdown"] #content table {
        display: block; width: max-content; max-width: 100%; overflow: auto;
        border-collapse: collapse; border-spacing: 0; margin: 0 0 16px;
    }
    html[data-format="markdown"] #content table th,
    html[data-format="markdown"] #content table td {
        padding: 6px 13px; border: 1px solid var(--gh-border);
    }
    html[data-format="markdown"] #content table th {
        font-weight: 600; background: var(--gh-subtle);
    }
    html[data-format="markdown"] #content table tr {
        background: var(--gh-canvas); border-top: 1px solid var(--gh-border);
    }
    html[data-format="markdown"] #content table tr:nth-child(2n) { background: var(--gh-subtle); }

    /* Code: a tinted, rounded block for pre, a small chip for inline code. */
    html[data-format="markdown"] #content pre {
        padding: 16px; overflow: auto; margin: 0 0 16px;
        background: var(--gh-subtle); border-radius: 6px; font-size: 85%; line-height: 1.45;
    }
    html[data-format="markdown"] #content code {
        font-family: var(--gh-mono); font-size: 85%;
        background: var(--gh-code-bg); padding: .2em .4em; border-radius: 6px;
    }
    html[data-format="markdown"] #content pre code {
        background: transparent; padding: 0; border-radius: 0; font-size: 100%; white-space: pre;
    }

    /* Headings: the h1/h2 hairline is the README tell. */
    html[data-format="markdown"] #content h1,
    html[data-format="markdown"] #content h2 {
        padding-bottom: .3em; border-bottom: 1px solid var(--gh-border);
    }
    html[data-format="markdown"] #content h1,
    html[data-format="markdown"] #content h2,
    html[data-format="markdown"] #content h3,
    html[data-format="markdown"] #content h4,
    html[data-format="markdown"] #content h5,
    html[data-format="markdown"] #content h6 {
        margin: 24px 0 16px; font-weight: 600; line-height: 1.25;
    }
    html[data-format="markdown"] #content h1 { font-size: 2em; }
    html[data-format="markdown"] #content h2 { font-size: 1.5em; }
    html[data-format="markdown"] #content h3 { font-size: 1.25em; }
    html[data-format="markdown"] #content h6 { color: var(--gh-muted); }

    /* Links, quotes, rules, lists, task lists. */
    html[data-format="markdown"] #content a { color: var(--gh-accent); text-decoration: underline; }
    html[data-format="markdown"] #content blockquote {
        padding: 0 1em; margin: 0 0 16px; color: var(--gh-muted); opacity: 1;
        border-inline-start: .25em solid var(--gh-border);
    }
    html[data-format="markdown"] #content hr {
        height: .25em; padding: 0; margin: 24px 0; border: 0; background: var(--gh-border);
    }
    html[data-format="markdown"] #content ul,
    html[data-format="markdown"] #content ol { padding-inline-start: 2em; margin: 0 0 16px; }
    html[data-format="markdown"] #content li + li { margin-top: .25em; }
    html[data-format="markdown"] #content li > ul,
    html[data-format="markdown"] #content li > ol { margin-top: .25em; margin-bottom: 0; }
    /* marked emits a bare checkbox inside the <li>, no class, so the item is matched
       structurally and the box is pulled back over the list indent. */
    html[data-format="markdown"] #content li:has(input[type="checkbox"]) { list-style: none; }
    html[data-format="markdown"] #content li:has(input[type="checkbox"]) > p { margin-top: 0; margin-bottom: 0; }
    html[data-format="markdown"] #content li input[type="checkbox"] {
        margin: 0 .2em .25em -1.6em; vertical-align: middle;
    }
    html[data-format="markdown"] #content img { max-width: 100%; }
    html[data-format="markdown"] #content del { text-decoration: line-through; }

    /* Copy button on code blocks: a markdown-scoped enhancer adds one <button>
       per eligible <pre>, so only the block that contains it is made a
       positioning context. The button hides until the block is hovered or the
       button is focused/keyboard-copied, and the extra top padding keeps the
       first code line clear of it. */
    html[data-format="markdown"] #content pre.ekb-has-copy {
        position: relative; padding-top: 34px;
    }
    html[data-format="markdown"] #content .ekb-copy {
        position: absolute; top: 6px; right: 6px;
        padding: 2px 8px; border: 1px solid var(--gh-border); border-radius: 6px;
        background: var(--gh-subtle); color: var(--gh-text);
        font-family: var(--gh-sans); font-size: 12px; line-height: 1.4;
        cursor: pointer; opacity: 0; transition: opacity .12s ease;
    }
    html[data-format="markdown"] #content pre.ekb-has-copy:hover .ekb-copy,
    html[data-format="markdown"] #content .ekb-copy:focus-visible,
    html[data-format="markdown"] #content .ekb-copy[data-copied] { opacity: 1; }
    html[data-format="markdown"] #content .ekb-copy:hover {
        background: var(--gh-canvas); border-color: var(--gh-muted);
    }
    html[data-format="markdown"] #content .ekb-copy[data-copied] {
        color: var(--gh-accent); border-color: var(--gh-accent);
    }
    /* The same button on block math. Only the positioning context and the hover
       reveal are math-specific; the look above is the shared .ekb-copy rule. Inline
       math is clicked directly (cursor: copy) and flashes a brief highlight. */
    html[data-format="markdown"] #content .math-block.ekb-math-copy { position: relative; }
    html[data-format="markdown"] #content .math-block.ekb-math-copy .ekb-copy {
        position: absolute; top: 6px; right: 6px; opacity: 0;
    }
    html[data-format="markdown"] #content .math-block.ekb-math-copy:hover .ekb-copy,
    html[data-format="markdown"] #content .math-block.ekb-math-copy .ekb-copy:focus-visible,
    html[data-format="markdown"] #content .math-block.ekb-math-copy .ekb-copy[data-copied] { opacity: 1; }
    html[data-format="markdown"] #content .math-inline.ekb-math-copy { cursor: copy; }
    html[data-format="markdown"] #content .math-inline.ekb-math-copy[data-ekb-copied] {
        background: var(--gh-code-bg); border-radius: 3px;
    }

    /* Line numbers on markdown code blocks, opt-in via the page's `lineNumbers`
       state (the markdown enhancer adds .ekb-lines only then). Each wrapped line
       is a block whose number is a ::before pseudo-element in a reserved left grid
       column (2.4em, plus a .75em gap - the old inline geometry). The gutter is a
       box of its own, not padding: WebKit stretches a multi-line selection across
       the text box, and padding would be painted over on the lines between the
       endpoints. Being pseudo content, the number is invisible to textContent and
       the Copy button still yields the original source byte-for-byte. An interior
       blank line is :empty, so it is unnumbered but still occupies one line via
       min-height. */
    html[data-format="markdown"] #content pre.ekb-lines { counter-reset: ekb-line; }
    html[data-format="markdown"] #content pre.ekb-lines code { display: block; }
    html[data-format="markdown"] #content pre.ekb-lines .ekb-line {
        display: grid; grid-template-columns: 2.4em 1fr; column-gap: .75em;
    }
    html[data-format="markdown"] #content pre.ekb-lines .ekb-line:empty { min-height: 1lh; }
    html[data-format="markdown"] #content pre.ekb-lines .ekb-line::before {
        counter-increment: ekb-line;
        content: counter(ekb-line);
        grid-column: 1; grid-row: 1; box-sizing: border-box;
        text-align: right; color: var(--gh-muted); font-family: var(--gh-mono);
        -webkit-user-select: none; user-select: none;
    }
    html[data-format="markdown"] #content pre.ekb-lines .ekb-line:empty::before {
        counter-increment: none; content: none;
    }

    /* Collapsible <details>, the GitHub way: raw HTML passed through by marked.
       Only rhythm, weight and the affordance cursor are set; the native
       disclosure marker is left alone. */
    html[data-format="markdown"] #content details { margin: 16px 0; }
    html[data-format="markdown"] #content summary {
        cursor: pointer; font-weight: 600; margin-bottom: 0;
    }
    html[data-format="markdown"] #content details[open] > summary { margin-bottom: 8px; }

    /* FictionBook: the elements FB2 has and HTML does not. Scoped to the format attribute a
       FB2 page carries, so an EPUB/MOBI page (no attribute) matches none of it. */
    html[data-format="fb2"] #content p { margin: 0 0 .6em 0; text-indent: 1.2em; }
    html[data-format="fb2"] #content p.fb2-empty-line { margin: 0; height: 1em; }
    html[data-format="fb2"] #content .fb2-body-break {
        margin: 32px 0; border-top: 1px solid var(--toc-border);
    }
    html[data-format="fb2"] #content .fb2-subtitle {
        font-weight: 600; text-align: center; text-indent: 0; margin: 1.2em 0 .6em;
    }
    html[data-format="fb2"] #content .fb2-minor-title { font-weight: 600; text-indent: 0; }
    html[data-format="fb2"] #content .fb2-epigraph,
    html[data-format="fb2"] #content .fb2-cite {
        margin: 0 0 1em 1.6em; font-style: italic; opacity: .9;
    }
    html[data-format="fb2"] #content .fb2-cite p { text-indent: 0; }
    html[data-format="fb2"] #content .fb2-text-author {
        text-align: right; text-indent: 0; font-style: italic; opacity: .75;
    }
    html[data-format="fb2"] #content .fb2-poem { margin: 1em 0 1.4em 1.2em; }
    html[data-format="fb2"] #content .fb2-stanza { margin: 0 0 .8em 0; }
    html[data-format="fb2"] #content .fb2-verse { text-indent: 0; margin: 0; }
    html[data-format="fb2"] #content .fb2-annotation {
        margin: 0 0 1.2em; padding: 0 1em; opacity: .85; font-size: .95em;
    }
    html[data-format="fb2"] #content .fb2-note-ref { font-size: .75em; vertical-align: super; }
    html[data-format="fb2"] #content img.fb2-image { display: block; margin: 1em auto; }
    html[data-format="fb2"] #content table {
        border-collapse: collapse; margin: 1em 0;
    }
    html[data-format="fb2"] #content td, html[data-format="fb2"] #content th {
        border: 1px solid var(--toc-border); padding: .3em .6em; text-align: start;
    }

    /* End of the FictionBook skin: same rule as the Markdown one above - every selector is
       gated on html[data-format="fb2"], an attribute ReaderDocument emits only for an FB2
       book, so no other format matches any of it. */
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

        /* The auto-fold mode. It decides one thing only: whether `updateCurrent` closes
           the branch it is leaving. With it off the entry being read still follows the
           book and still opens its own branch - an entry folded away would be a
           highlight nobody can see - and nothing is closed behind the reader. */
        var foldFollow = document.getElementById('toc-fold-follow');
        var autoFold = state.autoFoldTOC !== false;
        function reflectAutoFold() {
            if (!foldFollow) { return; }
            foldFollow.setAttribute('aria-pressed', autoFold ? 'true' : 'false');
            foldFollow.title = autoFold ? 'Auto-fold contents: on' : 'Auto-fold contents: off';
        }
        reflectAutoFold();
        if (foldFollow) {
            foldFollow.addEventListener('click', function () {
                autoFold = !autoFold;
                reflectAutoFold();
                /* Remembered by the extension, like the sidebar width: a mode the reader
                   has to set again on every preview is not a mode. Switching it back on
                   folds nothing by itself - the next highlight change does that. */
                send(uiBridge, { autoFoldTOC: autoFold });
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
            /* Everything starts folded: the sidebar opens as a bare outline, and the
               follow-fold below is what opens the branch being read. */
            toc.querySelectorAll('li.has-children').forEach(function (item) {
                item.classList.add('collapsed');
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
            var MIN_WIDTH = 220;      /* measured: below this the header row (title + A−/100%/A+
                                         + fold + auto-fold + hide) is squeezed or clipped */
            var RESERVED = 200;       /* keep this much for the text */
            var dragX = 0, dragWidth = 0, dragging = false;

            function applySidebarWidth(px) {
                root.style.setProperty('--toc-width', Math.round(px) + 'px');
            }
            function sidebarWidth() {
                return toc ? toc.getBoundingClientRect().width : 0;
            }
            /* The extension remembers the width per user; 25% of the panel otherwise.
               A width stored before the minimum was raised is lifted to it, or the
               header row would come back clipped until the divider is dragged again. */
            if (state.sidebarWidth) { applySidebarWidth(Math.max(state.sidebarWidth, MIN_WIDTH)); }

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
               it folded branches the reader had deliberately opened. All of it is
               skipped while the sidebar's auto-fold switch is off. */
            if (autoFold && previous) {
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

        /* ---------- where a link or an image really leads ---------- */

        /* Chrome's status bubble, at the foot of the text column. An in-page link
           names the entry it lands on - the anchor ids here are chN--… , which is not
           something to show a reader - and everything else, a remote image included,
           shows the absolute URL the click would follow. */
        var statusStrip = document.createElement('div');
        statusStrip.id = 'ekb-status';
        document.body.appendChild(statusStrip);

        function statusTextFor(node) {
            if (node.tagName === 'IMG') {
                var source = node.currentSrc || node.getAttribute('src') || '';
                /* A data: URL is not a destination, and the blocked-network-image tile
                   already says what it is, in the page itself. */
                return source.slice(0, 5) === 'data:' ? '' : source;
            }
            var href = node.getAttribute('href') || '';
            if (href.charAt(0) !== '#') { return node.href || href; }
            var target = targetOf(node);
            if (!target) { return href; }
            var text = leadingText(target, 80);
            if (!text) { return href; }
            return '→ ' + text + (text.length >= 80 ? '…' : '');
        }

        /* The first `limit` characters of text inside an element, stopping there. A
           sidebar entry can point straight at a whole chapter (every entry of one
           book did), and materialising a chapter's text on every hover is work the
           reader would feel; the walker stops as soon as it has enough. Trim only
           otherwise: `white-space: nowrap` collapses whatever is left, so no regex
           and no escape is needed anywhere here. */
        function leadingText(element, limit) {
            var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
            var out = '', node;
            while (out.length < limit && (node = walker.nextNode())) {
                out += node.nodeValue;
            }
            return out.trim().slice(0, limit).trim();
        }

        document.addEventListener('mouseover', function (event) {
            /* An image inside a link is a link: the link is what a click follows. */
            var link = event.target.closest ? event.target.closest('a') : null;
            var node = link || (event.target.closest ? event.target.closest('img') : null);
            var text = node ? statusTextFor(node) : '';
            if (text) {
                statusStrip.textContent = text;
                statusStrip.classList.add('ekb-on');
            } else {
                statusStrip.classList.remove('ekb-on');
            }
        }, true);

        document.addEventListener('mouseout', function () {
            statusStrip.classList.remove('ekb-on');
        }, true);

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

        /* ---------- clipboard ---------- */

        /* The one clipboard writer, shared by the code-block buttons and the math
           copy affordances. The extension's ekbCopy handler is preferred, then the
           async clipboard API, then a hidden textarea using execCommand. Defined
           once at IIFE scope so the math and code enhancers cannot drift apart. */
        var copyBridge = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.ekbCopy;

        function copyText(text) {
            if (copyBridge) {
                try { copyBridge.postMessage(text); return true; } catch (error) {}
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
                try { navigator.clipboard.writeText(text); return true; } catch (error) {}
            }
            try {
                var area = document.createElement('textarea');
                area.value = text;
                area.setAttribute('readonly', '');
                area.style.position = 'fixed';
                area.style.top = '-1000px';
                area.style.opacity = '0';
                document.body.appendChild(area);
                area.select();
                document.execCommand('copy');
                document.body.removeChild(area);
                return true;
            } catch (error) {
                return false;
            }
        }

        /* ---------- math + diagrams ---------- */

        /* Markdown-derived books carry TeX in .math-inline/.math-block and Mermaid
           diagrams in pre.mermaid; neither appears in an EPUB/MOBI page, so the two
           selector guards below make this a no-op for the formats that predate it.
           Both renderers are vendored and served from the appex bundle over
           ekbres://assets/ - never the network. A missing or failing asset leaves the
           source text visible; the page is never blanked and nothing here throws.

           When the reader turned JavaScript parsing off, the backend already returned
           the document's raw source and none of this should run: the hard `jsParse`
           guard below is what keeps the 2.8 MB mermaid/KaTeX bundle from ever being
           fetched for a page we are not going to enhance. */
        var ASSET_BASE = 'ekbres://assets/';
        var jsParse = state.jsParse !== false;

        function injectScript(src, onload) {
            var script = document.createElement('script');
            script.src = src;
            script.onload = function () { try { onload(); } catch (error) {} };
            script.onerror = function () {};
            document.head.appendChild(script);
        }

        if (jsParse && document.querySelector('.mermaid') && !window.mermaid) {
            injectScript(ASSET_BASE + 'mermaid.min.js', function () {
                try {
                    window.mermaid.initialize({
                        startOnLoad: false,
                        securityLevel: 'strict',
                        theme: state.theme === 'dark' ? 'dark' : 'default'
                    });
                    var running = window.mermaid.run({ querySelector: '.mermaid' });
                    if (running && typeof running.catch === 'function') { running.catch(function () {}); }
                } catch (error) {}
            });
        }

        if (jsParse && document.querySelector('.math-inline, .math-block') && !window.katex) {
            var katexStyle = document.createElement('link');
            katexStyle.rel = 'stylesheet';
            katexStyle.href = ASSET_BASE + 'katex.min.css';
            document.head.appendChild(katexStyle);

            injectScript(ASSET_BASE + 'katex.min.js', function () {
                var elements = document.querySelectorAll('.math-inline, .math-block');
                for (var i = 0; i < elements.length; i++) {
                    var element = elements[i];
                    if (element.getAttribute('data-ekb-math') === 'done') { continue; }

                    /* Stashed before the render replaces the children, and kept even
                       when the render throws, so the original TeX stays copyable. */
                    var tex = element.textContent;
                    element.setAttribute('data-ekb-tex', tex);

                    try {
                        window.katex.render(element.textContent, element, {
                            displayMode: element.classList.contains('math-block'),
                            throwOnError: false
                        });
                        element.setAttribute('data-ekb-math', 'done');
                    } catch (error) {
                        /* Leave the raw TeX in place rather than emptying the node. */
                    }
                }
                enhanceMath();
            });
        }

        /* Copy affordances for rendered math, on the same clipboard path as the
           code blocks. The raw TeX is stashed in data-ekb-tex before katex replaces
           the element's children. Block math gets the shared .ekb-copy button;
           inline math is copied by clicking the formula itself, with a brief
           data-ekb-copied highlight. Idempotent via .ekb-math-copy. */
        function enhanceMath() {
            if (document.documentElement.getAttribute('data-format') !== 'markdown') { return; }

            var blocks = document.querySelectorAll('.math-block[data-ekb-tex]:not(.ekb-math-copy)');
            for (var i = 0; i < blocks.length; i++) {
                var block = blocks[i];
                block.classList.add('ekb-math-copy');
                var button = document.createElement('button');
                button.type = 'button';
                button.className = 'ekb-copy';
                button.textContent = 'Copy';
                (function (owner, control) {
                    control.addEventListener('click', function () {
                        copyText(owner.getAttribute('data-ekb-tex'));
                        control.textContent = 'Copied';
                        control.setAttribute('data-copied', '');
                        setTimeout(function () {
                            control.textContent = 'Copy';
                            control.removeAttribute('data-copied');
                        }, 1200);
                    });
                })(block, button);
                block.appendChild(button);
            }

            var inlines = document.querySelectorAll('.math-inline[data-ekb-tex]:not(.ekb-math-copy)');
            for (var j = 0; j < inlines.length; j++) {
                var inline = inlines[j];
                inline.classList.add('ekb-math-copy');
                inline.setAttribute('title', 'Copy LaTeX');
                (function (owner) {
                    owner.addEventListener('click', function () {
                        copyText(owner.getAttribute('data-ekb-tex'));
                        owner.setAttribute('data-ekb-copied', '');
                        setTimeout(function () {
                            owner.removeAttribute('data-ekb-copied');
                        }, 1200);
                    });
                })(inline);
            }
        }

        /* ---------- copy buttons (markdown only) ---------- */

        /* GitHub-style copy button on fenced code blocks. The html[data-format]
           gate keeps this off an EPUB/MOBI page: only a markdown page carries
           the attribute, and there none of these selectors can run.
           Deliberately independent of jsParse, because a raw-source page
           (pre.markdown-source) is exactly where copying matters most. */
        if (document.documentElement.getAttribute('data-format') === 'markdown') {
            /* Off unless the reader turned it on. The numbers themselves are ::before
               pseudo content (see the stylesheet), never text nodes; the copy payload
               is captured before the wrapping below, so it stays the original source. */
            var wantsLineNumbers = state.lineNumbers === true;

            /* One block span per line; each span holds only its own line text and no
               '\\n', because their block layout supplies the breaks and the stylesheet
               keeps the counter in a left gutter outside the selectable text run. A
               trailing newline's empty piece is skipped so no spurious blank numbered
               row appears; an interior blank line stays as an :empty span, which the
               stylesheet keeps one line tall and unnumbered. */
            function applyLineNumbers(target) {
                var pieces = target.textContent.split('\\n');
                if (pieces.length > 1 && pieces[pieces.length - 1] === '') { pieces.pop(); }
                var fragment = document.createDocumentFragment();
                for (var i = 0; i < pieces.length; i++) {
                    var line = document.createElement('span');
                    line.className = 'ekb-line';
                    line.textContent = pieces[i];
                    fragment.appendChild(line);
                }
                while (target.firstChild) { target.removeChild(target.firstChild); }
                target.appendChild(fragment);
            }

            function enhanceCodeBlocks() {
                var blocks = content.querySelectorAll('pre');
                for (var i = 0; i < blocks.length; i++) {
                    var pre = blocks[i];
                    if (pre.classList.contains('mermaid')) { continue; }
                    if (pre.closest && pre.closest('.math-block')) { continue; }
                    if (pre.classList.contains('ekb-has-copy')) { continue; }
                    var code = pre.querySelector('code');
                    if (!code && !pre.classList.contains('markdown-source')) { continue; }

                    /* Captured before the button is appended, so the button's own
                       label is never part of a raw-source block's textContent. */
                    var text = code ? code.textContent : pre.textContent;

                    /* Line numbers wrap the line's text in block spans; the captured
                       payload above is already the original source, so copy is
                       unaffected by the wrapping either way. */
                    if (wantsLineNumbers && !pre.classList.contains('ekb-lines')) {
                        applyLineNumbers(code || pre);
                        pre.classList.add('ekb-lines');
                    }

                    pre.classList.add('ekb-has-copy');
                    var button = document.createElement('button');
                    button.type = 'button';
                    button.className = 'ekb-copy';
                    button.textContent = 'Copy';

                    (function (owner, control, payload) {
                        control.addEventListener('click', function () {
                            copyText(payload);
                            control.textContent = 'Copied';
                            control.setAttribute('data-copied', '');
                            setTimeout(function () {
                                control.textContent = 'Copy';
                                control.removeAttribute('data-copied');
                            }, 1200);
                        });
                    })(pre, button, text);

                    pre.appendChild(button);
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', enhanceCodeBlocks);
            } else {
                enhanceCodeBlocks();
            }

            /* Covers math whose katex was already present when this script ran (the
               injection gate above skipped, so its onload never fires). */
            enhanceMath();
        }
    })();
    """
}
