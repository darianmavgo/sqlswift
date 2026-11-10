#!/bin/zsh
# Hot-reload watcher for SqlSwift (SqlSwift.app).
# Watches Sources/ and config/ for changes, runs incremental debug `swift build`,
# updates bin/SqlSwift.app, and touches bin/.hot-reload.stamp so the running app
# hot-swaps in-place while preserving open database/table/folder state.

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

export CLANG_MODULE_CACHE_PATH="/tmp/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/swiftpm-cache"

compute_signature() {
    /usr/bin/find Sources Tests config Package.swift -type f \( -name "*.swift" -o -name "*.sql" \) -exec /usr/bin/stat -f "%m %N" {} + 2>/dev/null | /usr/bin/shasum
}

build_and_stage() {
    echo "[hot-reload] Compiling incremental changes..."
    local t0=$(/bin/date +%s)
    if /usr/bin/swift build --package-path "$REPO_DIR" --disable-sandbox; then
        rm -rf bin/sqldoc.app bin/sqldoc
        mkdir -p bin/SqlSwift.app/Contents/MacOS bin/SqlSwift.app/Contents/Resources
        cp .build/debug/SqlSwiftApp bin/SqlSwift.app/Contents/MacOS/SqlSwift.tmp
        mv -f bin/SqlSwift.app/Contents/MacOS/SqlSwift.tmp bin/SqlSwift.app/Contents/MacOS/SqlSwift
        cp .build/debug/sqlswift bin/sqlswift.tmp
        mv -f bin/sqlswift.tmp bin/sqlswift
        if [ -f .build/Info.plist ]; then
            cp .build/Info.plist bin/SqlSwift.app/Contents/Info.plist
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mavgo.sqlswift.dev" bin/SqlSwift.app/Contents/Info.plist 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.mavgo.sqlswift.dev" bin/SqlSwift.app/Contents/Info.plist 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Set :CFBundleName SqlSwift (Dev)" bin/SqlSwift.app/Contents/Info.plist 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SqlSwift (Dev)" bin/SqlSwift.app/Contents/Info.plist 2>/dev/null || true
        fi
        printf 'APPL????' > bin/SqlSwift.app/Contents/PkgInfo
        [ -f config/assets/AppIcon.icns ] && cp config/assets/AppIcon.icns bin/SqlSwift.app/Contents/Resources/AppIcon.icns
        /usr/bin/codesign --force --sign - bin/SqlSwift.app >/dev/null 2>&1 || true
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f bin/SqlSwift.app >/dev/null 2>&1 || true
        /usr/bin/touch bin/.hot-reload.stamp
        local t1=$(/bin/date +%s)
        echo "[hot-reload] ✓ Hot-reloaded bin/SqlSwift.app (com.mavgo.sqlswift.dev) in $((t1 - t0))s ($(/bin/date '+%H:%M:%S'))"
    else
        echo "[hot-reload] ✗ Build failed — waiting for next save..."
    fi
}

# Launch the dev app after the first build unless one is already running
# (it then hot-swaps). --no-open skips this; --open forces a new instance.
SHOULD_OPEN=auto
ONCE_ONLY=0
for arg in "$@"; do
    if [[ "$arg" == "--open" || "$arg" == "-o" ]]; then
        SHOULD_OPEN=1
    elif [[ "$arg" == "--no-open" ]]; then
        SHOULD_OPEN=0
    elif [[ "$arg" == "--once" || "$arg" == "-1" ]]; then
        ONCE_ONLY=1
    fi
done

echo "[hot-reload] Initial build & stage in $REPO_DIR..."
build_and_stage

if [ "$SHOULD_OPEN" = "auto" ]; then
    if /usr/bin/pgrep -f "$REPO_DIR/bin/SqlSwift.app/Contents/MacOS/SqlSwift" >/dev/null 2>&1; then
        echo "[hot-reload] Dev app already running — it will hot-swap."
        SHOULD_OPEN=0
    else
        SHOULD_OPEN=1
    fi
fi

if [ "$SHOULD_OPEN" -eq 1 ]; then
    echo "[hot-reload] Opening development instance (open -n bin/SqlSwift.app)..."
    /usr/bin/open -n "$REPO_DIR/bin/SqlSwift.app"
fi

if [ "$ONCE_ONLY" -eq 1 ]; then
    exit 0
fi

LAST_SIG="$(compute_signature)"
echo "[hot-reload] Watching Sources/ and config/ for edits..."

while true; do
    /bin/sleep 0.7
    CUR_SIG="$(compute_signature)"
    if [ "$CUR_SIG" != "$LAST_SIG" ]; then
        LAST_SIG="$CUR_SIG"
        build_and_stage
        LAST_SIG="$(compute_signature)"
    fi
done
