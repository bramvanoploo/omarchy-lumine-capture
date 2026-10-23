# OmaLumineCapture

An [Omarchy](https://omarchy.org) status bar plugin for [LumineCapture](https://github.com/Netflate/LumineCapture), the fast, lightweight Wayland screenshot tool.

![LumineCapture Preview](preview.png)

## Features

- **Status bar icon** (camera). **Left-click** opens the quick capture mode & delay picker; **right-click** opens the configuration panel.
- **Automatic dependency install**: if `lumine-capture-bin` (AUR) is not installed, a confirmation dialog offers to install it. If the AUR helper `yay` is missing, it is explained and installed first. 
- **Global keybindings, one per capture mode**: ships with conflict-free defaults (`SUPER + \` Editor, `SUPER + ]` Full screen, `SUPER + [` Region, `SUPER + SHIFT + [` Region OCR) and lets you customize each shortcut in Settings.
  - **Live conflict detection & resolution**: if a chosen shortcut is already in use, you are warned and offered resolution paths.
  - **Removable shortcuts with automatic conflict restoration**: remove buttons are shown only for applied shortcuts, and removing a shortcut automatically resets any conflict resolution back to its original state.
  - **Reset offer when re-customizing**: if you change a keybinding that previously resolved a conflict, you are offered the option to restore the originally conflicting shortcut to its previous state.
- **Theme sync**: LumineCapture's colors follow the Omarchy theme you have selected, and are rewritten when the theme changes.

## Installation

```bash
omarchy plugin add https://github.com/bramvanoploo/omarchy-lumine-capture.git --enable
```

No manual setup required: clicking the bar icon will guide you through installing LumineCapture if it is not present.

## Uninstall

```bash
omarchy plugin remove bramvanoploo.omarchy-lumine-capture
```

## Development

The argument builder and its reader are plain JS, so the mapping between options and
flags is testable without a shell. The app's own defaults come from reading
`~/.config/LumineCapture/config.toml`, also plain JS:

```bash
node tests/launch-args.test.mjs
node tests/lumine-config.test.mjs
```

`preview.png` is rendered from the templates and assets in `preview/`:

```bash
./preview/generate-preview.sh
```

It renders `preview/template.html` with headless Chromium, versioned dynamically from `manifest.json`. The preview assets in `preview/` are real UI captures of OmaLumineCapture's configuration panel and mode picker. Pass `--capture` to re-capture live UI assets from Wayland.

## License

MIT © Bram van Oploo
