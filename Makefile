APP_NAME = sqldoc
BUILD_DIR = .build/release
INSTALL_DIR ?= $(HOME)/.local/bin
APPS_DIR ?= /Applications

.PHONY: all build release test clean install install-cli install-app uninstall app bench config generate icons config-check buildinfo lsclean lslist

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE_ID  = com.mavgo.sqldoc

CONFIG_DB     = sqldoc.db
CONFIG_SRC    = config/schema.sql config/seed.sql
GENERATED_DIR = Sources/SQLDocCore/Generated
GENERATED_STAMP = .build/configgen.stamp
BUILDINFO       = $(GENERATED_DIR)/BuildInfo.swift

all: build

# Rebuild the authoritative build-time config database from its SQL source.
$(CONFIG_DB): $(CONFIG_SRC)
	@rm -f $(CONFIG_DB)
	@sqlite3 $(CONFIG_DB) < config/schema.sql
	@sqlite3 $(CONFIG_DB) < config/seed.sql
	@echo "Built $(CONFIG_DB) from config/*.sql"

config: $(CONFIG_DB)

# Read sqldoc.db and emit typed Swift into Sources/SQLDocCore/Generated/.
# This is the step that pulls the config database into the build: everything
# under $(GENERATED_DIR) is compiled as part of SQLDocCore.
$(GENERATED_STAMP): $(CONFIG_DB) Sources/ConfigGen/main.swift
	@mkdir -p .build
	swift run ConfigGen --db $(CONFIG_DB) --out $(GENERATED_DIR) --platform mac --plist .build/Info.plist
	@touch $(GENERATED_STAMP)

generate: $(GENERATED_STAMP)

# Stamp the current git revision into BuildInfo.swift so the app can show which
# build it is. Always runs; the script only rewrites the file when it changes.
buildinfo:
	@sh scripts/gen-buildinfo.sh $(BUILDINFO)

# Render the web icon set from config/assets/icon-master.png (see icon_target
# in sqldoc.db). The .icns is committed, not generated.
icons: $(CONFIG_DB)
	@sh scripts/gen-icons.sh --db $(CONFIG_DB)

# CI guard: regenerate from the database and fail if any output is stale.
# BuildInfo.swift is excluded — it is stamped from git, not from the config DB.
config-check: generate
	@git diff --exit-code -- $(CONFIG_DB) config/ '$(GENERATED_DIR)/*.swift' ':!$(BUILDINFO)' || \
		(echo "config output is stale — run 'make generate' and commit"; exit 1)

build: generate buildinfo
	swift build

release: generate buildinfo
	swift build -c release

test: generate buildinfo
	swift run SQLDocTestsRunner

# Assemble bin/sqldoc.app from a fresh release build.
#   .build/Info.plist          rendered by ConfigGen from sqldoc.db (make generate)
#   config/assets/AppIcon.icns  committed (copy of sqldoc's tangerine .icns)
# `release` is phony, so `swift build -c release` runs every time — `app` and
# everything downstream of it always reflect the current source.
app: release
	@rm -rf bin/$(APP_NAME).app
	@mkdir -p bin/$(APP_NAME).app/Contents/MacOS bin/$(APP_NAME).app/Contents/Resources
	@cp $(BUILD_DIR)/SQLDocApp bin/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/sqldoc bin/sqldoc
	@cp .build/Info.plist bin/$(APP_NAME).app/Contents/Info.plist
	@printf 'APPL????' > bin/$(APP_NAME).app/Contents/PkgInfo
	@cp config/assets/AppIcon.icns bin/$(APP_NAME).app/Contents/Resources/AppIcon.icns
	@# Stamp the git revision into the bundle so Finder "Get Info" / About shows it.
	@rev=$$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown); \
	 base=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" bin/$(APP_NAME).app/Contents/Info.plist 2>/dev/null || echo 0); \
	 /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$base ($$rev)" bin/$(APP_NAME).app/Contents/Info.plist 2>/dev/null || true
	@echo "built bin/$(APP_NAME).app and bin/sqldoc ($$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown))"

# `make install` = the whole thing: CLI + app, from the latest build, then purge
# stale "Open With" entries so only the freshly installed bundle is offered.
install: install-cli install-app lsclean

install-cli: app
	@mkdir -p $(INSTALL_DIR)
	@cp bin/sqldoc $(INSTALL_DIR)/sqldoc
	@echo "installed $(INSTALL_DIR)/sqldoc"

install-app: app
	@rm -rf "$(APPS_DIR)/$(APP_NAME).app"
	@cp -R bin/$(APP_NAME).app "$(APPS_DIR)/$(APP_NAME).app"
	@touch "$(APPS_DIR)/$(APP_NAME).app"
	@codesign --force --sign - "$(APPS_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@[ -x $(LSREGISTER) ] && $(LSREGISTER) -f "$(APPS_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@echo "installed $(APPS_DIR)/$(APP_NAME).app"

# List every app bundle on this Mac that claims the sqldoc identity or name —
# useful for spotting a leftover copy from the original (Go) sqldoc repo.
lslist:
	@echo "App bundles claiming '$(BUNDLE_ID)':"
	@mdfind "kMDItemCFBundleIdentifier == '$(BUNDLE_ID)'" 2>/dev/null | sed 's/^/  /' || true
	@mdfind "kMDItemCFBundleIdentifier == '$(BUNDLE_ID).viewer'" 2>/dev/null | sed 's/^/  /' || true
	@echo "App bundles named 'sqldoc':"
	@mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == 'sqldoc.app'" 2>/dev/null | sed 's/^/  /' || true

# Purge stale / duplicate "Open With" entries: rebuild the Launch Services
# database, then unregister every sqldoc.app that isn't the one in $(APPS_DIR)
# (old build artefacts, a checkout of the original sqldoc repo, etc.). Bundles
# still on disk can be re-found later by Spotlight — delete them to be rid of
# them for good; `make lslist` shows where they are.
lsclean:
	@echo "→ rebuilding Launch Services database…"
	@[ -x $(LSREGISTER) ] && $(LSREGISTER) -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
	@[ -d "$(APPS_DIR)/$(APP_NAME).app" ] && [ -x $(LSREGISTER) ] && $(LSREGISTER) -f "$(APPS_DIR)/$(APP_NAME).app" >/dev/null 2>&1 || true
	@echo "→ unregistering other copies…"
	@for b in $$(mdfind "kMDItemCFBundleIdentifier == '$(BUNDLE_ID)'" 2>/dev/null); do \
		if [ "$$b" != "$(APPS_DIR)/$(APP_NAME).app" ]; then \
			echo "   - $$b"; \
			[ -x $(LSREGISTER) ] && $(LSREGISTER) -u "$$b" >/dev/null 2>&1 || true; \
		fi; \
	done
	@killall Finder Dock >/dev/null 2>&1 || true
	@echo "✓ done. Only $(APPS_DIR)/$(APP_NAME).app is registered now."
	@echo "  (delete the copies listed above so Spotlight can't re-add them.)"

uninstall:
	@rm -f "$(INSTALL_DIR)/sqldoc"
	@[ -x $(LSREGISTER) ] && $(LSREGISTER) -u "$(APPS_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@rm -rf "$(APPS_DIR)/$(APP_NAME).app"
	@[ -x $(LSREGISTER) ] && $(LSREGISTER) -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
	@killall Finder Dock >/dev/null 2>&1 || true
	@echo "removed $(INSTALL_DIR)/sqldoc and $(APPS_DIR)/$(APP_NAME).app (Launch Services rebuilt)"

bench: release
	@swift run sqldoc bench testdata/sample.db

clean:
	@rm -rf .build bin testdata/*.db
