#!/bin/sh
#
# EBookQL — build, install and register the Quick Look preview + thumbnail
# extensions.
#
#   ./install.sh              build and install (into /Applications)
#   ./install.sh build        build only
#   ./install.sh status       show whether the extensions are registered/enabled
#   ./install.sh history      show the reading-history database, if any
#   ./install.sh uninstall    deregister and remove /Applications/EBookQL.app
#
# No sudo, no developer account: everything is signed "Sign to Run Locally".

set -eu

APP_NAME=EBookQL
CONFIG=Release
DERIVED=build/DerivedData
INSTALL_DIR=/Applications
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
PREVIEW_ID=com.rocaltair.EBookQL.Preview
THUMBNAIL_ID=com.rocaltair.EBookQL.Thumbnail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# xcodebuild needs Xcode, not the command line tools; don't touch the system
# selection, just point this script at it.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR

project() {
    command -v xcodegen >/dev/null 2>&1 || {
        echo "xcodegen is required: brew install xcodegen" >&2
        exit 1
    }
    xcodegen generate
}

build() {
    project
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
        -configuration "$CONFIG" -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" build
}

# Xcode registers the products it builds with LaunchServices, so an older copy
# in build/DerivedData can shadow the installed one. Drop those registrations.
deregister_built_products() {
    for bundle in "$BUILT_APP/Contents/PlugIns/EBookQLPreview.appex" \
                  "$BUILT_APP/Contents/PlugIns/EBookQLThumbnail.appex"; do
        [ -d "$bundle" ] && pluginkit -r "$bundle" >/dev/null 2>&1 || true
    done
    [ -d "$BUILT_APP" ] && "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
}

install_app() {
    build
    deregister_built_products
    rm -rf "$INSTALLED_APP"
    ditto "$BUILT_APP" "$INSTALLED_APP"
    codesign --verify --strict "$INSTALLED_APP"
    "$LSREGISTER" -f "$INSTALLED_APP"
    pluginkit -a "$INSTALLED_APP/Contents/PlugIns/EBookQLPreview.appex"
    pluginkit -a "$INSTALLED_APP/Contents/PlugIns/EBookQLThumbnail.appex"
    pluginkit -e use -i "$PREVIEW_ID"
    pluginkit -e use -i "$THUMBNAIL_ID"
    echo "installed $INSTALLED_APP"
    status
}

status() {
    echo "--- registered extensions ---"
    pluginkit -m -v 2>/dev/null | grep -i "$APP_NAME" || echo "  (none)"
    echo "--- how the book extensions resolve ---"
    /usr/bin/swift -e 'import UniformTypeIdentifiers
for ext in ["epub", "mobi", "azw", "azw3"] {
    print("  .\(ext) ->", UTType(filenameExtension: ext)?.identifier ?? "unknown")
}' 2>/dev/null || true
}

history() {
    db=$(find "$HOME/Library/Containers/$PREVIEW_ID" -name positions.sqlite3 2>/dev/null | head -1)
    if [ -z "$db" ]; then
        echo "no reading-history database yet (nothing has been previewed)"
        return
    fi
    echo "$db"
    sqlite3 "$db" "SELECT date(last_read,'unixepoch','localtime') AS last, opens, round(fraction,3) AS pos, substr(path, -45) FROM positions ORDER BY last_read DESC LIMIT 20;"
}

uninstall_app() {
    for bundle in "$INSTALLED_APP/Contents/PlugIns/EBookQLPreview.appex" \
                  "$INSTALLED_APP/Contents/PlugIns/EBookQLThumbnail.appex"; do
        [ -d "$bundle" ] && pluginkit -r "$bundle" || true
    done
    [ -d "$INSTALLED_APP" ] && "$LSREGISTER" -u "$INSTALLED_APP" || true
    rm -rf "$INSTALLED_APP"
    echo "removed $INSTALLED_APP"
}

case "${1:-install}" in
    build)     build ;;
    install)   install_app ;;
    status)    status ;;
    history)   history ;;
    uninstall) uninstall_app ;;
    *)         echo "usage: $0 [install|build|status|history|uninstall]" >&2; exit 2 ;;
esac
