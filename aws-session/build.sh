#!/bin/bash
# Builds the distributable single-file plugin: renders the icons, then inlines
# them into plugin.template.sh as base64 constants.
#
#   ./build.sh            -> dist/aws-session.5s.sh
#   ./build.sh --install  -> also copies it over the installed plugin
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/dist/aws-session.5s.sh"
PLUGINS="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/.config/swiftbar/plugins")}"

mkdir -p "$SRC/dist"
"$SRC/gen-icons.sh" >/dev/null

python3 - "$SRC/plugin.template.sh" "$SRC/icons" "$OUT" <<'PY'
import base64, pathlib, sys

template, icons, out = (pathlib.Path(p) for p in sys.argv[1:4])
text = template.read_text()

for name, path in {
    "__ICON_ACTIVE__":  icons / "menubar/active.png",
    "__ICON_EXPIRED__": icons / "menubar/expired.png",
    "__ICON_NONE__":    icons / "menubar/none.png",
    "__ICON_LOGIN__":   icons / "drop/login.png",
}.items():
    if name not in text:
        sys.exit(f"placeholder {name} missing from template")
    text = text.replace(name, base64.b64encode(path.read_bytes()).decode())

if "__ICON_" in text:
    sys.exit("unsubstituted placeholder left in output")

out.write_text(text)
PY

chmod +x "$OUT"
bash -n "$OUT"
printf 'built %s (%s KB)\n' "$OUT" "$(( $(wc -c < "$OUT") / 1024 ))"

if [[ "${1:-}" == "--install" ]]; then
  cp "$OUT" "$PLUGINS/aws-session.5s.sh"
  chmod +x "$PLUGINS/aws-session.5s.sh"
  echo "installed to $PLUGINS/aws-session.5s.sh"
fi
