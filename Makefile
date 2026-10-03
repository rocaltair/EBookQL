# EBookQL — convenience wrapper over install.sh / release.sh / xcodegen.
# `make` (or `make help`) lists the targets.

SHELL := /bin/sh
.DEFAULT_GOAL := help

APP       := EBookQL
DIST      := dist
DERIVED   := build/DerivedData
CONFIG    := Release
BUILT_APP := $(DERIVED)/Build/Products/$(CONFIG)/$(APP).app

# Where `make deploy` installs to. Empty (the default) means this machine: the dmg
# is installed right here, no ssh/scp. Set it to any ssh/scp target to install a
# copy on another machine instead: `make deploy REMOTE=user@host` (a host alias works
# too, e.g. `REMOTE=macmini`).
REMOTE ?=

# xcodebuild needs the GUI Xcode, not the Command Line Tools; don't touch the
# system selection, just point this build at it (same as install.sh does).
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: help generate build install release deploy status history uninstall clean

help:
	@echo "EBookQL — convenience targets:"
	@echo ""
	@echo "  make build       Release build only (build/DerivedData)"
	@echo "  make install     Build, install to /Applications, register both extensions"
	@echo "  make release     Build + dist/$(APP)-<version>.dmg"
	@echo "  make deploy      release, then install the dmg (REMOTE, or this Mac when empty)"
	@echo "  make status      Registered/enabled extensions + how book UTIs resolve"
	@echo "  make history     Show the saved reading positions"
	@echo "  make uninstall   Deregister and remove /Applications/$(APP).app"
	@echo "  make generate    Regenerate $(APP).xcodeproj from project.yml"
	@echo "  make clean       Remove build/ and dist/"
	@echo ""
	@echo "Variables:"
	@echo "  REMOTE=<empty>   deploy target. Empty (default) installs on this Mac;"
	@echo "                   otherwise an ssh/scp target, e.g. a host alias or"
	@echo "                   (make deploy REMOTE=admin@192.168.1.123)"

generate:
	xcodegen generate

build:
	./install.sh build

install:
	./install.sh install

status:
	./install.sh status

history:
	./install.sh history

uninstall:
	./install.sh uninstall

release:
	./release.sh

# Version and dmg path are read from the built app, so they resolve after
# `release` has produced it (recursive `=` on purpose).
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(BUILT_APP)/Contents/Info.plist" 2>/dev/null)
DMG     = $(DIST)/$(APP)-$(VERSION).dmg

# Install the disk image: mount, verify, copy the app to /Applications, register both
# extensions, open it once — the same flow the DMG's read-me describes. With REMOTE
# empty the dmg is installed on this Mac; otherwise it is shipped over and run there.
# The dmg path is baked in rather than passed as $1: ssh does not forward a trailing
# argument as the remote shell's $1 the way `sh -c '...' sh arg` does.
DMG_INSTALL = set -e; \
	DMG="$(1)"; VOL="/Volumes/$(APP)"; \
	PLUGINS="/Applications/$(APP).app/Contents/PlugIns"; \
	LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; \
	[ -d "$$VOL" ] && hdiutil detach "$$VOL" -force >/dev/null 2>&1 || true; \
	hdiutil attach "$$DMG" -nobrowse -readonly >/dev/null; \
	codesign --verify --strict "$$VOL/$(APP).app"; \
	rm -rf "/Applications/$(APP).app"; \
	ditto "$$VOL/$(APP).app" "/Applications/$(APP).app"; \
	"$$LS" -f "/Applications/$(APP).app"; \
	pluginkit -a "$$PLUGINS/EBookQLPreview.appex"; \
	pluginkit -a "$$PLUGINS/EBookQLThumbnail.appex"; \
	pluginkit -e use -i com.rocaltair.EBookQL.Preview; \
	pluginkit -e use -i com.rocaltair.EBookQL.Thumbnail; \
	open -a "/Applications/$(APP).app" 2>/dev/null || true; \
	hdiutil detach "$$VOL" >/dev/null; \
	rm -f "$$DMG"

deploy: release
	@test -f "$(DMG)" || { echo "deploy: $(DMG) not found" >&2; exit 1; }
ifneq ($(strip $(REMOTE)),)
	scp "$(DMG)" "$(REMOTE):/tmp/"
	ssh "$(REMOTE)" '$(call DMG_INSTALL,/tmp/$(APP)-$(VERSION).dmg)'
	@echo "deployed $(APP) $(VERSION) to $(REMOTE)"
else
	sh -c '$(call DMG_INSTALL,$(DMG))'
	@echo "deployed $(APP) $(VERSION) to this Mac"
endif

clean:
	rm -rf build dist
