#!/bin/bash
# Builds the distributable single-file plugin: renders the icons, runs the
# test suite against the template, then inlines the icons as base64 constants.
#
#   ./build.sh            -> dist/claude-rc.5s.sh
#   ./build.sh --install  -> also copies it over the installed plugin
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/dist/claude-rc.5s.sh"
PLUGINS="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/.config/swiftbar/plugins")}"

mkdir -p "$SRC/dist"
"$SRC/gen-icons.sh" >/dev/null
"$SRC/test.sh"

python3 - "$SRC/plugin.template.sh" "$SRC/icons/menubar" "$OUT" <<'PY'
import base64, pathlib, sys

template, icons, out = (pathlib.Path(p) for p in sys.argv[1:4])
text = template.read_text()

for colour in ("green", "amber", "red", "grey"):
    name = f"__ICON_{colour.upper()}__"
    if name not in text:
        sys.exit(f"placeholder {name} missing from template")
    text = text.replace(name, base64.b64encode((icons / f"{colour}.png").read_bytes()).decode())

if "__ICON_" in text:
    sys.exit("unsubstituted placeholder left in output")

out.write_text(text)
PY

chmod +x "$OUT"
bash -n "$OUT"
printf 'built %s (%s KB)\n' "$OUT" "$(( $(wc -c < "$OUT") / 1024 ))"

if [[ "${1:-}" == "--install" ]]; then
  cp "$OUT" "$PLUGINS/claude-rc.5s.sh"
  chmod +x "$PLUGINS/claude-rc.5s.sh"
  echo "installed to $PLUGINS/claude-rc.5s.sh"
fi
