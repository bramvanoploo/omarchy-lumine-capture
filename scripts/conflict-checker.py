#!/usr/bin/env python3
"""
Keybinding management and conflict resolution service for OmaLumineCapture.

Actions:
  check-key <chord> [mode]
  apply-key <json_payload>
  remove-key <json_payload>
  sync <json_payload>
  status
"""

import sys
import os
import re
import json
import shutil
import subprocess
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
HYPR_DIR = HOME / ".config" / "hypr"
BINDINGS_LUA = HYPR_DIR / "bindings.lua"
OMARCHY_DIR = Path("/usr/share/omarchy/default/hypr/bindings")
PLUGIN_ID = "bramvanoploo.omarchy-lumine-capture"
SETTINGS_FILE = Path(__file__).resolve().parent.parent / "settings.json"

MODE_ORDER = ["", "full", "window", "region", "region-ocr"]
MODE_LABELS = {
    "": "Editor",
    "full": "Full screen",
    "window": "Window",
    "region": "Region",
    "region-ocr": "Region OCR"
}

MOD_MAP = {
    "super": 64, "mod4": 64, "logo": 64, "win": 64,
    "ctrl": 4, "control": 4,
    "alt": 8, "mod1": 8,
    "shift": 1
}
MOD_CANONICAL = {
    "super": "SUPER", "mod4": "SUPER", "logo": "SUPER", "win": "SUPER",
    "ctrl": "CTRL", "control": "CTRL",
    "alt": "ALT", "mod1": "ALT",
    "shift": "SHIFT"
}
MOD_ORDER = {"SUPER": 0, "CTRL": 1, "ALT": 2, "SHIFT": 3}

KEYCODE_TO_KEY = {
    "CODE:10": "1",
    "CODE:11": "2",
    "CODE:12": "3",
    "CODE:13": "4",
    "CODE:14": "5",
    "CODE:15": "6",
    "CODE:16": "7",
    "CODE:17": "8",
    "CODE:18": "9",
    "CODE:19": "0",
    "CODE:20": "MINUS",
    "CODE:21": "EQUAL",
    "CODE:34": "BRACKETLEFT",
    "CODE:35": "BRACKETRIGHT",
    "CODE:47": "SEMICOLON",
    "CODE:48": "APOSTROPHE",
    "CODE:49": "GRAVE",
    "CODE:51": "BACKSLASH",
    "CODE:59": "COMMA",
    "CODE:60": "PERIOD",
    "CODE:61": "SLASH",
}
KEY_TO_KEYCODE = {v: k for k, v in KEYCODE_TO_KEY.items()}

KEY_ALIASES = {
    "BACKQUOTE": "GRAVE", "BACKTICK": "GRAVE", "ESC": "ESCAPE", "ENTER": "RETURN",
    "DEL": "DELETE", "PGUP": "PAGEUP", "PGDN": "PAGEDOWN", "PRIOR": "PAGEUP", "NEXT": "PAGEDOWN",
    "SYSRQ": "PRINT",
    # Bracket & symbol aliases
    "]": "BRACKETRIGHT", "[": "BRACKETLEFT",
    "}": "BRACKETRIGHT", "{": "BRACKETLEFT",
    "-": "MINUS", "=": "EQUAL",
    ";": "SEMICOLON", "'": "APOSTROPHE", '"': "APOSTROPHE",
    ",": "COMMA", ".": "PERIOD",
    "/": "SLASH", "\\": "BACKSLASH",
    "`": "GRAVE",
}
KEY_ALIASES.update(KEYCODE_TO_KEY)

SAFE_KEY_EXTRA = {
    "SPACE", "GRAVE", "RETURN", "TAB", "ESCAPE", "BACKSPACE", "INSERT", "DELETE",
    "HOME", "END", "PAGEUP", "PAGEDOWN", "MINUS", "EQUAL", "COMMA", "PERIOD",
    "SLASH", "SEMICOLON", "APOSTROPHE", "BACKSLASH", "BRACKETLEFT", "BRACKETRIGHT",
    "LEFT", "RIGHT", "UP", "DOWN", "PRINT", "PAUSE",
}


def is_safe_key(key):
    if not key:
        return False
    if key in SAFE_KEY_EXTRA:
        return True
    if re.fullmatch(r"[A-Z0-9]", key):
        return True
    if re.fullmatch(r"F(?:[1-9]|1[0-9]|2[0-4])", key):
        return True
    return False


def normalize_key_chord(chord_str):
    if not chord_str:
        return None, 0, ""
    cleaned = chord_str.strip().replace("+", " ").replace(",", " ")
    tokens = [t.strip() for t in cleaned.split() if t.strip()]
    if not tokens:
        return None, 0, ""
    mods = 0
    mod_names = set()
    key = ""
    for token in tokens:
        tl = token.lower()
        if tl in MOD_MAP:
            mods |= MOD_MAP[tl]
            mod_names.add(MOD_CANONICAL[tl])
        else:
            if key:
                # Reject multiple non-modifier keys in a single chord
                return None, 0, ""
            key = token.upper()
    key = KEY_ALIASES.get(key, key)
    if not is_safe_key(key):
        return None, 0, ""
    # Enforce at least two keys pressed (at least one modifier and one base key)
    if not mod_names or not key or (len(mod_names) + 1 < 2):
        return None, 0, ""
    sorted_mods = sorted(mod_names, key=lambda m: MOD_ORDER.get(m, 99))
    norm = " + ".join(sorted_mods) + " + " + key
    return norm, mods, key


def get_hyprctl_binds():
    try:
        return json.loads(subprocess.check_output(["hyprctl", "binds", "-j"], timeout=3))
    except Exception:
        return []


DEFAULT_KEYBINDINGS = {
    "": "SUPER + BACKSLASH",
    "full": "SUPER + BRACKETRIGHT",
    "window": "",
    "region": "SUPER + BRACKETLEFT",
    "region-ocr": "SUPER + SHIFT + BRACKETLEFT"
}


def read_settings():
    if not SETTINGS_FILE.exists():
        return {"keybindings": dict(DEFAULT_KEYBINDINGS), "conflict_resolutions": {}}
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
        if "keybindings" not in data or not isinstance(data["keybindings"], dict):
            data["keybindings"] = dict(DEFAULT_KEYBINDINGS)
        if "conflict_resolutions" not in data or not isinstance(data["conflict_resolutions"], dict):
            if "conflictResolutions" in data and isinstance(data["conflictResolutions"], dict):
                data["conflict_resolutions"] = data["conflictResolutions"]
            else:
                data["conflict_resolutions"] = {}
        return data
    except Exception:
        return {"keybindings": dict(DEFAULT_KEYBINDINGS), "conflict_resolutions": {}}


def write_settings(data):
    try:
        existing = {}
        if SETTINGS_FILE.exists():
            try:
                existing = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
            except Exception:
                existing = {}
        existing.update(data)
        if "conflict_resolutions" in data:
            existing["conflictResolutions"] = data["conflict_resolutions"]
        if "conflictResolutions" in data:
            existing["conflict_resolutions"] = data["conflictResolutions"]
        temp_f = SETTINGS_FILE.with_suffix(f".tmp.{os.getpid()}")
        temp_f.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
        temp_f.replace(SETTINGS_FILE)
    except Exception as e:
        print(f"Error writing settings: {e}", file=sys.stderr)


def _effective_user_hypr_dir():
    if BINDINGS_LUA.parent != HYPR_DIR:
        return BINDINGS_LUA.parent
    return HYPR_DIR


def extract_description_from_line(fn, rest, raw_line):
    # 1. o.bind("...", "Description", ...) or o.bind_toggle("...", "Description", ...)
    if fn in ("o.bind", "o.bind_toggle"):
        m = re.match(r'^\s*["\']([^"\']+)["\']', rest)
        if m:
            return m.group(1).strip()
    # 2. { description = "..." }
    m = re.search(r'description\s*=\s*["\']([^"\']+)["\']', raw_line)
    if m:
        return m.group(1).strip()
    # 3. global("plugin.id:action") -> e.g. "omaguake:toggle"
    m = re.search(r'global\s*\(\s*["\']([^"\']+)["\']\s*\)', raw_line)
    if m:
        target = m.group(1)
        name = target.split(":", 1)[0].split(".")[-1]
        action = target.split(":", 1)[1] if ":" in target else ""
        return f"{name} ({action})" if action else name
    # 4. send_shortcut
    if "send_shortcut" in raw_line:
        m = re.search(r'key\s*=\s*["\']([^"\']+)["\']', raw_line)
        if m:
            return f"Send key '{m.group(1)}'"
    # 5. exec_cmd / exec
    m = re.search(r'exec(?:_cmd)?\s*\(\s*["\']([^"\']+)["\']\s*\)', raw_line)
    if m:
        return m.group(1).strip()
    m = re.search(r'["\']([^"\']+)["\']', rest)
    if m:
        return m.group(1).strip()
    return ""


def _iter_omarchy_loop_bindings(file_path, content, is_user):
    """
    Expands loop-generated bindings in Omarchy's default tiling.lua and utilities.lua
    (workspaces 1..10, group windows 1..5, bar panels 1..9).
    """
    if 'Switch to workspace " .. workspace' in content:
        for ws in range(1, 11):
            code = f"code:{ws + 9}"
            yield {
                "raw_chord": f"SUPER + {code}",
                "source_file": str(file_path),
                "is_user_file": is_user,
                "raw_line": f'o.bind("SUPER + {code}", "Switch to workspace {ws}", hl.dsp.focus({{ workspace = "{ws}" }}))',
                "fn": "o.bind",
                "rest": f'"Switch to workspace {ws}", hl.dsp.focus({{ workspace = "{ws}" }})',
                "description": f"Switch to workspace {ws}",
            }
            yield {
                "raw_chord": f"SUPER + SHIFT + {code}",
                "source_file": str(file_path),
                "is_user_file": is_user,
                "raw_line": f'o.bind("SUPER + SHIFT + {code}", "Move window to workspace {ws}", hl.dsp.window.move({{ workspace = "{ws}" }}))',
                "fn": "o.bind",
                "rest": f'"Move window to workspace {ws}", hl.dsp.window.move({{ workspace = "{ws}" }})',
                "description": f"Move window to workspace {ws}",
            }
            yield {
                "raw_chord": f"SUPER + SHIFT + ALT + {code}",
                "source_file": str(file_path),
                "is_user_file": is_user,
                "raw_line": f'o.bind("SUPER + SHIFT + ALT + {code}", "Move window silently to workspace {ws}", hl.dsp.window.move({{ workspace = "{ws}", follow = false }}))',
                "fn": "o.bind",
                "rest": f'"Move window silently to workspace {ws}", hl.dsp.window.move({{ workspace = "{ws}", follow = false }})',
                "description": f"Move window silently to workspace {ws}",
            }
    if 'Switch to group window " .. index' in content:
        for idx in range(1, 6):
            code = f"code:{idx + 9}"
            yield {
                "raw_chord": f"SUPER + ALT + {code}",
                "source_file": str(file_path),
                "is_user_file": is_user,
                "raw_line": f'o.bind("SUPER + ALT + {code}", "Switch to group window {idx}", hl.dsp.group.active({{ index = {idx} }}))',
                "fn": "o.bind",
                "rest": f'"Switch to group window {idx}", hl.dsp.group.active({{ index = {idx} }})',
                "description": f"Switch to group window {idx}",
            }
    if 'Bar panel " .. panel' in content:
        for panel in range(1, 10):
            code = f"code:{panel + 9}"
            yield {
                "raw_chord": f"SUPER + CTRL + {code}",
                "source_file": str(file_path),
                "is_user_file": is_user,
                "raw_line": f'o.bind("SUPER + CTRL + {code}", "Bar panel {panel}", "omarchy-shell -q shell togglePanelAt right {panel}")',
                "fn": "o.bind",
                "rest": f'"Bar panel {panel}", "omarchy-shell -q shell togglePanelAt right {panel}"',
                "description": f"Bar panel {panel}",
            }


def collect_system_bindings():
    """
    Yields all (norm_chord, mods, key, source_info) entries found in user Hyprland
    config files and Omarchy default binding files.
    """
    search_dirs = []
    user_dir = _effective_user_hypr_dir()
    if user_dir.exists():
        search_dirs.append((user_dir, True))
    if OMARCHY_DIR.exists():
        search_dirs.append((OMARCHY_DIR, False))

    for sdir, is_user in search_dirs:
        for p in sorted(sdir.iterdir()):
            if not p.is_file() or p.suffix not in (".lua", ".conf") or "bak" in p.name or ".tmp." in p.name:
                continue
            try:
                content = p.read_text(encoding="utf-8")
                if is_user:
                    content = re.sub(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), "", content, flags=re.DOTALL)
                for line in content.splitlines():
                    sline = line.strip()
                    if sline.startswith("--") or sline.startswith("#"):
                        continue
                    m = re.match(r'((?:o\.bind(?:_toggle)?|hl\.bind))\s*\(\s*["\']([^"\']+)["\']\s*,\s*(.*)\)', sline)
                    if m:
                        raw_chord = m.group(2).strip()
                        c_norm, c_mods, c_k = normalize_key_chord(raw_chord)
                        if c_norm and c_k:
                            fn = m.group(1)
                            rest = m.group(3)
                            desc = extract_description_from_line(fn, rest, sline)
                            yield (c_norm, c_mods, c_k, {
                                "source_file": str(p),
                                "is_user_file": is_user,
                                "raw_line": sline,
                                "raw_chord": raw_chord,
                                "fn": fn,
                                "rest": rest,
                                "description": desc
                            })
                        continue
                    # Check conf format: bind = MOD, KEY, ...
                    m_conf = re.match(r'bind[a-z]*\s*=\s*([^,]+),\s*([^,]+),\s*(.*)', sline)
                    if m_conf:
                        c_mod_str = m_conf.group(1).strip()
                        c_k_str = m_conf.group(2).strip()
                        c_chord = f"{c_mod_str} + {c_k_str}" if c_mod_str else c_k_str
                        c_norm, c_mods, c_k = normalize_key_chord(c_chord)
                        if c_norm and c_k:
                            yield (c_norm, c_mods, c_k, {
                                "source_file": str(p),
                                "is_user_file": is_user,
                                "raw_line": sline,
                                "raw_chord": c_chord,
                                "fn": "bind",
                                "rest": m_conf.group(3).strip(),
                                "description": m_conf.group(3).strip()
                            })
                for item in _iter_omarchy_loop_bindings(p, content, is_user):
                    c_norm, c_mods, c_k = normalize_key_chord(item["raw_chord"])
                    if c_norm and c_k:
                        yield (c_norm, c_mods, c_k, item)
            except Exception:
                pass


def find_system_binding_source(norm_chord):
    """
    Locates where norm_chord is bound in user Hyprland files or Omarchy defaults.
    """
    if not norm_chord:
        return None
    _, target_mods, target_key = normalize_key_chord(norm_chord)
    if not target_key:
        return None

    for _, c_mods, c_k, info in collect_system_bindings():
        if c_k == target_key and c_mods == target_mods:
            return info
    return None


def generate_candidate_chords():
    mods_list = [
        "SUPER + ALT",
        "SUPER + SHIFT",
        "CTRL + ALT",
        "CTRL + SHIFT",
    ]
    keys_list = [
        "C", "S", "X", "P", "R", "A", "Z", "V", "W", "Q",
        "F8", "F9", "F10", "F11", "F12", "PRINT", "GRAVE"
    ]
    out = []
    for m in mods_list:
        for k in keys_list:
            out.append(f"{m} + {k}")
    return out


def find_free_suggestions(exclude_chord=None, extra_excludes=None, count=3):
    taken = set(extra_excludes or [])
    if exclude_chord:
        norm_ex, _, _ = normalize_key_chord(exclude_chord)
        if norm_ex:
            taken.add(norm_ex)

    # Exclude all active plugin bindings
    settings = read_settings()
    for c in (settings.get("keybindings") or {}).values():
        if c:
            c_norm, _, _ = normalize_key_chord(c)
            if c_norm:
                taken.add(c_norm)

    bind_keys = set()
    for b in get_hyprctl_binds():
        k_raw = str(b.get("key", "")).strip()
        kc = int(b.get("keycode", 0) or 0)
        if not k_raw and kc > 0:
            k_raw = f"CODE:{kc}"
        k_norm = KEY_ALIASES.get(k_raw.upper(), k_raw.upper())
        if k_norm:
            bind_keys.add((int(b.get("modmask", 0) or 0), k_norm))

    for _, c_mods, c_k, _ in collect_system_bindings():
        bind_keys.add((c_mods, c_k))

    free = []
    for cand in generate_candidate_chords():
        norm, mods, key = normalize_key_chord(cand)
        if not norm or norm in taken:
            continue
        if (mods, key) not in bind_keys:
            free.append(norm)
            taken.add(norm)
            if len(free) >= count:
                break
    return free


def check_key_conflict(candidate_chord, target_mode=None):
    norm, target_mods, target_key = normalize_key_chord(candidate_chord)
    if not target_key:
        cleaned = (candidate_chord or "").strip().replace("+", " ").replace(",", " ")
        tokens = [t.strip() for t in cleaned.split() if t.strip()]
        mod_count = sum(1 for t in tokens if t.lower() in MOD_MAP)
        has_key = any(t.lower() not in MOD_MAP for t in tokens)
        if mod_count > 0 and not has_key:
            msg = f"Key combination '{candidate_chord}' contains only modifiers. Keybindings require at least one modifier and a base key (2+ keys required)."
        elif mod_count == 0 and has_key:
            msg = f"Single key '{candidate_chord}' cannot be used alone. Keybindings require at least two keys pressed (at least one modifier + a key)."
        else:
            msg = f"Key combination '{candidate_chord}' is not a valid keybinding."
        return {
            "valid": False,
            "conflict": False,
            "message": msg,
            "chord": ""
        }

    settings = read_settings()
    plugin_bindings = settings.get("keybindings", {})

    # Check OmaLumineCapture other modes
    for m, c in plugin_bindings.items():
        if not c:
            continue
        c_norm, _, _ = normalize_key_chord(c)
        if c_norm == norm:
            if target_mode is not None and m == target_mode:
                return {
                    "valid": True,
                    "conflict": False,
                    "message": f"'{norm}' is the current keybinding for {MODE_LABELS.get(m, m)}.",
                    "chord": norm
                }
            else:
                other_label = MODE_LABELS.get(m, m)
                suggs_user = find_free_suggestions(norm, {norm}, 3)
                suggs_conf = find_free_suggestions(norm, set(suggs_user) | {norm}, 3)
                return {
                    "valid": True,
                    "conflict": True,
                    "message": f"Keybinding '{norm}' is already in use by OmaLumineCapture ({other_label}).",
                    "chord": norm,
                    "owner": other_label,
                    "owner_scope": "plugin",
                    "other_mode": m,
                    "suggestions_for_user": suggs_user,
                    "suggestions_for_conflicting": suggs_conf
                }

    # Check active Hyprland bindings
    for b in get_hyprctl_binds():
        desc = b.get("description", "") or ""
        arg = b.get("arg", "") or ""
        if PLUGIN_ID in arg or PLUGIN_ID in desc or "lumine-capture" in arg:
            continue
        k_raw = str(b.get("key", "")).strip()
        kc = int(b.get("keycode", 0) or 0)
        if not k_raw and kc > 0:
            k_raw = f"CODE:{kc}"
        b_key = KEY_ALIASES.get(k_raw.upper(), k_raw.upper())
        if b_key == target_key and int(b.get("modmask", 0) or 0) == target_mods:
            src_info = find_system_binding_source(norm)
            label = desc
            if not label and src_info and src_info.get("description"):
                label = src_info.get("description")
            if not label and arg and not arg.isdigit():
                label = arg
            if not label:
                label = b.get("dispatcher", "") or "system shortcut"
            suggs_user = find_free_suggestions(norm, {norm}, 3)
            suggs_conf = find_free_suggestions(norm, set(suggs_user) | {norm}, 3)
            return {
                "valid": True,
                "conflict": True,
                "message": f"Conflicts with existing binding: '{norm}' is assigned to '{label}'.",
                "chord": norm,
                "owner": label,
                "owner_scope": "system",
                "source_info": src_info,
                "suggestions_for_user": suggs_user,
                "suggestions_for_conflicting": suggs_conf
            }

    # Check user config and default file definitions directly
    src_info = find_system_binding_source(norm)
    if src_info:
        desc = src_info.get("description") or "custom Hyprland binding"
        suggs_user = find_free_suggestions(norm, {norm}, 3)
        suggs_conf = find_free_suggestions(norm, set(suggs_user) | {norm}, 3)
        return {
            "valid": True,
            "conflict": True,
            "message": f"Conflicts with existing binding: '{norm}' is assigned to '{desc}'.",
            "chord": norm,
            "owner": desc,
            "owner_scope": "system",
            "source_info": src_info,
            "suggestions_for_user": suggs_user,
            "suggestions_for_conflicting": suggs_conf
        }

    return {
        "valid": True,
        "conflict": False,
        "message": f"Keybinding '{norm}' is free and available.",
        "chord": norm
    }


def restore_user_config_lines(target_mode):
    """
    Uncomments any lines in ~/.config/hypr/*.lua or *.conf commented out for target_mode.
    """
    user_dir = _effective_user_hypr_dir()
    if not user_dir.exists():
        return
    for p in user_dir.iterdir():
        if not p.is_file() or p.suffix not in (".lua", ".conf") or "bak" in p.name or ".tmp." in p.name:
            continue
        try:
            content = p.read_text(encoding="utf-8")
            if "Disabled by OmaLumineCapture" not in content:
                continue
            prefix = r"(?:--|#)"
            pattern = prefix + r' Disabled by OmaLumineCapture \(conflict resolution: ' + re.escape(target_mode) + r'\)\n' + prefix + r' ([^\n]+)'
            new_content = re.sub(pattern, r'\1', content)
            if new_content != content:
                temp_f = p.with_suffix(f".tmp.{os.getpid()}")
                temp_f.write_text(new_content, encoding="utf-8")
                temp_f.replace(p)
        except Exception:
            pass


def disable_user_config_line(norm_chord, target_mode):
    """
    Comments out the conflicting line in ~/.config/hypr/*.lua or *.conf.
    """
    _, c_mods, c_k = normalize_key_chord(norm_chord)
    user_dir = _effective_user_hypr_dir()
    if not user_dir.exists() or not c_k:
        return
    for p in user_dir.iterdir():
        if not p.is_file() or p.suffix not in (".lua", ".conf") or "bak" in p.name or ".tmp." in p.name:
            continue
        try:
            comment = "#" if p.suffix == ".conf" else "--"
            content = p.read_text(encoding="utf-8")
            parts = re.split(r"(-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID) + r")", content, flags=re.DOTALL)
            changed = False
            for i in range(len(parts)):
                if parts[i].startswith("-- BEGIN " + PLUGIN_ID):
                    continue
                new_lines = []
                for line in parts[i].splitlines():
                    sline = line.strip()
                    if sline.startswith("--") or sline.startswith("#"):
                        new_lines.append(line)
                        continue
                    matched = False
                    m = re.search(r'(?:o\.bind(?:_toggle)?|hl\.bind)\s*\(\s*["\']([^"\']+)["\']', line)
                    if m:
                        _, b_mods, b_key = normalize_key_chord(m.group(1))
                        if b_key == c_k and b_mods == c_mods:
                            matched = True
                    elif p.suffix == ".conf":
                        m_conf = re.match(r'bind[a-z]*\s*=\s*([^,]+),\s*([^,]+),', sline)
                        if m_conf:
                            c_mod_str = m_conf.group(1).strip()
                            c_k_str = m_conf.group(2).strip()
                            c_chord = f"{c_mod_str} + {c_k_str}" if c_mod_str else c_k_str
                            _, b_mods, b_key = normalize_key_chord(c_chord)
                            if b_key == c_k and b_mods == c_mods:
                                matched = True
                    if matched:
                        new_lines.append(f"{comment} Disabled by OmaLumineCapture (conflict resolution: {target_mode})")
                        new_lines.append(f"{comment} " + line)
                        changed = True
                        continue
                    new_lines.append(line)
                parts[i] = "\n".join(new_lines)
            if changed:
                temp_f = p.with_suffix(f".tmp.{os.getpid()}")
                temp_f.write_text("".join(parts), encoding="utf-8")
                temp_f.replace(p)
        except Exception:
            pass


def sanitize_args(raw):
    raw = (raw or "").strip()
    if not raw:
        return ""
    if re.search(r'["`$\\|<>;\r\n&]', raw):
        return ""
    return raw


def write_hyprland_block(keybindings, conflict_resolutions, args_by_mode):
    """
    Rebuilds the OmaLumineCapture block in ~/.config/hypr/bindings.lua.
    """
    BINDINGS_LUA.parent.mkdir(parents=True, exist_ok=True)
    existing = BINDINGS_LUA.read_text(encoding="utf-8") if BINDINGS_LUA.exists() else ""
    live = re.search(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), existing, flags=re.DOTALL)
    live_block = live.group(0) if live else None
    cleaned = re.sub(r"\n*-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID) + r"\n*", "\n", existing, flags=re.DOTALL).strip()

    block_lines = ["", f"-- BEGIN {PLUGIN_ID}"]

    # 1. Unbinds and reassignments from active conflict resolutions
    for mode, cr in conflict_resolutions.items():
        if cr.get("owner_scope") == "system":
            orig = cr.get("original_chord")
            src = cr.get("source_info") or {}
            if orig:
                block_lines.append(f'hl.unbind("{orig}")')
            raw_orig = src.get("raw_chord")
            if raw_orig and raw_orig != orig and '"' not in raw_orig and "\\" not in raw_orig:
                block_lines.append(f'hl.unbind("{raw_orig}")')
            if cr.get("action_type") == "reassign" and cr.get("reassigned_chord"):
                reassigned = cr["reassigned_chord"]
                if src and src.get("fn") and src.get("rest") and src.get("fn") != "bind":
                    fn = src["fn"]
                    rest = src["rest"]
                    block_lines.append(f'{fn}("{reassigned}", {rest})')
                else:
                    owner_desc = cr.get("owner", "Reassigned action")
                    block_lines.append(f'o.bind("{reassigned}", "{owner_desc}", nil)')

    # 2. Keybindings for OmaLumineCapture
    seen = set()
    for mode in MODE_ORDER:
        chord = (keybindings.get(mode) or "").strip()
        if not chord or chord.lower() in ("none", '""', "''"):
            continue
        norm, _, _ = normalize_key_chord(chord)
        if not norm or norm in seen:
            continue
        seen.add(norm)
        cmd = ("lumine-capture " + sanitize_args(args_by_mode.get(mode, ""))).strip()
        launch_cmd = cmd
        if shutil.which("uwsm-app"):
            launch_cmd = "uwsm-app -- " + cmd
        safe_cmd = launch_cmd.replace('\\', '').replace('"', "")
        tag = f"LumineCapture[{MODE_LABELS.get(mode, mode)}]" if mode else "LumineCapture"
        block_lines.append(f'hl.bind("{norm}", hl.dsp.exec_cmd("{safe_cmd}"), {{ description = "{tag}: {cmd}", dont_inhibit = true }})')

    block_lines.append(f"-- END {PLUGIN_ID}")
    block_lines.append("")

    new_block = "\n".join(block_lines[1:-1])
    new_content = cleaned + "\n" + "\n".join(block_lines)

    if live_block is None or "\n".join(live_block.splitlines()) != new_block:
        try:
            temp_binding = BINDINGS_LUA.with_suffix(f".tmp.{os.getpid()}")
            temp_binding.write_text(new_content, encoding="utf-8")
            temp_binding.replace(BINDINGS_LUA)
        except Exception:
            BINDINGS_LUA.write_text(new_content, encoding="utf-8")
        try:
            subprocess.run(["hyprctl", "reload"], timeout=3, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def handle_apply(payload):
    mode = payload.get("mode", "")
    chord = payload.get("chord", "").strip()
    resolution_type = payload.get("resolution_type", "none")  # none | reassign | takeover
    reassigned_chord = payload.get("reassigned_chord", "").strip()
    conflicting_owner = payload.get("conflicting_owner", "")
    conflicting_scope = payload.get("conflicting_scope", "system")
    other_mode = payload.get("other_mode", "")
    reset_previous_conflict = bool(payload.get("reset_previous_conflict", False))
    args_by_mode = payload.get("args_by_mode", {})

    settings = read_settings()
    keybindings = dict(settings.get("keybindings", {}))
    conflict_resolutions = dict(settings.get("conflict_resolutions", {}))

    # 1. Reset previous conflict for this mode if requested
    if reset_previous_conflict and mode in conflict_resolutions:
        prior = conflict_resolutions[mode]
        if prior.get("owner_scope") == "plugin":
            prior_other = prior.get("other_mode")
            orig = prior.get("original_chord")
            if prior_other and orig:
                # restore if not currently occupied by another mode
                if not any(keybindings.get(m) == orig for m in MODE_ORDER if m != prior_other and m != mode):
                    keybindings[prior_other] = orig
        elif prior.get("owner_scope") == "system":
            restore_user_config_lines(mode)
        del conflict_resolutions[mode]

    # 2. Process new keybinding
    norm_chord, _, _ = normalize_key_chord(chord)
    if not norm_chord:
        return {"success": False, "error": "Invalid keybinding combination."}
    keybindings[mode] = norm_chord

    # 3. Process conflict resolution
    if resolution_type == "reassign":
        norm_reassigned, _, _ = normalize_key_chord(reassigned_chord)
        if not norm_reassigned:
            return {"success": False, "error": "Invalid replacement keybinding combination."}
        if conflicting_scope == "plugin":
            if other_mode:
                keybindings[other_mode] = norm_reassigned
            conflict_resolutions[mode] = {
                "target_chord": norm_chord,
                "owner": conflicting_owner,
                "owner_scope": "plugin",
                "other_mode": other_mode,
                "original_chord": norm_chord,
                "action_type": "reassign",
                "reassigned_chord": norm_reassigned
            }
        else:  # system
            src = find_system_binding_source(norm_chord)
            disable_user_config_line(norm_chord, mode)
            conflict_resolutions[mode] = {
                "target_chord": norm_chord,
                "owner": conflicting_owner,
                "owner_scope": "system",
                "original_chord": norm_chord,
                "action_type": "reassign",
                "reassigned_chord": norm_reassigned,
                "source_info": src
            }
    elif resolution_type == "takeover":
        if conflicting_scope == "plugin":
            if other_mode:
                keybindings[other_mode] = ""
            conflict_resolutions[mode] = {
                "target_chord": norm_chord,
                "owner": conflicting_owner,
                "owner_scope": "plugin",
                "other_mode": other_mode,
                "original_chord": norm_chord,
                "action_type": "takeover",
                "reassigned_chord": ""
            }
        else:  # system
            src = find_system_binding_source(norm_chord)
            disable_user_config_line(norm_chord, mode)
            conflict_resolutions[mode] = {
                "target_chord": norm_chord,
                "owner": conflicting_owner,
                "owner_scope": "system",
                "original_chord": norm_chord,
                "action_type": "takeover",
                "reassigned_chord": "",
                "source_info": src
            }

    # Save settings and write bindings.lua
    write_settings({
        "keybindings": keybindings,
        "conflict_resolutions": conflict_resolutions
    })
    write_hyprland_block(keybindings, conflict_resolutions, args_by_mode)

    return {
        "success": True,
        "message": f"Keybinding applied: {norm_chord} ({MODE_LABELS.get(mode, mode)})",
        "keybindings": keybindings,
        "conflict_resolutions": conflict_resolutions
    }


def handle_remove(payload):
    mode = payload.get("mode", "")
    args_by_mode = payload.get("args_by_mode", {})

    settings = read_settings()
    keybindings = dict(settings.get("keybindings", {}))
    conflict_resolutions = dict(settings.get("conflict_resolutions", {}))

    # Reset any resolved conflict for this mode
    if mode in conflict_resolutions:
        prior = conflict_resolutions[mode]
        if prior.get("owner_scope") == "plugin":
            prior_other = prior.get("other_mode")
            orig = prior.get("original_chord")
            if prior_other and orig:
                if not any(keybindings.get(m) == orig for m in MODE_ORDER if m != prior_other and m != mode):
                    keybindings[prior_other] = orig
        elif prior.get("owner_scope") == "system":
            restore_user_config_lines(mode)
        del conflict_resolutions[mode]

    keybindings[mode] = ""

    write_settings({
        "keybindings": keybindings,
        "conflict_resolutions": conflict_resolutions
    })
    write_hyprland_block(keybindings, conflict_resolutions, args_by_mode)

    return {
        "success": True,
        "message": f"Keybinding removed for {MODE_LABELS.get(mode, mode)}",
        "keybindings": keybindings,
        "conflict_resolutions": conflict_resolutions
    }


def handle_sync(payload):
    settings = read_settings()
    keybindings = settings.get("keybindings", {})
    conflict_resolutions = settings.get("conflict_resolutions", {})
    args_by_mode = payload.get("args_by_mode", {})

    if not SETTINGS_FILE.exists():
        write_settings({
            "keybindings": keybindings,
            "conflict_resolutions": conflict_resolutions
        })

    write_hyprland_block(keybindings, conflict_resolutions, args_by_mode)
    return {"success": True, "keybindings": keybindings, "conflict_resolutions": conflict_resolutions}


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "status"

    if action == "status":
        s = read_settings()
        print(json.dumps({
            "keybindings": s.get("keybindings", {}),
            "conflict_resolutions": s.get("conflict_resolutions", {})
        }))
    elif action == "check-key":
        chord = sys.argv[2] if len(sys.argv) > 2 else ""
        mode = sys.argv[3] if len(sys.argv) > 3 else None
        res = check_key_conflict(chord, mode)
        print(json.dumps(res))
    elif action == "apply-key" or action == "apply-map":
        raw = sys.argv[2] if len(sys.argv) > 2 else "{}"
        try:
            payload = json.loads(raw)
        except Exception as e:
            print(json.dumps({"success": False, "error": f"Invalid JSON: {e}"}))
            sys.exit(1)
        res = handle_apply(payload)
        print(json.dumps(res))
        if not res.get("success"):
            sys.exit(1)
    elif action == "remove-key":
        raw = sys.argv[2] if len(sys.argv) > 2 else "{}"
        try:
            payload = json.loads(raw)
        except Exception as e:
            print(json.dumps({"success": False, "error": f"Invalid JSON: {e}"}))
            sys.exit(1)
        res = handle_remove(payload)
        print(json.dumps(res))
        if not res.get("success"):
            sys.exit(1)
    elif action == "sync":
        raw = sys.argv[2] if len(sys.argv) > 2 else "{}"
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        res = handle_sync(payload)
        print(json.dumps(res))
    else:
        print(json.dumps({"error": f"Unknown action: {action}"}))
        sys.exit(1)
