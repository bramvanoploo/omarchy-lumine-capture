#!/usr/bin/env python3
"""Mirror the active Omarchy theme into LumineCapture's [theme] colors.

Omarchy keeps its theme colors in ~/.local/state/omarchy/current/theme/colors.toml
(regenerated whenever the user runs `omarchy theme set`). LumineCapture reads its
appearance from ~/.config/LumineCapture/config.toml. This script maps the Omarchy
colors onto the color keys LumineCapture understands and writes them into the
[theme] section, in place, so every other line of the user's config - comments
included - stays untouched. Only the key lines it changes lose an inline comment.

Usage:
  sync-theme.py            sync now (force)
  sync-theme.py --check    sync only if the Omarchy theme changed (for pollers/hooks)
  sync-theme.py --print    print the computed mapping, write nothing
"""

import sys
import os
import re
import json
import hashlib
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))

OMARCHY_THEME_DIR = HOME / ".local/state/omarchy/current/theme"
COLORS_TOML = OMARCHY_THEME_DIR / "colors.toml"
SHELL_TOML = OMARCHY_THEME_DIR / "shell.toml"
THEME_NAME_FILE = HOME / ".local/state/omarchy/current/theme.name"

LC_CONFIG = HOME / ".config/LumineCapture/config.toml"
STATE_FILE = Path(__file__).resolve().parent.parent / ".theme-sync.json"

MARKER = "# Colors below are synced from the Omarchy theme by OmaLumineCapture"

# The color keys of LumineCapture's [theme] section that map onto Omarchy colors.
# Sizes, radii and font metrics are left alone: they are the app's own look.
COLOR_KEYS = [
    "background", "foreground", "muted", "hover", "accent", "on_accent",
    "border", "border_on_light", "field", "track", "caret", "text_selection",
]


# ---------- tiny TOML reader (flat key = "value" lines, sections tracked) ----------

def read_toml(path):
    """Return {section: {key: value_string}}. Comments and blanks are skipped."""
    out = {}
    section = ""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return out
    return parse_toml_text(raw)


def parse_toml_text(raw):
    """Return {section: {key: value_string}} from a TOML string."""
    out = {}
    section = ""
    for line in (raw or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("["):
            close_idx = stripped.find("]")
            section = (stripped[1:close_idx] if close_idx > 0 else stripped.strip("[]")).strip()
            out.setdefault(section, {})
            continue
        m = re.match(r"([A-Za-z0-9_.\-]+)\s*=\s*(.+)", stripped)
        if not m:
            continue
        value = m.group(2).strip()
        if value.startswith('"'):
            end_q = value.find('"', 1)
            if end_q > 0:
                value = value[1:end_q]
        elif value.startswith("'"):
            end_q = value.find("'", 1)
            if end_q > 0:
                value = value[1:end_q]
        else:
            value = re.sub(r"\s*#.*$", "", value).strip()
        out.setdefault(section, {})[m.group(1)] = value
    return out


# ---------- color helpers (sRGB) ----------

def normalize_hex(value):
    """'#rgb' / '#rrggbb' / '#rrggbbaa' -> (r, g, b, a) floats."""
    if not value:
        return None
    h = value.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) not in (6, 8):
        return None
    try:
        r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
        a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    except ValueError:
        return None
    return (r, g, b, a)


def to_hex(rgb, fallback="#000000"):
    if not rgb:
        return fallback
    r, g, b, a = rgb
    h = "#" + "".join(f"{max(0, min(255, round(c * 255))):02x}" for c in (r, g, b))
    if a < 0.999:
        h += f"{round(a * 255):02x}"
    return h


def mix(color_a, color_b, ratio):
    """Blend two colors: ratio 0 returns color_a, 1 returns color_b."""
    a, b = normalize_hex(color_a), normalize_hex(color_b)
    if not a and not b:
        return "#000000"
    if not a:
        return to_hex(b)
    if not b:
        return to_hex(a)
    return to_hex(tuple(a[i] + (b[i] - a[i]) * ratio for i in range(4)))


def with_alpha(color, alpha):
    rgb = normalize_hex(color)
    if not rgb:
        return color
    return to_hex((rgb[0], rgb[1], rgb[2], alpha))


def luminance(color):
    rgb = normalize_hex(color)
    if not rgb:
        return 0.0
    r, g, b = rgb[:3]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


# ---------- mapping ----------

def read_bar_surface_alpha():
    """The bar's own background alpha from shell.toml, if the theme ships one."""
    data = read_toml(SHELL_TOML)
    bar = data.get("bar", {})
    raw = bar.get("background-alpha")
    try:
        alpha = float(raw)
    except (TypeError, ValueError):
        return 0.95
    return max(0.55, min(1.0, alpha))


def build_colors():
    """Map Omarchy theme colors onto LumineCapture's [theme] color keys."""
    theme = read_toml(COLORS_TOML)
    c = theme.get("", {})
    bg = c.get("bg") or c.get("background") or "#1e1e2e"
    fg = c.get("fg") or c.get("foreground") or "#cdd6f4"
    accent = c.get("accent") or c.get("selection") or "#89b4fa"
    lighter_bg = c.get("lighter_bg") or mix(bg, fg, 0.08)
    dark_fg = c.get("dark_fg") or mix(fg, bg, 0.35)
    border_tone = c.get("muted") or mix(bg, fg, 0.22)
    cursor = c.get("cursor") or accent
    on_accent = c.get("selection_foreground") or bg

    # The bar surface alpha keeps the panel blending with the wallpaper, the way
    # Omarchy's own bar does; light themes get a touch more opacity for legibility.
    alpha = read_bar_surface_alpha()
    if luminance(bg) > 0.5:
        alpha = max(alpha, 0.97)

    return {
        # The app's panel background: the theme background, semi-transparent.
        "background": with_alpha(bg, alpha),
        "foreground": to_hex(normalize_hex(fg)),
        # Dimmed text, e.g. hints and secondary labels.
        "muted": to_hex(normalize_hex(dark_fg)),
        # Raised surface for hover: a lifted background, slightly tinted by fg.
        "hover": mix(lighter_bg, fg, 0.10),
        "accent": to_hex(normalize_hex(accent)),
        # Text and icons drawn on top of an accent fill.
        "on_accent": to_hex(normalize_hex(on_accent)),
        "border": to_hex(normalize_hex(border_tone)),
        # Faint hairline used when LumineCapture sits on a light background.
        "border_on_light": with_alpha(bg, 0.22),
        # Input field background: a surface barely lifted off the panel.
        "field": mix(lighter_bg, bg, 0.15),
        # Unfilled part of progress bars.
        "track": mix(bg, fg, 0.18),
        "caret": to_hex(normalize_hex(cursor)),
        "text_selection": with_alpha(accent, 0.43),
    }


# ---------- config.toml patching (comment preserving) ----------

def theme_section_bounds(lines):
    """Index range of the top-level [theme] section, (start, end), or None."""
    for i, line in enumerate(lines):
        if line.strip() == "[theme]":
            end = len(lines)
            for j in range(i + 1, len(lines)):
                s = lines[j].strip()
                if s.startswith("["):
                    end = j
                    break
            return (i, end)
    return None


def patch(text, colors, theme_name):
    """Return text with [theme] color keys set to the mapped colors."""
    lines = text.split("\n")
    bounds = theme_section_bounds(lines)

    if bounds is None:
        add = ["", "[theme]", MARKER]
        add += [f'{k} = "{colors[k]}"' for k in COLOR_KEYS]
        body = text.rstrip("\n")
        return (body + "\n" if body else "") + "\n".join(add) + "\n"

    start, end = bounds
    marker = f"{MARKER}"
    if theme_name:
        marker += f": {theme_name}"
    # Keep one marker line right under the header, refreshed in place.
    if start + 1 < end and lines[start + 1].strip().startswith("# Colors below are synced"):
        lines[start + 1] = marker
        insert_at = start + 2
    else:
        lines.insert(start + 1, marker)
        end += 1
        insert_at = start + 2

    for key in COLOR_KEYS:
        value = f'{key} = "{colors[key]}"'
        found = None
        for j in range(insert_at, end):
            if re.match(r"\s*" + re.escape(key) + r"\s*=", lines[j]):
                found = j
                break
        if found is not None:
            lines[found] = value
        else:
            lines.insert(end, value)
            end += 1
    return "\n".join(lines)


def read_theme_name():
    try:
        return THEME_NAME_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def theme_fingerprint():
    h = hashlib.sha256()
    for path in (COLORS_TOML, SHELL_TOML, THEME_NAME_FILE):
        h.update(path.name.encode())
        try:
            h.update(path.read_bytes())
        except OSError:
            h.update(b"<missing>")
    return h.hexdigest()


def write_state(fingerprint, colors, theme_name):
    try:
        STATE_FILE.write_text(json.dumps({
            "fingerprint": fingerprint,
            "theme": theme_name,
            "colors": colors,
        }, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def read_state():
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def current_colors_in_config(text):
    """Color values LumineCapture's config currently holds, for idempotency."""
    return parse_toml_text(text).get("theme", {})


def do_sync(force):
    theme_name = read_theme_name()
    colors = build_colors()
    fingerprint = theme_fingerprint()

    if not normalize_hex(colors["background"]):
        return {"success": False, "error": "Could not read Omarchy theme colors."}

    exists = LC_CONFIG.exists()
    try:
        text = LC_CONFIG.read_text(encoding="utf-8") if exists else ""
    except OSError:
        text = ""
    have = current_colors_in_config(text)
    matches = all(have.get(k) == v for k, v in colors.items())

    state = read_state()
    if not force and state.get("fingerprint") == fingerprint and matches:
        return {"success": True, "changed": False, "theme": theme_name}

    if not exists:
        LC_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        text = "# LumineCapture config, created by OmaLumineCapture theme sync.\n"

    patched = patch(text, colors, theme_name)
    try:
        temp_cfg = LC_CONFIG.with_suffix(f".tmp.{os.getpid()}")
        temp_cfg.write_text(patched, encoding="utf-8")
        temp_cfg.replace(LC_CONFIG)
    except OSError:
        LC_CONFIG.write_text(patched, encoding="utf-8")
    write_state(fingerprint, colors, theme_name)
    return {"success": True, "changed": True, "theme": theme_name, "colors": colors}


def main():
    args = sys.argv[1:]
    mode = args[0] if args else "--force"

    if mode == "--print":
        print(json.dumps({"theme": read_theme_name(), "colors": build_colors()}, indent=2))
        return 0

    res = do_sync(force=(mode != "--check"))
    print(json.dumps(res))
    return 0 if res.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
