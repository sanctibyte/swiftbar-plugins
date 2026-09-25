#!/bin/bash
# Renders the AWS session icons: flat glyph in the menu bar, rounded tile with
# a corner badge in the dropdown. Re-run after editing; SwiftBar picks the PNGs up on next refresh.
set -euo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/icons"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aws-session-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/menubar" "$OUT/drop" "$WORK"

render() { # $1=svg  $2=outfile  $3=w  $4=h
  printf '%s' "$1" > "$WORK/_r.svg"
  rsvg-convert -w "$3" -h "$4" "$WORK/_r.svg" -o "$2"
}

# A cloud built from overlapping opaque primitives — reliable across renderers.
CLOUD='<g id="cloud"><circle cx="-5.5" cy="1" r="4.2" fill="currentColor"/><circle cx="6" cy="1.8" r="3.4" fill="currentColor"/><circle cx="0.3" cy="-2.6" r="6.2" fill="currentColor"/><rect x="-9.7" y="1" width="19.4" height="5.2" rx="2.6" fill="currentColor"/></g>'

G="#30D158"; Gd="#248A3D"   # active
R="#FF453A"                 # expired
N="#8E8E93"                 # never logged in

# --- menu bar: one flat cloud, coloured by state ----------------------------
menu() { # $1=outfile $2=colour
  local svg="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\" viewBox=\"0 0 30 30\"><defs>${CLOUD}</defs><g style=\"color:$2\" transform=\"translate(15,15.8) scale(1.35)\"><use href=\"#cloud\"/></g></svg>"
  render "$svg" "$1" 60 60
}

menu "$OUT/menubar/active.png"  "$G"
menu "$OUT/menubar/expired.png" "$R"
menu "$OUT/menubar/none.png"    "$N"

# --- dropdown: green tile, white cloud, corner badge with a play triangle ----
TILE_DEFS="<defs>${CLOUD}<g id=\"play\"><path d=\"M-5,-6 L-5,6 L7,0 Z\" fill=\"#ffffff\"/></g><clipPath id=\"tile\"><rect width=\"72\" height=\"72\" rx=\"18\"/></clipPath></defs>"

tile() { # $1=outfile $2=size
  local svg="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$2\" height=\"$2\" viewBox=\"0 0 72 72\">${TILE_DEFS}<rect width=\"72\" height=\"72\" rx=\"18\" fill=\"${G}\"/><g style=\"color:#ffffff\" transform=\"translate(34,34) scale(1.9)\"><use href=\"#cloud\"/></g><g clip-path=\"url(#tile)\"><circle cx=\"72\" cy=\"72\" r=\"34\" fill=\"${Gd}\"/></g><use href=\"#play\" x=\"57\" y=\"57\"/></svg>"
  render "$svg" "$1" "$2" "$2"
}

tile "$OUT/drop/login.png" 88

# SwiftBar/NSImage sizes raster images by embedded DPI (points = px*72/dpi).
# 18pt in both places.
for f in "$OUT"/menubar/*.png; do sips -s dpiWidth 240 -s dpiHeight 240 "$f" >/dev/null 2>&1; done
for f in "$OUT"/drop/*.png;    do sips -s dpiWidth 352 -s dpiHeight 352 "$f" >/dev/null 2>&1; done

echo "done"
