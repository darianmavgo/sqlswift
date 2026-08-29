#!/bin/sh
# gen-icons.sh — render every icon_target in sqldoc.db from the master image.
#
#   scripts/gen-icons.sh [--db sqldoc.db] [--sqldoc PATH]
#
# Reads:  identity 'icon.master' (a 1024px PNG, or an SVG) + the icon_target table
# Writes: each icon_target.path (this repo; the Go repo only with --sqldoc PATH)
#
# Scaler:  sips (macOS), or ImageMagick (magick/convert); rsvg-convert/resvg if
#          the master is an SVG. .ico also needs ImageMagick or icotool.
# A target whose tool is missing is skipped with a warning; the rest still run.
#
# The two .icns files are handled outside this script: config/assets/AppIcon.icns
# is committed verbatim (a copy of sqldoc/packaging/macos/sqldoc.icns).

set -eu

db=sqldoc.db
sqldoc_repo=""
while [ $# -gt 0 ]; do
  case $1 in
    --db)     db=$2; shift 2 ;;
    --sqldoc) sqldoc_repo=$2; shift 2 ;;
    *) echo "gen-icons: unknown option: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
warn() { printf 'gen-icons: %s\n' "$*" >&2; }

master=$(sqlite3 "$db" "SELECT value FROM identity WHERE key='icon.master' AND platform='all';")
[ -f "$master" ] || { warn "master icon not found: $master"; exit 1; }

case $master in
  *.svg|*.SVG)
    if   have rsvg-convert; then png() { rsvg-convert -w "$2" -h "$2" -o "$3" "$1"; }
    elif have resvg;        then png() { resvg -w "$2" -h "$2" "$1" "$3"; }
    elif have sips;         then png() { sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null; }
    else warn "need rsvg-convert, resvg, or sips for an SVG master"; exit 1; fi ;;
  *)
    if   have sips;    then png() { sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null; }
    elif have magick;  then png() { magick "$1" -resize "${2}x${2}" "$3"; }
    elif have convert; then png() { convert "$1" -resize "${2}x${2}" "$3"; }
    else warn "need sips or ImageMagick to scale the master"; exit 1; fi ;;
esac

emit_ico() {  # $1 out.ico  $2 csv-sizes
  work=$(mktemp -d); files=""
  for s in $(echo "$2" | tr ',' ' '); do png "$master" "$s" "$work/$s.png"; files="$files $work/$s.png"; done
  if   have magick;  then magick $files "$1"
  elif have convert; then convert $files "$1"
  elif have icotool; then icotool -c -o "$1" $files
  else warn "skip $1 (no ImageMagick / icotool)"; rm -rf "$work"; return 0; fi
  rm -rf "$work"
}

sqlite3 "$db" "SELECT repo||'|'||format||'|'||sizes||'|'||path FROM icon_target ORDER BY repo,path;" |
while IFS='|' read -r repo format sizes path; do
  case $repo in
    sqlswift) out=$path ;;
    sqldoc)   [ -n "$sqldoc_repo" ] && [ -d "$sqldoc_repo" ] || { warn "skip $path (pass --sqldoc PATH to render the Go repo)"; continue; }
              out=$sqldoc_repo/$path ;;
    *) warn "skip unknown repo: $repo"; continue ;;
  esac
  mkdir -p "$(dirname "$out")"
  case $format in
    svg)  cp "$master" "$out"; echo "wrote $out" ;;
    png)  png "$master" "${sizes%%,*}" "$out"; echo "wrote $out" ;;
    ico)  emit_ico "$out" "$sizes" && [ -f "$out" ] && echo "wrote $out" || true ;;
    *)    warn "skip $out (unsupported format: $format)" ;;
  esac
done

echo "gen-icons: done"
