# OmaLumineCapture

An [Omarchy](https://omarchy.org) status bar plugin for [LumineCapture](https://github.com/Netflate/LumineCapture), the fast, lightweight Wayland screenshot tool.

## Installation

```bash
omarchy plugin add <this-repo-git-url> --enable
```

No manual setup required: clicking the bar icon will guide you through installing LumineCapture if it is not present.

## Features

- **Status bar icon** (camera). **Left-click** starts a capture; **right-click** opens the configuration panel.
- **Automatic dependency install**: if `lumine-capture-bin` (AUR) is not installed, a confirmation dialog offers to install it. If the AUR helper `yay` is missing, it is explained and installed first. Installation runs in a terminal with `--noconfirm`.
- **Global keybinding** (default `SUPER + SHIFT + S`, temporary default) with conflict checking against Hyprland bindings: on conflict, pick a suggested free chord or take over (the conflicting binding is disabled with a comment).
- **Full configuration panel**: every option of `~/.config/LumineCapture/config.toml` is auto-generated as collapsible sections with typed controls (toggles, steppers, text/color fields). Changes save immediately; "Restore defaults" resets via `lumine-capture --print-default-config`.

## Uninstall

```bash
omarchy plugin remove bramvanoploo.omarchy-lumine-capture
```

Then remove the `-- BEGIN bramvanoploo.omarchy-lumine-capture` block from `~/.config/hypr/bindings.lua` if a keybinding was applied.

## License

MIT © Bram van Oploo
