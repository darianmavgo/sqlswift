APP_NAME = sqldoc
BUILD_DIR = .build/release
INSTALL_DIR ?= $(HOME)/.local/bin
APPS_DIR ?= /Applications

.PHONY: all build release test clean install app bench config generate icons config-check

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

# Render every platform icon from config/assets/icon.svg (see icon_target in sqldoc.db).
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
	swift test

# The bundle's Info.plist and icon both come from sqldoc.db:
#   .build/Info.plist        rendered by ConfigGen (make generate)
#   config/assets/AppIcon.icns  rendered by scripts/gen-icons.sh (make icons)
app: release
	@mkdir -p bin/$(APP_NAME).app/Contents/MacOS bin/$(APP_NAME).app/Contents/Resources
	@cp $(BUILD_DIR)/SQLDocApp bin/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/sqldoc bin/sqldoc
	@cp .build/Info.plist bin/$(APP_NAME).app/Contents/Info.plist
	@printf 'APPL????' > bin/$(APP_NAME).app/Contents/PkgInfo
	@[ -f config/assets/AppIcon.icns ] && cp config/assets/AppIcon.icns bin/$(APP_NAME).app/Contents/Resources/AppIcon.icns || echo "note: no AppIcon.icns (install rsvg-convert/resvg, then 'make icons')"
	@echo "Built bin/$(APP_NAME).app and bin/sqldoc"

install: app
	@mkdir -p $(INSTALL_DIR)
	@cp bin/sqldoc $(INSTALL_DIR)/sqldoc
	@echo "Installed sqldoc CLI to $(INSTALL_DIR)/sqldoc"

install-app: app
	@rm -rf $(APPS_DIR)/$(APP_NAME).app
	@cp -R bin/$(APP_NAME).app $(APPS_DIR)/$(APP_NAME).app
	@echo "Installed $(APP_NAME).app to $(APPS_DIR)"

bench: release
	@swift run sqldoc bench testdata/sample.db

clean:
	@rm -rf .build bin testdata/*.db
