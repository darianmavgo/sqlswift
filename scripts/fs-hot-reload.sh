#!/bin/zsh
# Hot reload for FileStudio (bin/FileStudio.app).
# Watches the app's Swift sources, Package.swift, config/filestudio and the Go worker
# (../filestudio), rebuilds what changed (debug), restages the bundle and touches the stamp.
# The running dev app sees the stamp, saves its place (section, folder, a running backup),
# stops its worker cleanly and relaunches into the new build.
set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1
GO_DIR="$REPO_DIR/../filestudio"
# outside ~/Documents: reading there from the app needs a privacy grant (see FSLog)
DEV_DIR="$HOME/Library/Caches/com.mavgo.filestudio.dev"
mkdir -p "$DEV_DIR"
STAMP="$DEV_DIR/.fs-hot-reload.stamp"

swift_sig() {
    /usr/bin/find Sources/FileStudioApp Sources/FileStudioKit Sources/SQLDocCore config/filestudio Package.swift -type f \
        \( -name "*.swift" -o -name "*.plist" \) -exec /usr/bin/stat -f "%m %N" {} + 2>/dev/null | /usr/bin/shasum
}
go_sig() {
    [ -d "$GO_DIR" ] || { echo none; return; }
    /usr/bin/find "$GO_DIR/pkg" "$GO_DIR/cmd" "$GO_DIR/go.mod" -type f \( -name "*.go" -o -name "go.mod" \) ! -name "*_test.go" \
        -exec /usr/bin/stat -f "%m %N" {} + 2>/dev/null | /usr/bin/shasum
}

build_and_stage() {
    local t0=$(/bin/date +%s)
    if [ "$1" = "go" ] || [ ! -x "$GO_DIR/bin/filestudio" ]; then
        echo "[fs-hot] building the Go worker..."
        (cd "$GO_DIR" && go build -o bin/filestudio ./cmd/filestudio) || { echo "[fs-hot] ✗ Go build failed — waiting for next save..."; return 1; }
    fi
    echo "[fs-hot] compiling..."
    local out="$DEV_DIR/build.log"
    if ! /usr/bin/swift build --package-path "$REPO_DIR" --disable-sandbox --product FileStudio >"$out" 2>&1; then
        # just the compiler's file:line: error lines, without colour codes
        sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -E '\.swift:[0-9]+:[0-9]+: error:' | sort -u | head -20
        echo "[fs-hot] ✗ Swift build failed — waiting for next save... (full log: $out)"
        return 1
    fi
    make -s fs-stage >/dev/null || { echo "[fs-hot] ✗ staging failed"; return 1; }
    /usr/bin/touch "$STAMP"
    echo "[fs-hot] ✓ reloaded bin/FileStudio.app in $(( $(/bin/date +%s) - t0 ))s ($(/bin/date '+%H:%M:%S'))"
}

echo "[fs-hot] initial build..."
build_and_stage go
if ! /usr/bin/pgrep -f "$REPO_DIR/bin/FileStudio.app/Contents/MacOS/FileStudio" >/dev/null 2>&1; then
    echo "[fs-hot] opening bin/FileStudio.app"
    /usr/bin/open -n "$REPO_DIR/bin/FileStudio.app"
else
    echo "[fs-hot] dev app already running — it will reload itself"
fi
[ "${1:-}" = "--once" ] && exit 0

LAST_SWIFT="$(swift_sig)"; LAST_GO="$(go_sig)"
echo "[fs-hot] watching Sources/FileStudio*, config/filestudio and ../filestudio (Ctrl+C to stop)"
while true; do
    /bin/sleep 0.6
    CS="$(swift_sig)"; CG="$(go_sig)"
    if [ "$CS" != "$LAST_SWIFT" ] || [ "$CG" != "$LAST_GO" ]; then
        kind=swift; [ "$CG" != "$LAST_GO" ] && kind=go
        LAST_SWIFT="$CS"; LAST_GO="$CG"
        build_and_stage $kind
        LAST_SWIFT="$(swift_sig)"; LAST_GO="$(go_sig)"
    fi
done
