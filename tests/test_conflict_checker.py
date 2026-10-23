#!/usr/bin/env python3
import unittest
import json
import sys
import tempfile
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import importlib
cc = importlib.import_module("conflict-checker")

class TestConflictCheckerNew(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp_bindings = Path(self.tmpdir.name) / "bindings.lua"
        self.tmp_settings = Path(self.tmpdir.name) / "settings.json"
        self.tmp_bindings.write_text("-- test bindings\n", encoding="utf-8")
        self.tmp_settings.write_text(json.dumps({"keybindings": {}, "conflict_resolutions": {}}), encoding="utf-8")
        
        self.orig_hypr_dir = cc.HYPR_DIR
        self.orig_bindings = cc.BINDINGS_LUA
        self.orig_settings = cc.SETTINGS_FILE
        cc.HYPR_DIR = Path(self.tmpdir.name)
        cc.BINDINGS_LUA = self.tmp_bindings
        cc.SETTINGS_FILE = self.tmp_settings

    def tearDown(self):
        cc.HYPR_DIR = self.orig_hypr_dir
        cc.BINDINGS_LUA = self.orig_bindings
        cc.SETTINGS_FILE = self.orig_settings
        self.tmpdir.cleanup()

    def test_normalize_key_chord(self):
        norm, mods, key = cc.normalize_key_chord("ctrl + alt + super + s")
        self.assertEqual(norm, "SUPER + CTRL + ALT + S")
        self.assertEqual(key, "S")

        # Test bracket right and code:35 normalization
        norm_bracket, mods_bracket, key_bracket = cc.normalize_key_chord("SUPER + ALT + ]")
        self.assertEqual(norm_bracket, "SUPER + ALT + BRACKETRIGHT")
        self.assertEqual(key_bracket, "BRACKETRIGHT")

        norm_code, _, _ = cc.normalize_key_chord("SUPER + ALT + code:35")
        self.assertEqual(norm_code, "SUPER + ALT + BRACKETRIGHT")

    def test_single_key_or_modifier_only_invalid(self):
        # Single keys without modifiers must be rejected (< 2 keys)
        res_single = cc.check_key_conflict("PRINT")
        self.assertFalse(res_single["valid"])

        res_bare_c = cc.check_key_conflict("C")
        self.assertFalse(res_bare_c["valid"])

        # Modifier only must be rejected
        res_super = cc.check_key_conflict("SUPER")
        self.assertFalse(res_super["valid"])

        # Multiple base keys must be rejected
        res_multi_base = cc.check_key_conflict("SUPER + A + B")
        self.assertFalse(res_multi_base["valid"])

    def test_workspace_and_bind_toggle_conflicts(self):
        # SUPER + 1 (code:10 in tiling.lua loop) should conflict with Switch to workspace 1
        res_ws = cc.check_key_conflict("SUPER + 1")
        self.assertTrue(res_ws["valid"])
        self.assertTrue(res_ws["conflict"])
        self.assertIn("workspace 1", res_ws["owner"].lower())

        # SUPER + SHIFT + SPACE (o.bind_toggle in utilities.lua) should conflict
        res_toggle = cc.check_key_conflict("SUPER + SHIFT + SPACE")
        self.assertTrue(res_toggle["valid"])
        self.assertTrue(res_toggle["conflict"])
        self.assertIn("bar", res_toggle["owner"].lower())

    def test_keep_prior_conflict_when_reset_false(self):
        # 1. Apply conflict takeover on full
        cc.handle_apply({
            "mode": "full",
            "chord": "SUPER + RETURN",
            "resolution_type": "takeover",
            "conflicting_owner": "Terminal",
            "conflicting_scope": "system"
        })
        # 2. Change full to a new chord with reset_previous_conflict=False
        res = cc.handle_apply({
            "mode": "full",
            "chord": "SUPER + ALT + C",
            "resolution_type": "none",
            "reset_previous_conflict": False
        })
        self.assertTrue(res["success"])
        self.assertIn("full", res["conflict_resolutions"])
        content = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertIn('hl.unbind("SUPER + RETURN")', content)

    def test_user_file_disable_and_restore(self):
        self.tmp_bindings.write_text('o.bind("SUPER + ALT + M", "My Custom App", "my-app")\n', encoding="utf-8")
        res = cc.handle_apply({
            "mode": "region",
            "chord": "SUPER + ALT + M",
            "resolution_type": "reassign",
            "reassigned_chord": "SUPER + ALT + Z",
            "conflicting_owner": "My Custom App",
            "conflicting_scope": "system"
        })
        self.assertTrue(res["success"])
        content = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertIn('-- Disabled by OmaLumineCapture (conflict resolution: region)', content)
        self.assertIn('o.bind("SUPER + ALT + Z", "My Custom App", "my-app")', content)

        # Removing region keybinding restores the user line
        cc.handle_remove({"mode": "region"})
        restored = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertNotIn('-- Disabled by OmaLumineCapture', restored)
        self.assertIn('o.bind("SUPER + ALT + M", "My Custom App", "my-app")', restored)

    def test_sanitize_args(self):
        # Safe paths including parentheses are preserved
        self.assertEqual(cc.sanitize_args("-r -o '/tmp/My (Shots)'"), "-r -o '/tmp/My (Shots)'")
        # Injection attempts are rejected
        self.assertEqual(cc.sanitize_args("-r; rm -rf /"), "")
        self.assertEqual(cc.sanitize_args("-r $(whoami)"), "")

    def test_bracket_right_conflict(self):
        # SUPER + ALT + ] should conflict with Omarchy utilities.lua (code:35 - Make webcam overlay larger)
        res = cc.check_key_conflict("SUPER + ALT + ]")
        self.assertTrue(res["valid"])
        self.assertTrue(res["conflict"])
        self.assertIn("webcam", res["owner"].lower())

    def test_defaults_applied_on_first_run(self):
        # Empty/non-existent settings should return default keybindings
        self.tmp_settings.unlink(missing_ok=True)
        s = cc.read_settings()
        kb = s.get("keybindings", {})
        self.assertEqual(kb.get(""), "SUPER + BACKSLASH")
        self.assertEqual(kb.get("full"), "SUPER + BRACKETRIGHT")
        self.assertEqual(kb.get("window"), "")
        self.assertEqual(kb.get("region"), "SUPER + BRACKETLEFT")
        self.assertEqual(kb.get("region-ocr"), "SUPER + SHIFT + BRACKETLEFT")

    def test_check_system_conflict(self):
        res = cc.check_key_conflict("SUPER + RETURN")
        self.assertTrue(res["valid"])
        self.assertTrue(res["conflict"])
        self.assertEqual(res["owner_scope"], "system")
        self.assertIn("suggestions_for_user", res)
        self.assertIn("suggestions_for_conflicting", res)

    def test_apply_free_chord(self):
        payload = {
            "mode": "region",
            "chord": "SUPER + ALT + C",
            "resolution_type": "none"
        }
        res = cc.handle_apply(payload)
        self.assertTrue(res["success"])
        self.assertEqual(res["keybindings"]["region"], "SUPER + ALT + C")
        self.assertEqual(res["conflict_resolutions"], {})

    def test_apply_reassign_conflict(self):
        payload = {
            "mode": "full",
            "chord": "SUPER + RETURN",
            "resolution_type": "reassign",
            "reassigned_chord": "SUPER + ALT + T",
            "conflicting_owner": "Terminal",
            "conflicting_scope": "system"
        }
        res = cc.handle_apply(payload)
        self.assertTrue(res["success"])
        self.assertEqual(res["keybindings"]["full"], "SUPER + RETURN")
        self.assertIn("full", res["conflict_resolutions"])
        self.assertEqual(res["conflict_resolutions"]["full"]["action_type"], "reassign")
        self.assertEqual(res["conflict_resolutions"]["full"]["reassigned_chord"], "SUPER + ALT + T")

        # Check bindings.lua contains unbind and reassign
        content = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertIn('hl.unbind("SUPER + RETURN")', content)
        self.assertIn('SUPER + ALT + T', content)
        self.assertIn('SUPER + RETURN', content)

    def test_remove_keybinding_resets_conflict(self):
        # 1. Apply conflict reassign
        payload = {
            "mode": "full",
            "chord": "SUPER + RETURN",
            "resolution_type": "reassign",
            "reassigned_chord": "SUPER + ALT + T",
            "conflicting_owner": "Terminal",
            "conflicting_scope": "system"
        }
        cc.handle_apply(payload)

        # 2. Remove keybinding for full
        res_remove = cc.handle_remove({"mode": "full"})
        self.assertTrue(res_remove["success"])
        self.assertEqual(res_remove["keybindings"]["full"], "")
        self.assertNotIn("full", res_remove["conflict_resolutions"])

        # Check bindings.lua no longer contains unbind or reassignment
        content = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertNotIn('hl.unbind("SUPER + RETURN")', content)
        self.assertNotIn('SUPER + ALT + T', content)

    def test_change_keybinding_with_prior_conflict_reset(self):
        # 1. Apply conflict takeover
        payload = {
            "mode": "full",
            "chord": "SUPER + RETURN",
            "resolution_type": "takeover",
            "conflicting_owner": "Terminal",
            "conflicting_scope": "system"
        }
        cc.handle_apply(payload)

        # 2. Change full to a new chord and reset prior conflict
        payload_change = {
            "mode": "full",
            "chord": "SUPER + ALT + C",
            "resolution_type": "none",
            "reset_previous_conflict": True
        }
        res_change = cc.handle_apply(payload_change)
        self.assertTrue(res_change["success"])
        self.assertEqual(res_change["keybindings"]["full"], "SUPER + ALT + C")
        self.assertNotIn("full", res_change["conflict_resolutions"])

        content = self.tmp_bindings.read_text(encoding="utf-8")
        self.assertNotIn('hl.unbind("SUPER + RETURN")', content)
        self.assertIn('SUPER + ALT + C', content)

    def test_camel_case_conflict_resolutions_sync(self):
        # Verify both conflictResolutions (camelCase) and conflict_resolutions (snake_case) stay in sync
        self.tmp_settings.write_text(json.dumps({
            "keybindings": {"full": "SUPER + RETURN"},
            "conflictResolutions": {"full": {"owner": "Terminal", "owner_scope": "system"}}
        }), encoding="utf-8")
        s = cc.read_settings()
        self.assertIn("full", s["conflict_resolutions"])
        self.assertEqual(s["conflict_resolutions"]["full"]["owner"], "Terminal")

        cc.write_settings({"conflict_resolutions": {"window": {"owner": "Test"}}})
        saved = json.loads(self.tmp_settings.read_text(encoding="utf-8"))
        self.assertEqual(saved["conflictResolutions"], {"window": {"owner": "Test"}})
        self.assertEqual(saved["conflict_resolutions"], {"window": {"owner": "Test"}})

    def test_extract_description(self):
        self.assertEqual(
            cc.extract_description_from_line("o.bind", '"Terminal", { omarchy = "terminal" }', 'o.bind("SUPER + RETURN", "Terminal", { omarchy = "terminal" })'),
            "Terminal"
        )
        self.assertEqual(
            cc.extract_description_from_line("hl.bind", 'hl.dsp.global("bramvanoploo.omaguake:toggle")', 'hl.bind("CTRL + SPACE", hl.dsp.global("bramvanoploo.omaguake:toggle"), { dont_inhibit = true })'),
            "omaguake (toggle)"
        )
        self.assertEqual(
            cc.extract_description_from_line("o.bind", '"Save", hl.dsp.send_shortcut({ mods = "CTRL", key = "s" })', 'o.bind("SUPER + S", "Save", ...)'),
            "Save"
        )

if __name__ == "__main__":
    unittest.main()
