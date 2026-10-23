# OmaLumineCapture Preview Generator

This directory contains the assets and templates used to generate the high-resolution repository preview banner (`preview.png`).

## Files

- `template.html`: 1920x1080 banner template inspired by OmaGuake and OMapple previews.
- `generate-preview.sh`: Shell script that populates the version, coordinates assets, and renders the banner via headless Chromium.
- `settings_capture.png`: High-resolution capture of the OmaLumineCapture configuration panel.
- `modepanel_capture.png`: High-resolution capture of the capture mode quick-picker popout.

## How to Regenerate

To generate `preview.png` in the repository root:

```bash
./preview/generate-preview.sh
```

To re-capture live UI assets from Wayland before rendering:

```bash
./preview/generate-preview.sh --capture
```
