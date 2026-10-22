#!/usr/bin/env bash
# Render preview.png from docs/preview.html.
#
# Reads the accent and text colours from the active Omarchy theme, the version
# from manifest.json, then photographs docs/preview.html with headless Chromium.
#
#   scripts/render-preview.sh [output.png]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docs="$root/docs"
out="${1:-$root/preview.png}"
colors="${OMARCHY_THEME_COLORS:-$HOME/.local/state/omarchy/current/theme/colors.toml}"
for tool in magick chromium python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for shot in shot-panel.png shot-wallpaper.jpg; do
  [ -f "$docs/$shot" ] || { echo "missing docs/$shot" >&2; exit 1; }
done

eval "$(ACCENT_COLORS="$colors" MANIFEST="$root/manifest.json" python3 - <<'PY'
import json, os, re, tomllib
theme = tomllib.load(open(os.environ["ACCENT_COLORS"], "rb"))
version = json.load(open(os.environ["MANIFEST"]))["version"]
def rgb(h):
    h = h.lstrip("#")
    return f"{int(h[0:2],16)}, {int(h[2:4],16)}, {int(h[4:6],16)}"
keys = {"accent": "accent", "fg": "fg", "dark_fg": "dark_fg", "bg": "background", "dark_bg": "dark_bg"}
sh = []
for name, key in keys.items():
    value = theme.get(key, "#59b2d5" if name == "accent" else "#d8e9e9")
    sh.append(f'export {name.upper()}="{value}"')
    if name in ("accent", "fg"):
        sh.append(f'export {name.upper()}_RGB="{rgb(value)}"')
sh.append(f'export VERSION="{version}"')
print("\n".join(sh))
PY
)"

sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__ACCENT_RGB__|$ACCENT_RGB|g" -e "s|__ACCENT__|$ACCENT|g" \
    -e "s|__FG_RGB__|$FG_RGB|g" -e "s|__FG__|$FG|g" \
    -e "s|__DARK_FG__|$DARK_FG|g" -e "s|__BG__|$BG|g" -e "s|__DARK_BG__|$DARK_BG|g" \
    "$docs/preview.html" > "$docs/.preview.rendered.html"

chromium --headless=new --disable-gpu --hide-scrollbars --no-sandbox \
  --force-device-scale-factor=1 --window-size=1920,1080 \
  --screenshot="$out" "file://$docs/.preview.rendered.html" 2>/dev/null

[ -n "${KEEPCACHE:-}" ] || rm -f "$docs/.preview.rendered.html"
identify "$out"
