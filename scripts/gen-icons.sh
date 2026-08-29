#!/bin/sh
# gen-icons.sh — render every icon_target in sqldoc.db from its master SVG.
#
#   scripts/gen-icons.sh [--db sqldoc.db] [--sqldoc ../sqldoc]
#
# Reads:  identity 'icon.master' + the icon_target table
# Writes: each icon_target.path (into this repo, or the sibling sqldoc repo)
#
# Rasteriser: rsvg-convert (librsvg), resvg, or macOS `sips`.
# .icns needs `iconutil` (macOS) or `png2icns` (icnsutils).
# .ico   needs ImageMagick `convert`, or `icotool` (icoutils).
# A target whose tool is missing is skipped with a warning; the rest still run.

set -eu

db=sqldoc.db
sqldoc_repo=../sqldoc
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

if have rsvg-convert; then
  png() { rsvg-convert -w "$2" -h "$2" -o "$3" "$1"; }
elif have resvg; then
  png() { resvg -w "$2" -h "$2" "$1" "$3"; }
elif have sips; then
  png() { sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null; }
else
  warn "need rsvg-convert, resvg, or sips to rasterise SVG"; exit 1
fi

emit_icns() {  # $1 out.icns  $2 csv-sizes
  if ! have iconutil && ! have png2icns; then warn "skip $1 (no iconutil / png2icns)"; return 0; fi
  work=$(mktemp -d); set="$work/icon.iconset"; mkdir -p "$set"
  for s in $(echo "$2" | tr ',' ' '); do
    png "$master" "$s" "$set/icon_${s}x${s}.png"
    d=$((s * 2)); png "$master" "$d" "$set/icon_${s}x${s}@2x.png"
  done
  if have iconutil; then iconutil -c icns -o "$1" "$set"
  else png2icns "$1" "$set"/*.png >/dev/null; fi
  rm -rf "$work"
}

emit_ico() {  # $1 out.ico  $2 csv-sizes
  work=$(mktemp -d); files=""
  for s in $(echo "$2" | tr ',' ' '); do png "$master" "$s" "$work/$s.png"; files="$files $work/$s.png"; done
  if have magick;   then magick $files "$1"
  elif have convert; then convert $files "$1"
  elif have icotool; then icotool -c -o "$1" $files
  else warn "skip $1 (no ImageMagick / icotool)"; rm -rf "$work"; return 0; fi
  rm -rf "$work"
}

sqlite3 "$db" "SELECT repo||'|'||format||'|'||sizes||'|'||path FROM icon_target ORDER BY repo,path;" |
while IFS='|' read -r repo format sizes path; do
  case $repo in
    sqlswift) out=$path ;;
    sqldoc)   out=$sqldoc_repo/$path; [ -d "$sqldoc_repo" ] || { warn "skip $path (no $sqldoc_repo)"; continue; } ;;
    *) warn "skip unknown repo: $repo"; continue ;;
  esac
  mkdir -p "$(dirname "$out")"
  case $format in
    svg)  cp "$master" "$out"; echo "wrote $out" ;;
    png)  png "$master" "${sizes%%,*}" "$out"; echo "wrote $out" ;;
    ico)  emit_ico  "$out" "$sizes" && [ -f "$out" ] && echo "wrote $out" || true ;;
    icns) emit_icns "$out" "$sizes" && [ -f "$out" ] && echo "wrote $out" || true ;;
  esac
done

echo "gen-icons: done"
