#!/bin/sh
# gen-icons.sh — render every icon_target in sqldoc.db from its master SVG.
#
#   scripts/gen-icons.sh [--db sqldoc.db] [--sqldoc ../sqldoc]
#
# Reads:  identity 'icon.master'  + the icon_target table
# Writes: each icon_target.path (into this repo, or the sibling sqldoc repo)
#
# Needs one SVG rasteriser: rsvg-convert (librsvg), resvg, or `sips` (macOS,
# limited). macOS `.icns` assembly uses `iconutil`.

set -eu

db=sqldoc.db
sqldoc_repo=../sqldoc
while [ $# -gt 0 ]; do
  case $1 in
    --db)     db=$2; shift 2 ;;
    --sqldoc) sqldoc_repo=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

q() { sqlite3 "$db" "$1"; }

master=$(q "SELECT value FROM identity WHERE key='icon.master' AND platform='all';")
[ -f "$master" ] || { echo "master icon not found: $master" >&2; exit 1; }

if command -v rsvg-convert >/dev/null 2>&1; then
  png() { rsvg-convert -w "$2" -h "$2" -o "$3" "$1"; }
elif command -v resvg >/dev/null 2>&1; then
  png() { resvg -w "$2" -h "$2" "$1" "$3"; }
elif command -v sips >/dev/null 2>&1; then
  png() { sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null; }
else
  echo "need rsvg-convert, resvg, or sips to rasterise SVG" >&2; exit 1
fi

emit_icns() {  # $1 out.icns  $2 csv-sizes
  set=$(mktemp -d)/icon.iconset; mkdir -p "$set"
  for s in $(echo "$2" | tr ',' ' '); do
    png "$master" "$s"        "$set/icon_${s}x${s}.png"
    d=$((s * 2)); png "$master" "$d" "$set/icon_${s}x${s}@2x.png"
  done
  if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns -o "$1" "$set"
  else
    # portable-ish fallback: png2icns from icnsutils
    png2icns "$1" "$set"/*.png
  fi
  rm -rf "$(dirname "$set")"
}

emit_ico() {  # $1 out.ico  $2 csv-sizes
  tmp=$(mktemp -d); files=""
  for s in $(echo "$2" | tr ',' ' '); do png "$master" "$s" "$tmp/$s.png"; files="$files $tmp/$s.png"; done
  # shellcheck disable=SC2086
  convert $files "$1"   # ImageMagick
  rm -rf "$tmp"
}

q "SELECT repo||'|'||format||'|'||sizes||'|'||path FROM icon_target ORDER BY repo,path;" |
while IFS='|' read -r repo format sizes path; do
  case $repo in
    sqlswift) out=$path ;;
    sqldoc)   out=$sqldoc_repo/$path ;;
    *) echo "skip unknown repo: $repo" >&2; continue ;;
  esac
  mkdir -p "$(dirname "$out")"
  case $format in
    svg)  cp "$master" "$out" ;;
    png)  png "$master" "${sizes%%,*}" "$out" ;;
    ico)  emit_ico "$out" "$sizes" ;;
    icns) emit_icns "$out" "$sizes" ;;
  esac
  echo "wrote $out"
done
