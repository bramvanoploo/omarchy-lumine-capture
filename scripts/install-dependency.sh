#!/bin/bash
# Installs yay (if missing) and lumine-capture-bin (AUR) for OmaLumineCapture,
# without further confirmation (--noconfirm), in a visible terminal.
set -uo pipefail

export YAY_DIR="${TMPDIR:-/tmp}/omalumine-yay-install-$$"

xdg-terminal-exec --app-id=org.omarchy.terminal --title="OmaLumineCapture Setup" -e bash -c '
  source omarchy-restart-gum 2>/dev/null || true
  omarchy-show-logo 2>/dev/null || true

  if ! command -v yay >/dev/null 2>&1; then
    echo -e "\033[1;34m::\033[0m yay not found — installing yay from the AUR (required for AUR packages)..."
    rm -rf -- "$YAY_DIR"
    git clone --depth 1 https://aur.archlinux.org/yay.git "$YAY_DIR"
    (
      cd "$YAY_DIR" && makepkg -si --noconfirm
    ) || echo -e "\033[0;31m::\033[0m yay installation failed"
    rm -rf -- "$YAY_DIR"
  fi

  if command -v yay >/dev/null 2>&1; then
    echo -e "\033[0;36m::\033[0m Installing lumine-capture-bin (AUR) with yay --noconfirm..."
    yay -S --noconfirm lumine-capture-bin
  fi

  echo
  if command -v omarchy-show-done >/dev/null 2>&1; then omarchy-show-done; fi
' || true

# Terminal closed: verify result and report back to the bar widget.
if pacman -Q lumine-capture-bin >/dev/null 2>&1; then
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell omalumine.bar installDone 2>/dev/null || true
  fi
else
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell omalumine.bar resetInstallState 2>/dev/null || true
  fi
fi
