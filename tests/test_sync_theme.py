#!/usr/bin/env python3
import unittest
import sys
import tempfile
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import importlib
st = importlib.import_module("sync-theme")


class TestSyncTheme(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.orig_colors = st.COLORS_TOML
        self.orig_shell = st.SHELL_TOML
        self.orig_theme_name = st.THEME_NAME_FILE
        self.orig_lc_config = st.LC_CONFIG
        self.orig_state = st.STATE_FILE

        st.COLORS_TOML = self.root / "colors.toml"
        st.SHELL_TOML = self.root / "shell.toml"
        st.THEME_NAME_FILE = self.root / "theme.name"
        st.LC_CONFIG = self.root / "config.toml"
        st.STATE_FILE = self.root / ".theme-sync.json"

        st.COLORS_TOML.write_text('bg = "#1e1e2e"\nfg = "#cdd6f4"\naccent = "#89b4fa"\n', encoding="utf-8")
        st.SHELL_TOML.write_text('[bar]\nbackground-alpha = 0.9\n', encoding="utf-8")
        st.THEME_NAME_FILE.write_text("catppuccin\n", encoding="utf-8")

    def tearDown(self):
        st.COLORS_TOML = self.orig_colors
        st.SHELL_TOML = self.orig_shell
        st.THEME_NAME_FILE = self.orig_theme_name
        st.LC_CONFIG = self.orig_lc_config
        st.STATE_FILE = self.orig_state
        self.tmpdir.cleanup()

    def test_sync_creates_and_is_idempotent(self):
        res1 = st.do_sync(force=True)
        self.assertTrue(res1["success"])
        self.assertTrue(res1["changed"])
        content = st.LC_CONFIG.read_text(encoding="utf-8")
        self.assertIn("# Colors below are synced from the Omarchy theme by OmaLumineCapture: catppuccin", content)
        self.assertIn('accent = "#89b4fa"', content)

        # Second sync with same content reports changed=False even with force=True
        res2 = st.do_sync(force=True)
        self.assertTrue(res2["success"])
        self.assertFalse(res2["changed"])

    def test_preserves_other_sections_and_comments(self):
        st.LC_CONFIG.write_text(
            '# User header\n[general]\nto = "cs"\n\n[theme]\nfont_size = 14\n',
            encoding="utf-8",
        )
        res = st.do_sync(force=True)
        self.assertTrue(res["success"])
        content = st.LC_CONFIG.read_text(encoding="utf-8")
        self.assertIn('# User header', content)
        self.assertIn('to = "cs"', content)
        self.assertIn('font_size = 14', content)
        self.assertIn('accent = "#89b4fa"', content)


if __name__ == "__main__":
    unittest.main()
