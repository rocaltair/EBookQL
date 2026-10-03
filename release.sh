#!/bin/sh
#
# EBookQL — build a Release app and pack it into a drag-to-install disk image.
#
#   ./release.sh            build, then write dist/EBookQL-<version>.dmg
#   ./release.sh --keep     leave the staging folder behind for inspection
#
# The image holds the app, a symlink to /Applications and a short read-me, which is the
# whole install: drag the app onto the symlink, then open it once. Opening it is what
# registers the four extensions with the system — measured, a copy on its own registers
# nothing, and the first launch registers all of them and leaves them enabled. The app also does
# that itself on launch and reports the result in its window, so a machine where something
# else won the registration says so instead of failing quietly.
#
# No sudo and no developer account. The app is signed "Sign to Run Locally", so a copy
# that arrives over the network is quarantined by Gatekeeper and will not open until the
# user clears it (right-click ▸ Open, or `xattr -d com.apple.quarantine`). A DMG handed
# over by other means carries no quarantine flag and opens normally.

set -eu

APP_NAME=EBookQL
CONFIG=Release
DERIVED=build/DerivedData
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
STAGE=build/dmg
DIST=dist

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR

# install.sh already knows how to generate the project and build the app.
./install.sh build

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
DMG="$DIST/$APP_NAME-$VERSION.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE/$APP_NAME" "$DIST"
ditto "$BUILT_APP" "$STAGE/$APP_NAME/$APP_NAME.app"
ln -s /Applications "$STAGE/$APP_NAME/Applications"

cat > "$STAGE/$APP_NAME/Read me first.txt" <<'TEXT'
EBookQL — Quick Look previews and thumbnails for EPUB, MOBI, AZW, AZW3, FictionBook,
DjVu and CBZ books, and for Markdown.

1. Drag EBookQL onto the "Applications" folder in this window.
2. Open EBookQL from the Applications folder. Once is enough: opening it registers
   its Quick Look extensions, and the window shows whether they are live.
3. Select a book, a scan, a comic or a Markdown file in the Finder and press Space.

If nothing appears, or the window says an extension is "switched off", enable it in
System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look, then reopen the
Finder. A found book is loaded from wherever it lives, including network shares.

EBookQL is signed "Sign to Run Locally" (no developer account). If macOS refuses to
open a copy that was downloaded, right-click it and choose Open.
TEXT

# A plain HFS+ read-only image: no Finder scripting, so nothing to grant permission for.
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE/$APP_NAME" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

if [ "${1:-}" != "--keep" ]; then
    rm -rf "$STAGE"
fi

echo "built $DMG ($(du -h "$DMG" | cut -f1))"
echo "  contents:"
hdiutil attach "$DMG" -nobrowse -readonly >/dev/null && \
    ls -1 "/Volumes/$APP_NAME" | sed 's/^/    /' && \
    hdiutil detach "/Volumes/$APP_NAME" >/dev/null
