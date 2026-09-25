#!/bin/bash
# Renders the Claude RC menu bar glyph, a dot between two pairs of broadcast
# arcs "((•))", in the shared palette. Same pipeline as aws-session:
# SVG -> rsvg-convert -> sips DPI stamp so NSImage draws 18pt.
set -euo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/icons"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-rc-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/menubar"

render() { # $1=svg  $2=outfile  $3=px
  printf '%s' "$1" > "$WORK/_r.svg"
  rsvg-convert -w "$3" -h "$3" "$WORK/_r.svg" -o "$2"
}

# Arcs at r=6 and r=10.5 spanning ±45° either side of the centre (15,15).
GLYPH='<circle cx="15" cy="15" r="2.8" fill="currentColor"/><g fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M19.243,10.757 A6,6 0 0 1 19.243,19.243"/><path d="M10.757,10.757 A6,6 0 0 0 10.757,19.243"/><path d="M22.425,7.575 A10.5,10.5 0 0 1 22.425,22.425"/><path d="M7.575,7.575 A10.5,10.5 0 0 0 7.575,22.425"/></g>'

menu() { # $1=name $2=colour
  render "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\" viewBox=\"0 0 30 30\"><g style=\"color:$2\">${GLYPH}</g></svg>" "$OUT/menubar/$1.png" 60
}

menu green "#30D158"
menu amber "#FF9F0A"
menu red   "#FF453A"
menu grey  "#8E8E93"

# SwiftBar/NSImage sizes raster images by embedded DPI (points = px*72/dpi):
# 60px @ 240dpi = 18pt, matching the other plugins.
for f in "$OUT"/menubar/*.png; do sips -s dpiWidth 240 -s dpiHeight 240 "$f" >/dev/null 2>&1; done

echo "done"
