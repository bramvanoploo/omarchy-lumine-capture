#!/bin/bash
# OmaLumineCapture - mirror the Omarchy theme into LumineCapture's config.
#
# The plugin polls the theme itself, so this hook is optional: installing it
# makes the sync immediate instead of within a few seconds.
#
#   omarchy hook install theme-set.d scripts/theme-set-hook.sh

THEME_SLUG="$1"
PLUGIN="$HOME/.config/omarchy/plugins/bramvanoploo.omarchy-lumine-capture"
SCRIPT="$PLUGIN/scripts/sync-theme.py"

[ -f "$SCRIPT" ] || exit 0
python3 "$SCRIPT" --check > /dev/null 2>&1 || true
