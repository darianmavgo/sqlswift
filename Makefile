APP_NAME = sqldoc
BUILD_DIR = .build/release
INSTALL_DIR ?= $(HOME)/.local/bin
APPS_DIR ?= /Applications

.PHONY: all build release test clean install app bench

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test

app: release
	@mkdir -p bin
	@rm -rf bin/$(APP_NAME).app
	@mkdir -p bin/$(APP_NAME).app/Contents/MacOS
	@mkdir -p bin/$(APP_NAME).app/Contents/Resources
	@cp $(BUILD_DIR)/SQLDocApp bin/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/sqldoc bin/sqldoc
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > bin/$(APP_NAME).app/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '<plist version="1.0">' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '<dict>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundleIdentifier</key><string>com.darian.sqldoc</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundleName</key><string>$(APP_NAME)</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundlePackageType</key><string>APPL</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundleShortVersionString</key><string>0.3.0</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>LSMinimumSystemVersion</key><string>14.0</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <key>CFBundleDocumentTypes</key>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    <array>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '        <dict>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '            <key>CFBundleTypeName</key><string>SQLite Database</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '            <key>CFBundleTypeRole</key><string>Viewer</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '            <key>LSHandlerRank</key><string>Alternate</string>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '            <key>CFBundleTypeExtensions</key>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '            <array><string>db</string><string>sqlite</string><string>sqlite3</string><string>db3</string></array>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '        </dict>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '    </array>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '</dict>' >> bin/$(APP_NAME).app/Contents/Info.plist
	@echo '</plist>' >> bin/$(APP_NAME).app/Contents/Info.plist
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
