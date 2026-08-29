APP_NAME = sqldoc
BUILD_DIR = .build/release
INSTALL_DIR ?= $(HOME)/.local/bin
APPS_DIR ?= /Applications

.PHONY: all build release test clean install install-cli install-app uninstall app bench config generate icons config-check

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

CONFIG_DB     = sqldoc.db
CONFIG_SRC    = config/schema.sql config/seed.sql
GENERATED_DIR = Sources/SQLDocCore/Generated
GENERATED_STAMP = .build/configgen.stamp

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

# Render the web icon set from config/assets/icon-master.png (see icon_target
# in sqldoc.db). The .icns is committed, not generated.
icons: $(CONFIG_DB)
	@sh scripts/gen-icons.sh --db $(CONFIG_DB)

# CI guard: regenerate from the database and fail if any output is stale.
config-check: generate
	@git diff --exit-code -- $(CONFIG_DB) config/ '$(GENERATED_DIR)/*.swift' || \
		(echo "config output is stale — run 'make generate' and commit"; exit 1)

build: generate
	swift build

release: generate
	swift build -c release

test: generate
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
	@echo "built bin/$(APP_NAME).app and bin/sqldoc"

# `make install` = the whole thing: CLI + app, from the latest build, and make
# Finder/Dock actually notice the new bundle.
install: install-cli install-app

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
	@echo "installed $(APPS_DIR)/$(APP_NAME).app (re-registered with Launch Services)"
	@echo "if Finder still shows the old icon: killall Dock Finder"

uninstall:
	@rm -f "$(INSTALL_DIR)/sqldoc"
	@[ -x $(LSREGISTER) ] && $(LSREGISTER) -u "$(APPS_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@rm -rf "$(APPS_DIR)/$(APP_NAME).app"
	@echo "removed $(INSTALL_DIR)/sqldoc and $(APPS_DIR)/$(APP_NAME).app"

bench: release
	@swift run sqldoc bench testdata/sample.db

clean:
	@rm -rf .build bin testdata/*.db
