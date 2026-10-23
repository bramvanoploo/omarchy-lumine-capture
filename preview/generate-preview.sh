#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="$PROJECT_DIR/preview.png"
MANIFEST_FILE="$PROJECT_DIR/manifest.json"

CAPTURE_NEW=0
if [[ "${1:-}" == "--capture" ]]; then
  CAPTURE_NEW=1
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Error: manifest.json not found at $MANIFEST_FILE" >&2
  exit 1
fi

VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))['version'])" 2>/dev/null || echo "0.5.0")
echo "==> Preparing preview banner for OmaLumineCapture v$VERSION..."

# Capture live screenshots if requested or missing
if (( CAPTURE_NEW )) || [[ ! -f "$SCRIPT_DIR/settings_capture.png" ]] || [[ ! -f "$SCRIPT_DIR/modepanel_capture.png" ]]; then
  echo "==> Capturing live assets via Wayland (grim & omarchy-shell)..."

  if ! command -v grim >/dev/null 2>&1 || ! command -v omarchy-shell >/dev/null 2>&1; then
    echo "Warning: grim or omarchy-shell not available. Using existing component images." >&2
  else
    # 1. Capture settings panel
    omarchy-shell omalumine.bar openSettings || true
    sleep 1
    grim /tmp/_full_settings.png
    omarchy-shell omalumine.bar closeSettings || true
    if [[ -f /tmp/_full_settings.png ]]; then
      python3 -c '
from PIL import Image
im = Image.open("/tmp/_full_settings.png")
card = im.crop((966, 478, 2490, 1682))
card.save("'"$SCRIPT_DIR"'/settings_capture.png")
'
      rm -f /tmp/_full_settings.png
    fi
  fi
fi

# Verify component images exist
if [[ ! -f "$SCRIPT_DIR/settings_capture.png" ]] || [[ ! -f "$SCRIPT_DIR/modepanel_capture.png" ]]; then
  echo "Error: Required asset images missing in $SCRIPT_DIR" >&2
  exit 1
fi

RENDER_HTML="$SCRIPT_DIR/index.rendered.html"
sed "s/{{VERSION}}/$VERSION/g" "$SCRIPT_DIR/template.html" > "$RENDER_HTML"

echo "==> Rendering 1920x1080 preview banner via Chromium headless..."
chromium \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=1920,1080 \
  --screenshot="$OUTPUT_FILE" \
  "file://$RENDER_HTML" 2>/dev/null

rm -f "$RENDER_HTML"

if command -v identify >/dev/null 2>&1; then
  identify "$OUTPUT_FILE"
fi

echo "==> Successfully created $OUTPUT_FILE for v$VERSION!"
