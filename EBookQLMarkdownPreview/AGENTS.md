# EBookQLMarkdownPreview

Markdown-only Quick Look preview appex, the sibling of `EBookQLPreview` that the user can switch on/off independently. It carries NO Swift sources of its own: `project.yml` compiles the `EBookQLPreview/` sources into it and copies `EBookQLPreview/ReaderAssets/` into its bundle.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| UTI list (`net.daringfireball.markdown` + `com.rocaltair.mdx`, imported here; the type itself is exported by the host app) | Info.plist |
| Principal class (`ReaderPreviewProvider`) | Info.plist `NSExtensionPrincipalClass` |
| Sandbox entitlements (`app-sandbox` + `network.client` + read-only) | EBookQLMarkdownPreview.entitlements |
| Shared sources + resources phase | project.yml target `EBookQLMarkdownPreview` |
| Bundle id | `com.rocaltair.EBookQL.MarkdownPreview` |

## CONVENTIONS
- `.md` and `.markdown` map to the system UTI `net.daringfireball.markdown`; `.mdx` is EBookQL's own `com.rocaltair.mdx`, conforming to Markdown and `public.plain-text`.
- `project.yml` excludes `Info.plist`, `*.entitlements` and `ReaderAssets` from the shared source glob, then re-adds `EBookQLPreview/ReaderAssets` as an optional resources phase. That phase is what puts the Mermaid/KaTeX files at the appex bundle root.
- Sandbox entitlements match the other appexes; the Markdown backend additionally needs `JavaScriptCore` in `OTHER_LDFLAGS`.
- `ReaderPreferences` reads the host's `settings.json` from this appex's own container.
- Splitting Markdown into its own appex is what lets the user truly disable Markdown Quick Look; macOS then falls back to its own generator.

## ANTI-PATTERNS
- Putting Swift sources in this directory: the target compiles the shared `EBookQLPreview/` sources, so a duplicate file would collide.
- Dropping the `ReaderAssets` resources phase: the reader would find no Mermaid/KaTeX at the bundle root.
- Forgetting `-Wl,-needed_framework,QuickLookUI` or `JavaScriptCore` for this target.
- Letting the MDX `UTImportedTypeDeclarations` drift from the app and sibling Info.plists.
