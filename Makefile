APP_NAME = SqlSwift
CLI_NAME = sqlswift
BUILD_DIR = .build/release
INSTALL_DIR ?= $(HOME)/.local/bin
APPS_DIR ?= /Applications

export CLANG_MODULE_CACHE_PATH ?= /tmp/clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE ?= /tmp/swiftpm-cache

SWIFT ?= /usr/bin/swift
SWIFT_FLAGS ?= --disable-sandbox

.PHONY: fs-worker fs-build fs-app fs-hot fs-stage fs-watch fs-test all build release test clean install install-cli install-app uninstall app bench config generate icons config-check buildinfo lsclean lslist uilog uistate ui-test ui-e2e conformance-db conformance-check conformance-shots conformance-guide conformance-deck

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE_ID  = com.mavgo.sqlswift

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
	$(SWIFT) run $(SWIFT_FLAGS) ConfigGen --db $(CONFIG_DB) --out $(GENERATED_DIR) --platform mac --plist .build/Info.plist
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
	@git diff --exit-code -- $(CONFIG_DB) config/ '$(GENERATED_DIR)/*.swift' ':!$(BUILDINFO)' ':!config/conformance.sql' || \
		(echo "config output is stale — run 'make generate' and commit"; exit 1)

build: generate buildinfo
	$(SWIFT) build $(SWIFT_FLAGS)

release: generate buildinfo
	$(SWIFT) build $(SWIFT_FLAGS) -c release

test: generate buildinfo
	$(SWIFT) run $(SWIFT_FLAGS) SQLDocTestsRunner

# Assemble bin/sqldoc.app from a fresh release build.
#   .build/Info.plist          rendered by ConfigGen from sqldoc.db (make generate)
#   config/assets/AppIcon.icns  committed (copy of sqldoc's tangerine .icns)
# `release` is phony, so `swift build -c release` runs every time — `app` and
# everything downstream of it always reflect the current source.
app: release
	@rm -rf bin/$(APP_NAME).app bin/sqldoc.app bin/sqldoc
	@mkdir -p bin/$(APP_NAME).app/Contents/MacOS bin/$(APP_NAME).app/Contents/Resources
	@cp $(BUILD_DIR)/SqlSwiftApp bin/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/$(CLI_NAME) bin/$(CLI_NAME)
	@cp .build/Info.plist bin/$(APP_NAME).app/Contents/Info.plist
	@printf 'APPL????' > bin/$(APP_NAME).app/Contents/PkgInfo
	@cp config/assets/AppIcon.icns bin/$(APP_NAME).app/Contents/Resources/AppIcon.icns
	@# Stamp the git revision into the bundle so Finder "Get Info" / About shows it.
	@rev=$$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown); \
	 base=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" bin/$(APP_NAME).app/Contents/Info.plist 2>/dev/null || echo 0); \
	 /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$base ($$rev)" bin/$(APP_NAME).app/Contents/Info.plist 2>/dev/null || true
	@echo "built bin/$(APP_NAME).app and bin/$(CLI_NAME) ($$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown))"

# `make install` = full release build & installation via scripts/install-app.sh
# ---- FileStudio (backup-to-R2 + reclaim UI over a filestudio db; see Sources/FileStudioApp) ----
FS_APP    = bin/FileStudio.app
FS_GO_BIN = ../filestudio/bin/filestudio

# fs_bundle <swift build dir>: assemble $(FS_APP) from that build, with the Go worker inside.
define fs_bundle
	@rm -rf $(FS_APP)
	@mkdir -p $(FS_APP)/Contents/MacOS $(FS_APP)/Contents/Resources
	@cp $(1)/FileStudio $(FS_APP)/Contents/MacOS/FileStudio
	@cp config/filestudio/Info.plist $(FS_APP)/Contents/Info.plist
	@printf 'APPL????' > $(FS_APP)/Contents/PkgInfo
	@cp config/assets/AppIcon.icns $(FS_APP)/Contents/Resources/AppIcon.icns
	@if [ -x $(FS_GO_BIN) ]; then cp $(FS_GO_BIN) $(FS_APP)/Contents/Resources/filestudio; \
	 else echo "note: $(FS_GO_BIN) not built; the app will look for filestudio on PATH (go build -o bin/filestudio ./cmd/filestudio)"; fi
	@/usr/bin/codesign --force --deep --sign - $(FS_APP) >/dev/null 2>&1 || true
endef

fs-worker:
	@if [ -d ../filestudio ]; then cd ../filestudio && go build -o bin/filestudio ./cmd/filestudio && echo "built $(FS_GO_BIN)"; fi

fs-build: generate buildinfo fs-worker
	$(SWIFT) build $(SWIFT_FLAGS) --product FileStudio

fs-app: generate buildinfo fs-worker
	$(SWIFT) build $(SWIFT_FLAGS) -c release --product FileStudio
	$(call fs_bundle,.build/release)
	@echo "built $(FS_APP)"

# Debug bundle at bin/FileStudio.app: writes bin/fs-ui.log (main-thread stalls) and fs-ui-state.txt,
# and runs commands from bin/fs-ui-command.txt. Rebuilds and relaunches.
fs-hot: fs-build
	@pkill -x FileStudio 2>/dev/null; sleep 0.5; true
	$(call fs_bundle,.build/debug)
	@open $(FS_APP)
	@echo "running $(FS_APP); tail -f bin/fs-ui.log"

# Stage the debug bundle without launching (used by the hot-reload watcher).
fs-stage:
	$(call fs_bundle,.build/debug)

# Hot reload: rebuild on every save of the app's Swift or the Go worker; the running app relaunches
# itself in place (same section, folder, and a running backup continues).
fs-watch:
	@zsh scripts/fs-hot-reload.sh

fs-test: fs-worker
	$(SWIFT) test $(SWIFT_FLAGS) --filter FileStudioKitTests

install:
	@sh scripts/install-app.sh
	@$(MAKE) lsclean

install-cli: app
	@mkdir -p $(INSTALL_DIR)
	@cp bin/$(CLI_NAME) $(INSTALL_DIR)/$(CLI_NAME)
	@echo "installed $(INSTALL_DIR)/$(CLI_NAME)"

install-app:
	@sh scripts/install-app.sh

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
	@$(SWIFT) run $(SWIFT_FLAGS) -c release sqlswift bench testdata/sample.db

watch hot:
	@sh scripts/hot-reload.sh

# Dev-app UI feedback loop: event stream + current-state snapshot (see CLAUDE.md).
uilog:
	@tail -n 200 -f bin/ui.log

uistate:
	@cat bin/ui-state.json

# Banquet URL <-> grid tests. Both read Tests/SQLDocAppTests/banquet-ui-cases.json.
#   ui-test: headless Swift Testing over the app's view models (no window needed)
#   ui-e2e:  replays the same cases in the running dev app (`make hot` first)
ui-test:
	swift test

ui-e2e:
	python3 scripts/ui-e2e.py $(ARGS)

# Banquet conformance ledger: one row per standard rule, with status, proof and demo recipe.
# config/conformance.sql is the source; the .db is committed so sqldoc can open it.
CONFORMANCE_DB = docs/conformance/conformance.db

$(CONFORMANCE_DB): config/conformance.sql
	@mkdir -p docs/conformance
	@rm -f $(CONFORMANCE_DB)
	@sqlite3 $(CONFORMANCE_DB) < config/conformance.sql
	@echo "Built $(CONFORMANCE_DB) from config/conformance.sql"

conformance-db: $(CONFORMANCE_DB)

conformance-check: $(CONFORMANCE_DB)
	@$(SWIFT) run $(SWIFT_FLAGS) ConformanceGen check
	@$(SWIFT) run $(SWIFT_FLAGS) ConformanceGen scorecard

# Replay every shot recipe in the running dev app (`make hot` first) into docs/conformance/img/.
conformance-shots: $(CONFORMANCE_DB)
	@$(SWIFT) run $(SWIFT_FLAGS) ConformanceGen shoot $(ARGS)

# The training page, docs/conformance/guide.html.
conformance-guide: $(CONFORMANCE_DB)
	@$(SWIFT) run $(SWIFT_FLAGS) ConformanceGen guide

# The same material as a slide deck (reveal.js from a CDN), docs/conformance/deck.html.
conformance-deck: $(CONFORMANCE_DB)
	@$(SWIFT) run $(SWIFT_FLAGS) ConformanceGen deck

clean:
	@rm -rf .build bin testdata/*.db
