# EBookQLReader

The reader host shared by every host that shows a book: the app's reader windows and the three Quick Look preview appexes (`EBookQLPreview`, `EBookQLMarkdownPreview`, `EBookQLCHMPreview`) compile these files. One WKWebView, one generated page, one `ekbres://` handler, one reading position - so the app and Quick Look cannot drift apart.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Load a book into the reader | BookReaderViewController.swift:136 (`loadBook`) |
| WebView + message channels | BookReaderViewController.swift:84 (`loadView`) |
| Parse + page build off the main thread | BookReaderViewController.swift:249 (`render`) |
| JS→native handlers (position / ui / zoom / copy) | BookReaderViewController.swift:301 |
| Reading position read/write | BookReaderViewController.swift:152 / :333 |
| Zoom ladder + persistence | BookReaderViewController.swift:30–50, :385 |
| External-link policy (app only) | BookReaderViewController.swift:405 |
| Temp extraction dirs + stale sweep | BookReaderViewController.swift:170, :438 |
| `ekbres://` resource serving | ReaderSchemeHandler.swift |
| The settings a host feeds the reader | ReaderSettings.swift |
| Quick Look adapter (panel size, entry point) | ../EBookQLPreview/ReaderPreviewProvider.swift |
| App adapter (window, menus, Open…) | ../EBookQLApp/ReaderWindows.swift |

## CONVENTIONS
- The controller is host-agnostic: no Quick Look, no window management. `updatePanelSize()` is the one hook (Quick Look overrides it; a window ignores it).
- `settingsProvider` is called with the URL and returns nil for a format with no settings of its own: EPUB/MOBI never pay for a settings read, while Markdown and FB2 do.
- `readingPositionStore` is injected. An appex keeps the default (its sandbox container); the app passes `SettingsStore.sharedPositionsPath` so a book has one position whether it was read in the panel or in the app.
- `opensExternalLinks` is off by default so Quick Look keeps its old behaviour; the app turns it on and hands http/https/mailto to the browser instead of navigating the reader away from the book.
- `workDirectoryPrefix` separates hosts' temp dirs (`EBookQL_` for appexes, `EBookQLReader_` for the app) so one host's stale sweep can never delete a directory another live host is still reading from.
- Resources are reached through `ekbres://`, and the reserved `assets` host reads `Bundle.main` - the appex bundle in Quick Look, the app bundle in the app. Both bundles therefore carry `ReaderAssets/` (app) and `DjVuAssets/` (app) at their resource root, flat.
- A load carries a generation token: a slow render for a book the reader has already navigated away from is dropped instead of painting over the newer one.

## ANTI-PATTERNS
- Making this file import QuickLookUI or SwiftUI: it is compiled into the app, which needs neither for the reader itself.
- Letting the app and the appex use different position databases - that is the whole point of the injection.
- Releasing the security scope after parsing: images are read lazily while scrolling.
- Using `webView.pageZoom` for the A−/A+ control (see ../EBookQLKit/Reader/AGENTS.md).
- Adding a resource file name that collides between `ReaderAssets/` and `DjVuAssets/`: the app copies both into one flat resource root (this is why both `NOTICES.md` files are excluded there and shipped inside the appexes instead).
