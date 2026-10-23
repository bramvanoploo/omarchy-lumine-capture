#!/usr/bin/env python3
# Keybinding conflict checker/applier for OmaLumineCapture.
# Pattern adapted from OmaGuake (bramvanoploo.omaguake) conflict-checker.py.
# One Hyprland binding per capture mode, all inside a single plugin block:
#   apply-map <json>  {"bindings": {mode: chord}, "args_by_mode": {mode: args},
#                      "mode": <mode being changed>, "unbind_conflicts": bool}
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
PLUGIN_ID = "bramvanoploo.omarchy-lumine-capture"

# Must match LaunchArgs.js MODES; "" is the editor mode.
MODE_ORDER = ["", "full", "window", "region", "region-ocr"]
MODE_LABELS = {"": "editor", "full": "full screen", "window": "window",
               "region": "region", "region-ocr": "region OCR"}

MOD_MAP = {"super": 64, "mod4": 64, "logo": 64, "win": 64, "ctrl": 4, "control": 4, "shift": 1, "alt": 8, "mod1": 8}
MOD_CANONICAL = {"super": "SUPER", "mod4": "SUPER", "logo": "SUPER", "win": "SUPER", "ctrl": "CTRL", "control": "CTRL", "shift": "SHIFT", "alt": "ALT", "mod1": "ALT"}

KEY_ALIASES = {
    "BACKQUOTE": "GRAVE", "BACKTICK": "GRAVE", "ESC": "ESCAPE", "ENTER": "RETURN",
    "DEL": "DELETE", "PGUP": "PAGEUP", "PGDN": "PAGEDOWN", "PRIOR": "PAGEUP", "NEXT": "PAGEDOWN",
    "SYSRQ": "PRINT",
}

SAFE_KEY_EXTRA = {
    "SPACE", "GRAVE", "RETURN", "TAB", "ESCAPE", "BACKSPACE", "INSERT", "DELETE",
    "HOME", "END", "PAGEUP", "PAGEDOWN", "MINUS", "EQUAL", "COMMA", "PERIOD",
    "SLASH", "SEMICOLON", "APOSTROPHE", "BACKSLASH",
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
            key = token.upper()
    key = KEY_ALIASES.get(key, key)
    if not is_safe_key(key):
        return None, 0, ""
    return " + ".join(sorted(mod_names)) + " + " + key if mod_names else key, mods, key


def get_hyprctl_binds():
    try:
        return json.loads(subprocess.check_output(["hyprctl", "binds", "-j"], timeout=3))
    except Exception:
        return []


def own_block(content):
    m = re.search(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), content, flags=re.DOTALL)
    return m.group(0) if m else ""


def own_chords():
    # {normalized chord: mode} for every binding the plugin wrote. Old single
    # binding blocks (description "LumineCapture: ...") map to the editor mode.
    chords = {}
    if BINDINGS_LUA.exists():
        try:
            block = own_block(BINDINGS_LUA.read_text(encoding="utf-8"))
            for m in re.finditer(r'hl\.bind\(\s*["\']([^"\']+)["\'][^\n]*?description = "LumineCapture(?:\[([^\]]*)\])?:', block):
                norm, _, _ = normalize_key_chord(m.group(1))
                if norm:
                    chords[norm] = m.group(2) if m.group(2) is not None else ""
        except Exception:
            pass
    return chords


def check_key_conflict(candidate_chord):
    norm, target_mods, target_key = normalize_key_chord(candidate_chord)
    if not target_key:
        return {"conflict": True, "message": "Invalid keybinding string."}
    own = own_chords()
    if norm in own:
        mode_label = MODE_LABELS.get(own[norm], own[norm])
        return {"conflict": False, "message": f"Keybinding '{norm}' is currently assigned to OmaLumineCapture ({mode_label})."}
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


def find_free_suggestions(exclude_chord=None, extra_excludes=None):
    candidates = [
        "SUPER + SHIFT + S", "CTRL + SHIFT + F12", "SUPER + ALT + C",
        "CTRL + ALT + C", "SUPER + SHIFT + X", "CTRL + SHIFT + P",
    ]
    taken = set(extra_excludes or [])
    if exclude_chord:
        norm_exclude = normalize_key_chord(exclude_chord)[0]
        if norm_exclude:
            taken.add(norm_exclude)
    bind_keys = {(int(b.get("modmask", 0)), str(b.get("key", "")).upper()) for b in get_hyprctl_binds()}
    free = []
    for cand in candidates:
        norm, mods, key = normalize_key_chord(cand)
        if not norm or norm in taken:
            continue
        if (mods, key) not in bind_keys:
            free.append(norm)
        if len(free) >= 3:
            break
    return free


def get_current_status():
    own = own_chords()
    applied = ", ".join(sorted(own)) if own else ""
    # No shipped default chord: nothing to suggest until the user records one.
    s_norm, s_mods, s_key = "", 0, ""
    s_conflict = False
    s_msg = ""
    return {
        "applied_key": applied,
        "suggested_key": "",
        "suggested_key_conflict": s_conflict,
        "suggested_key_conflict_message": s_msg,
        "key_suggestions": find_free_suggestions("", set(own)),
    }


def sanitize_args(raw):
    # What the launchers can carry into a Hyprland exec command: plain text,
    # single quotes (Omarchy's own quoting for paths with spaces), no escapes.
    raw = (raw or "").strip()
    if not raw:
        return ""
    if not re.fullmatch(r"[A-Za-z0-9 ._+=/@%:,'~-]*", raw):
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


def apply_map(payload):
    # Rebuild the whole plugin block from the full binding map, so clearing a
    # mode's shortcut drops its binding without extra bookkeeping.
    bindings = payload.get("bindings", {})
    args_by_mode = payload.get("args_by_mode", {})
    target_mode = payload.get("mode", "")
    unbind_conflicts = bool(payload.get("unbind_conflicts", False))

    target_chord = (bindings.get(target_mode) or "").strip()
    if target_chord and target_chord.lower() not in ("none", '""', "''"):
        norm, _, _ = normalize_key_chord(target_chord)
        if not norm:
            return {"success": False, "error": "Invalid keybinding."}
        own = own_chords()
        other = own.get(norm)
        if other is not None and other != target_mode:
            msg = (f"'{norm}' is already assigned to OmaLumineCapture "
                   f"({MODE_LABELS.get(other, other)}). Clear that mode's shortcut first.")
            return {"success": False, "error": msg,
                    "suggestions": find_free_suggestions(norm, set(own))}
        if unbind_conflicts:
            disable_key_conflicts_in_configs(norm)
        else:
            res = check_key_conflict(norm)
            if res["conflict"]:
                res["suggestions"] = find_free_suggestions(norm, set(own))
                return {"success": False, "error": res["message"], "suggestions": res["suggestions"]}

    BINDINGS_LUA.parent.mkdir(parents=True, exist_ok=True)
    existing = BINDINGS_LUA.read_text(encoding="utf-8") if BINDINGS_LUA.exists() else ""
    # What the block says now, if the plugin has written one before.
    live = re.search(r"-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID), existing, flags=re.DOTALL)
    live_block = live.group(0) if live else None
    cleaned = re.sub(r"\n*-- BEGIN " + re.escape(PLUGIN_ID) + r".*?-- END " + re.escape(PLUGIN_ID) + r"\n*", "\n", existing, flags=re.DOTALL).strip()
    block_lines = ["", f"-- BEGIN {PLUGIN_ID}"]
    # Preserve existing hl.unbind(...) lines so previous take-overs keep working.
    existing_unbinds = []
    if live_block:
        for m in re.finditer(r'hl\.unbind\(\s*["\']([^"\']+)["\']\s*\)', live_block):
            u_norm, _, _ = normalize_key_chord(m.group(1))
            if u_norm and u_norm not in existing_unbinds:
                existing_unbinds.append(u_norm)
    if target_chord and unbind_conflicts:
        norm, _, _ = normalize_key_chord(target_chord)
        if norm and norm not in existing_unbinds:
            existing_unbinds.append(norm)
    for u_norm in existing_unbinds:
        block_lines.append(f'hl.unbind("{u_norm}")')
    seen = set()
    for mode in MODE_ORDER:
        chord = (bindings.get(mode) or "").strip()
        if not chord or chord.lower() in ("none", '""', "''"):
            continue
        norm, _, _ = normalize_key_chord(chord)
        if not norm or norm in seen:
            continue  # invalid chords never reach here (checked above); a chord
            # used by two modes loses the later one, matching the UI rule.
        seen.add(norm)
        cmd = ("lumine-capture " + sanitize_args(args_by_mode.get(mode, ""))).strip()
        # Omarchy/Hyprland Lua exposes hl.dsp.exec_cmd / hl.dsp.exec_raw; there is no hl.dsp.exec.
        # Launch through uwsm-app when present so the app gets a systemd scope, like Omarchy's own bindings.
        launch_cmd = cmd
        if shutil.which("uwsm-app"):
            launch_cmd = "uwsm-app -- " + cmd
        safe_cmd = launch_cmd.replace('\\', '').replace('"', "")
        tag = f"LumineCapture[{MODE_LABELS.get(mode, mode)}]" if mode else "LumineCapture"
        block_lines.append(f'hl.bind("{norm}", hl.dsp.exec_cmd("{safe_cmd}"), {{ description = "{tag}: {cmd}", dont_inhibit = true }})')
    block_lines.append(f"-- END {PLUGIN_ID}")
    block_lines.append("")
    # The plugin re-applies the shortcuts at shell start to keep them in step
    # with the launch options. Rewriting the user's hyprland config and
    # reloading the compositor on every start, for a block that already says
    # this, is not a start-up side effect worth having, so an unchanged block
    # is left alone.
    new_block = "\n".join(block_lines[1:-1])
    if live_block is not None and "\n".join(live_block.splitlines()) == new_block:
        return {"success": True, "unchanged": True, "message": "Keybindings already run these commands."}
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
    return {"success": True, "message": "OmaLumineCapture bindings updated."}


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "status":
        print(json.dumps(get_current_status()))
    elif action == "check-key":
        chord = sys.argv[2] if len(sys.argv) > 2 else ""
        res = check_key_conflict(chord)
        if res.get("conflict"):
            res["suggestions"] = find_free_suggestions(chord, set(own_chords()))
        print(json.dumps(res))
    elif action == "apply-map":
        try:
            payload = json.loads(sys.argv[2] if len(sys.argv) > 2 else "{}")
        except json.JSONDecodeError as e:
            print(json.dumps({"success": False, "error": f"Bad JSON: {e}"}))
            sys.exit(1)
        res = apply_map(payload)
        print(json.dumps(res))
        if not res.get("success"):
            sys.exit(1)
    else:
        print(json.dumps({"error": f"Unknown action: {action}"}))
        sys.exit(1)
