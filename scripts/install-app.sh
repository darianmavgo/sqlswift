#!/bin/zsh
# ==============================================================================
# install-app.sh — Production Installer for SqlSwift.app
#
# Builds an optimized Release binary, packages a self-contained macOS bundle,
# installs it to /Applications/SqlSwift.app, and registers file associations.
#
# This installed application is completely isolated from the hot-reload
# development daemon and will NOT be overwritten or relaunched by dev work.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

APPS_DIR="${APPS_DIR:-/Applications}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
APP_NAME="SqlSwift"
BUNDLE_ID="com.mavgo.sqlswift"
TARGET_APP_PATH="$APPS_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

export CLANG_MODULE_CACHE_PATH="/tmp/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/swiftpm-cache"

echo "======================================================="
echo "        SqlSwift Production Application Installer       "
echo "======================================================="
echo "Repo:        $REPO_DIR"
echo "Destination: $TARGET_APP_PATH"
echo "CLI Dest:    $INSTALL_DIR/sqlswift"
echo "======================================================="

# 1. Ensure config and code generation are up to date
echo "\n[1/6] Generating build assets and configuration..."
if [ -f "config/schema.sql" ] && [ -f "config/seed.sql" ]; then
    rm -f sqldoc.db
    sqlite3 sqldoc.db < config/schema.sql
    sqlite3 sqldoc.db < config/seed.sql
fi

mkdir -p .build Sources/SQLDocCore/Generated
if [ -f "Sources/ConfigGen/main.swift" ] && [ -f "sqldoc.db" ]; then
    /usr/bin/swift run --package-path "$REPO_DIR" ConfigGen \
        --db sqldoc.db \
        --out Sources/SQLDocCore/Generated \
        --platform mac \
        --plist .build/Info.plist
fi

sh scripts/gen-buildinfo.sh Sources/SQLDocCore/Generated/BuildInfo.swift

# 2. Build Release Binaries (Optimized, no DEBUG flags, no hot-reload hooks)
echo "\n[2/6] Building optimized Release binaries (swift build -c release)..."
/usr/bin/swift build --package-path "$REPO_DIR" -c release --disable-sandbox

# 3. Assemble Standalone Application Bundle in Temp Stage
echo "\n[3/6] Packaging self-contained $APP_NAME.app bundle..."
STAGE_DIR="$(mktemp -d /tmp/sqlswift-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

APP_STAGE="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$APP_STAGE/Contents/MacOS"
mkdir -p "$APP_STAGE/Contents/Resources"

cp .build/release/SqlSwiftApp "$APP_STAGE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_STAGE/Contents/MacOS/$APP_NAME"

if [ -f ".build/Info.plist" ]; then
    cp .build/Info.plist "$APP_STAGE/Contents/Info.plist"
elif [ -f "bin/SqlSwift.app/Contents/Info.plist" ]; then
    cp bin/SqlSwift.app/Contents/Info.plist "$APP_STAGE/Contents/Info.plist"
fi

printf 'APPL????' > "$APP_STAGE/Contents/PkgInfo"

if [ -f "config/assets/AppIcon.icns" ]; then
    cp config/assets/AppIcon.icns "$APP_STAGE/Contents/Resources/AppIcon.icns"
fi

# Stamp git commit revision and version into Info.plist
REV=$(git rev-parse --short=9 HEAD 2>/dev/null || echo "release")
BASE_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_STAGE/Contents/Info.plist" 2>/dev/null || echo "3.1.0")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BASE_VER ($REV)" "$APP_STAGE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_STAGE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_STAGE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_STAGE/Contents/Info.plist" 2>/dev/null || true

# Code-sign the staged bundle
/usr/bin/codesign --force --sign - "$APP_STAGE" >/dev/null 2>&1 || true

# 4. Install into Target Directory
echo "\n[4/6] Installing to $TARGET_APP_PATH..."
mkdir -p "$APPS_DIR"
rm -rf "$TARGET_APP_PATH"
rm -rf "$APPS_DIR/sqldoc.app"  # Remove legacy name if present
cp -R "$APP_STAGE" "$TARGET_APP_PATH"
/usr/bin/touch "$TARGET_APP_PATH"
/usr/bin/codesign --force --sign - "$TARGET_APP_PATH" >/dev/null 2>&1 || true

# 5. Install CLI tool
echo "\n[5/6] Installing CLI tool..."
mkdir -p "$INSTALL_DIR"
cp .build/release/sqlswift "$INSTALL_DIR/sqlswift"
chmod +x "$INSTALL_DIR/sqlswift"
rm -f "$INSTALL_DIR/sqldoc"  # Clean up legacy CLI link if present

# Also install to /usr/local/bin if writable
if [ -w "/usr/local/bin" ]; then
    cp .build/release/sqlswift "/usr/local/bin/sqlswift"
    chmod +x "/usr/local/bin/sqlswift"
fi

# 6. Register with macOS Launch Services & Refresh File Associations
echo "\n[6/6] Registering file associations with macOS Launch Services..."
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET_APP_PATH" >/dev/null 2>&1 || true
fi

echo "\n======================================================="
echo "✓ Installation Complete!"
echo "  • App: $TARGET_APP_PATH"
echo "  • CLI: $INSTALL_DIR/sqlswift"
echo "  • Version: $BASE_VER ($REV)"
echo "  • Hot-reload isolation: ACTIVE (Release build; zero dev watcher hooks)"
echo "=======================================================\n"
