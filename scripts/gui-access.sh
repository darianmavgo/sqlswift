#!/bin/zsh
# Gives Claude eyes on the dev app, step by step, and proves each step worked.
#
#   scripts/gui-access.sh check [folder-or-db]   run every step below, stop at the first failure
#   scripts/gui-access.sh snap  [cmd ...]        run UI commands, snapshot the window, print the PNG path
#   scripts/gui-access.sh quit                   close the dev app
#
# How it works: the debug app has a `snapshot` UI command (Sources/SQLDocApp/Utilities/UIScreenshot.swift)
# that draws its own window into bin/ui-snapshot.png. It reads nothing from the screen, so it needs NO
# Screen Recording / Accessibility permission. Claude then reads the PNG with its image-capable Read tool.
#
# Needs: Command Line Tools (swift). Touches only bin/ and the folder you pass (read-only).
# `check` starts with a preflight of the Mac settings that can get in the way, and says which are
# required (FAIL stops the script) and which are optional (WARN, with the exact clicks to fix it).

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
APP="bin/SqlSwift.app"
BIN="$APP/Contents/MacOS/SqlSwift"
CMD="bin/ui-command.txt"
STATE="bin/ui-state.json"
PNG="bin/ui-snapshot.png"

step() { print -P "%F{blue}==>%f $*"; }
ok()   { print -P "    %F{green}PASS%f $*"; }
fail() { print -P "    %F{red}FAIL%f $*"; shift; for l in "$@"; do print "         $l"; done; exit 1; }

preflight() {
  step "0/5 Preflight: does this Mac have what we need?"
  # Required: a Swift toolchain.
  command -v swift >/dev/null || fail "swift not found" "Install the Command Line Tools:  xcode-select --install"
  ok "swift: $(swift --version 2>&1 | head -1 | sed 's/Apple //')"
  ok "macOS $(sw_vers -productVersion) ($(uname -m))"

  # Required: an unlocked, awake GUI session, or the app has nothing to draw into.
  local probe="${TMPDIR:-/tmp}/gui-access-probe.swift"
  cat > "$probe" <<'SWIFT'
import CoreGraphics
import Foundation
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("session", d.isEmpty ? "none" : "ok")
print("locked", (d["CGSSessionScreenIsLocked"] as? Bool) == true ? "yes" : "no")
print("onconsole", (d["kCGSSessionOnConsoleKey"] as? Bool) == false ? "no" : "yes")
print("screenrec", CGPreflightScreenCaptureAccess() ? "granted" : "denied")
SWIFT
  local out; out=$(swift "$probe" 2>/dev/null); rm -f "$probe"
  [ -n "$out" ] || fail "could not run the settings probe" "Try: swift --version"
  [[ "$out" == *"session none"* ]] && fail "no GUI login session" "This script must run from a Terminal inside your logged-in desktop, not over plain ssh."
  [[ "$out" == *"locked yes"* ]]   && fail "screen is locked" "Unlock the Mac; a locked session draws nothing."
  [[ "$out" == *"onconsole no"* ]] && fail "another user's session is in front" "Switch back to your own user (Fast User Switching)."
  ok "GUI session is unlocked and on the console"

  # Optional: only matters for external capture (screencapture), which the in-app snapshot does not use.
  if [[ "$out" == *"screenrec granted"* ]]; then
    ok "Screen Recording is allowed for this terminal (optional; the in-app snapshot does not need it)"
  else
    print -P "    %F{yellow}WARN%f Screen Recording is not allowed for this terminal."
    print "         Not needed: snapshots are drawn by the app itself. Only matters if you want"
    print "         screencapture-style grabs of other windows. To allow it anyway:"
    print "           System Settings > Privacy & Security > Screen & System Audio Recording"
    print "           > switch on the terminal app you run Claude Code in > restart that terminal."
  fi

  # Optional: display sleep would stall drawing mid-run.
  local sleepmin; sleepmin=$(pmset -g 2>/dev/null | awk '/displaysleep/{print $2}')
  [ -n "$sleepmin" ] && [ "$sleepmin" != "0" ] && [ "$sleepmin" -lt 5 ] \
    && print -P "    %F{yellow}WARN%f display sleeps after ${sleepmin} min; a sleeping display can blank a snapshot (caffeinate -d keeps it awake)"
  return 0
}

stage_app() {
  step "1/5 Build the debug app (incremental)"
  swift build --disable-sandbox >/tmp/gui-access-build.log 2>&1 \
    || fail "swift build failed" "see /tmp/gui-access-build.log"
  ok "built"

  step "2/5 Stage $APP (same layout the hot-reload script uses)"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/debug/SqlSwiftApp "$BIN.tmp" && mv -f "$BIN.tmp" "$BIN"
  [ -f .build/Info.plist ] && cp .build/Info.plist "$APP/Contents/Info.plist" \
    && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mavgo.sqlswift.dev" "$APP/Contents/Info.plist" 2>/dev/null
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  /usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1
  [ -x "$BIN" ] || fail "no executable at $BIN"
  ok "staged"
}

is_running() { pgrep -f "SqlSwift.app/Contents/MacOS/SqlSwift" >/dev/null; }

wait_for() { # wait_for <seconds> <test-command...>
  local n=$(( $1 * 5 )); shift
  for _ in $(seq 1 $n); do eval "$@" && return 0; sleep 0.2; done
  return 1
}

launch() {
  step "3/5 Launch the dev app"
  is_running && pkill -f "SqlSwift.app/Contents/MacOS/SqlSwift" && sleep 1
  rm -f "$STATE" "$PNG" "$CMD"
  local target="${1:-$REPO/testdata}"
  [ -e "$target" ] || target="$REPO"
  open -g -n "$APP" --args "$target"
  wait_for 15 "[ -s $STATE ]" || fail "app did not write $STATE within 15s" \
    "The app only logs when it runs from <repo>/bin/SqlSwift.app in a DEBUG build." \
    "Check: log stream --predicate 'subsystem == \"com.mavgo.sqlswift\"'"
  ok "running, state file present"
}

send() { printf '%s\n' "$1" > "$CMD"; wait_for 5 "[ ! -e $CMD ]" || fail "command not consumed: $1"; sleep 1.2; }

snapshot() {
  rm -f "$PNG"
  send "snapshot"
  wait_for 5 "[ -s $PNG ]" || fail "no $PNG after the snapshot command" \
    "Look for '[snapshot]' lines in bin/ui.log ('no window' means the window is not on screen:" \
    "unminimise it / switch to its Space and rerun)."
  local w h sz
  w=$(sips -g pixelWidth  "$PNG" 2>/dev/null | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$PNG" 2>/dev/null | awk '/pixelHeight/{print $2}')
  sz=$(stat -f %z "$PNG")
  # A blank render compresses to a few KB; real UI is far bigger.
  [ "${sz:-0}" -gt 20000 ] || fail "snapshot looks blank (${w}x${h}, ${sz} bytes)" \
    "SwiftUI sometimes needs the window frontmost: click the app once, then rerun 'snap'."
  ok "$PNG  ${w}x${h}  ${sz} bytes"
}

case "${1:-check}" in
  check)
    preflight
    stage_app
    launch "${2:-}"
    step "4/5 Drive the app through the command file"
    send "blur"
    grep -q '"banquetURL"' "$STATE" && ok "ui-state.json is live ($(grep -m1 '"banquetURL"' $STATE | sed 's/^ *//'))" || fail "state has no banquetURL"
    step "5/5 Take a snapshot Claude can read"
    snapshot
    print -P "\n%F{green}Done.%f Claude can now: scripts/gui-access.sh snap <ui-commands…>  then Read $REPO/$PNG"
    ;;
  snap)
    is_running || fail "dev app is not running" "run: scripts/gui-access.sh check"
    shift
    for c in "$@"; do send "$c"; done
    snapshot
    print "$REPO/$PNG"
    ;;
  quit)
    pkill -f "SqlSwift.app/Contents/MacOS/SqlSwift" && echo "closed" || echo "not running"
    ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac
