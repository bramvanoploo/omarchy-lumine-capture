#!/usr/bin/env python3
# Keybinding conflict checker/applier for OmaLumineCapture.
# Pattern adapted from OmaGuake (bramvanoploo.omaguake) conflict-checker.py.
import sys
import os
import re
import json
import subprocess
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
HYPR_DIR = HOME / ".config" / "hypr"
BINDINGS_LUA = HYPR_DIR / "bindings.lua"
PLUGIN_ID = "bramvanoploo.omarchy-lumine-capture"

MOD_MAP = {"super": 64, "mod4": 64, "logo": 64, "win": 64, "ctrl": 4, "control": 4, "shift": 1, "alt": 8, "mod1": 8}

KEY_ALIASES = {
    "BACKQUOTE": "GRAVE", "BACKTICK": "GRAVE", "ESC": "ESCAPE", "ENTER": "RETURN",
    "DEL": "DELETE", "PGUP": "PAGEUP", "PGDN": "PAGEDOWN",
}

SAFE_KEY_EXTRA = {
    "SPACE", "GRAVE", "RETURN", "TAB", "ESCAPE", "BACKSPACE", "INSERT", "DELETE",
    "HOME", "END", "PAGEUP", "PAGEDOWN", "MINUS", "EQUAL", "COMMA", "PERIOD",
    "SLASH", "SEMICOLON", "APOSTROPHE", "BACKSLASH",
}


def is_safe_key(key):
    if not key:
        return False
    if key in SAFE_KEY_EXTRA:
        return True
    if re.fullmatch(r"[A-Z0-9]", key):
        return True
    if re.fullmatch(r"F(?:[1-9]|1[0-2])", key):
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
    mod_names = []
    key = ""
    for token in tokens:
        tl = token.lower()
        if tl in MOD_MAP:
            mods |= MOD_MAP[tl]
            mod_names.append(tl.upper())
        else:
            key = token.upper()
    key = KEY_ALIASES.get(key, key)
    if not is_safe_key(key):
        return None, 0, ""
    return "+".join(sorted(mod_names)) + " + " + key if mod_names else key, mods, key


def get_hyprctl_binds():
    try:
        return json.loads(subprocess.check_output(["hyprctl", "binds", "-j"], timeout=3))
    except Exception:
        return []


def own_block(content):
    m = re.search(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), content, flags=re.DOTALL)
    return m.group(0) if m else ""


def current_own_chord():
    if BINDINGS_LUA.exists():
        try:
            block = own_block(BINDINGS_LUA.read_text(encoding="utf-8"))
            m = re.search(r'hl\.bind\(\s*["\']([^"\']+)["\']', block)
            if m:
                return normalize_key_chord(m.group(1))[0]
        except Exception:
            pass
    return None


def check_key_conflict(candidate_chord):
    norm, target_mods, target_key = normalize_key_chord(candidate_chord)
    if not target_key:
        return {"conflict": True, "message": "Invalid keybinding string."}
    if current_own_chord() == norm:
        return {"conflict": False, "message": f"Keybinding '{norm}' is currently assigned to OmaLumineCapture."}
    for b in get_hyprctl_binds():
        desc = b.get("description", "") or ""
        arg = b.get("arg", "") or ""
        if PLUGIN_ID in arg or PLUGIN_ID in desc or "lumine-capture" in arg:
            continue
        if str(b.get("key", "")).upper() == target_key and int(b.get("modmask", 0)) == target_mods:
            label = desc or arg or b.get("dispatcher", "") or "system action"
            return {"conflict": True, "message": f"Conflicts with existing binding: '{norm}' is assigned to '{label}'."}
    if BINDINGS_LUA.exists():
        try:
            content = re.sub(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), "", BINDINGS_LUA.read_text(encoding="utf-8"), flags=re.DOTALL)
            for line in content.splitlines():
                line = line.strip()
                if line.startswith("--"):
                    continue
                m = re.search(r'bind\s*\(\s*["\']([^"\']+)["\']\s*,\s*(?:["\']([^"\']*)["\']|[^,\)]+)', line)
                if m:
                    b_norm, b_mods, b_k = normalize_key_chord(m.group(1))
                    if b_k == target_key and b_mods == target_mods:
                        desc = m.group(2) if len(m.groups()) > 1 and m.group(2) else "custom Hyprland binding"
                        return {"conflict": True, "message": f"Conflicts with binding in ~/.config/hypr/bindings.lua: '{norm}' -> '{desc}'."}
        except Exception:
            pass
    return {"conflict": False, "message": f"Keybinding '{norm}' is available."}


def find_free_suggestions(exclude_chord=None):
    candidates = [
        "SUPER + SHIFT + S", "CTRL + SHIFT + F12", "SUPER + ALT + C",
        "CTRL + ALT + C", "SUPER + SHIFT + X", "CTRL + SHIFT + P",
    ]
    norm_exclude = normalize_key_chord(exclude_chord)[0] if exclude_chord else ""
    bind_keys = {(int(b.get("modmask", 0)), str(b.get("key", "")).upper()) for b in get_hyprctl_binds()}
    free = []
    for cand in candidates:
        norm, mods, key = normalize_key_chord(cand)
        if not norm or norm == norm_exclude:
            continue
        if (mods, key) not in bind_keys:
            free.append(norm)
        if len(free) >= 3:
            break
    return free


def get_current_status():
    applied = current_own_chord() or ""
    s_norm, s_mods, s_key = normalize_key_chord("SUPER + SHIFT + S")
    s_conflict = False
    s_msg = ""
    if applied != s_norm:
        for b in get_hyprctl_binds():
            desc = b.get("description", "") or ""
            arg = b.get("arg", "") or ""
            if PLUGIN_ID in arg or PLUGIN_ID in desc:
                continue
            if str(b.get("key", "")).upper() == s_key and int(b.get("modmask", 0)) == s_mods:
                s_conflict = True
                s_msg = f"'{s_norm}' is in use by '{desc or arg or 'system action'}'."
                break
    return {
        "applied_key": applied,
        "suggested_key": "SUPER + SHIFT + S",
        "suggested_key_conflict": s_conflict,
        "suggested_key_conflict_message": s_msg,
        "key_suggestions": find_free_suggestions(s_norm if s_conflict else ""),
    }


def sanitize_args(raw):
    raw = (raw or "").strip()
    if not raw:
        return ""
    if not re.fullmatch(r"[A-Za-z0-9 ._+=/@%:,~-]*", raw):
        return ""
    return raw


def disable_key_conflicts_in_configs(chord_norm):
    _, c_mods, c_k = normalize_key_chord(chord_norm)
    if not HYPR_DIR.exists() or not c_k:
        return
    for p in HYPR_DIR.iterdir():
        if p.is_file() and p.suffix in (".lua", ".conf") and "bak" not in p.name:
            try:
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
                        m = re.search(r'(?:o\.bind|hl\.bind)\s*\(\s*["\']([^"\']+)["\']', line)
                        if m:
                            _, b_mods, b_key = normalize_key_chord(m.group(1))
                            if b_key == c_k and b_mods == c_mods:
                                new_lines.append("-- Disabled by OmaLumineCapture (shortcut taken over)")
                                new_lines.append("-- " + line)
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


def apply_configuration(keychord, launch_args, unbind_conflicts=False):
    args = sanitize_args(launch_args)
    cmd = ("lumine-capture " + args).strip()
    norm = ""
    if keychord and keychord.strip().lower() not in ("none", ""):
        norm, _, _ = normalize_key_chord(keychord)
        if not norm:
            return {"success": False, "error": "Invalid keybinding."}
        if not unbind_conflicts:
            res = check_key_conflict(norm)
            if res["conflict"]:
                res["suggestions"] = find_free_suggestions(norm)
                return {"success": False, "error": res["message"], "suggestions": res["suggestions"]}
        else:
            disable_key_conflicts_in_configs(norm)

    BINDINGS_LUA.parent.mkdir(parents=True, exist_ok=True)
    existing = BINDINGS_LUA.read_text(encoding="utf-8") if BINDINGS_LUA.exists() else ""
    cleaned = re.sub(r"\n*-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID) + r"\n*", "\n", existing, flags=re.DOTALL).strip()
    block_lines = ["", f"-- BEGIN {PLUGIN_ID}"]
    if norm:
        if unbind_conflicts:
            block_lines.append(f'hl.unbind("{norm}")')
        safe_cmd = cmd.replace('\\', '').replace('"', "")
        block_lines.append(f'hl.bind("{norm}", hl.dsp.exec("{safe_cmd}"), {{ desc = "LumineCapture: {safe_cmd}" }})')
    block_lines.append(f"-- END {PLUGIN_ID}")
    block_lines.append("")
    new_content = cleaned + "\n" + "\n".join(block_lines)
    try:
        temp_binding = BINDINGS_LUA.with_suffix(f".tmp.{os.getpid()}")
        temp_binding.write_text(new_content, encoding="utf-8")
        temp_binding.replace(BINDINGS_LUA)
    except Exception:
        BINDINGS_LUA.write_text(new_content, encoding="utf-8")
    try:
        subprocess.run(["hyprctl", "reload"], timeout=3)
    except Exception:
        pass
    return {"success": True, "message": "OmaLumineCapture binding updated."}


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "status":
        print(json.dumps(get_current_status()))
    elif action == "check-key":
        res = check_key_conflict(sys.argv[2] if len(sys.argv) > 2 else "")
        if res.get("conflict"):
            res["suggestions"] = find_free_suggestions(sys.argv[2] if len(sys.argv) > 2 else "")
        print(json.dumps(res))
    elif action == "apply":
        chord = sys.argv[2] if len(sys.argv) > 2 else ""
        if chord.lower() in ("none", '""', "''"):
            chord = ""
        args = sys.argv[3] if len(sys.argv) > 3 else ""
        unbind = len(sys.argv) > 4 and sys.argv[4].lower() in ("1", "true", "yes")
        res = apply_configuration(chord, args, unbind)
        print(json.dumps(res))
        if not res.get("success"):
            sys.exit(1)
    else:
        print(json.dumps({"error": f"Unknown action: {action}"}))
        sys.exit(1)
