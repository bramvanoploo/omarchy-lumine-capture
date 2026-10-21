import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

QtObject {
  id: root

  property string pluginDir: ""
  readonly property string homeDir: Quickshell.env("HOME") || ""
  property string version: "0.1.0"
  readonly property string pluginId: "bramvanoploo.omarchy-lumine-capture"
  readonly property string configPath: (homeDir ? homeDir : "~") + "/.config/omarchy/plugins/" + pluginId + "/settings.json"
  readonly property string conflictCheckerScript: pluginDir + "/scripts/conflict-checker.py"
  readonly property string installScript: pluginDir + "/scripts/install-dependency.sh"

  property string keybinding: "SUPER + SHIFT + S"
  property string launchArgs: ""

  signal settingsChanged()

  function loadSettings(raw) {
    if (!raw || !raw.trim()) { applyDefaults(); return }
    try {
      var data = JSON.parse(raw)
      if (data.keybinding !== undefined) keybinding = String(data.keybinding)
      if (data.launchArgs !== undefined) launchArgs = String(data.launchArgs)
    } catch (e) {
      applyDefaults()
    }
  }

  function applyDefaults() {
    keybinding = "SUPER + SHIFT + S"
    launchArgs = ""
  }

  function saveSettings(obj) {
    if (obj.keybinding !== undefined) keybinding = String(obj.keybinding)
    if (obj.launchArgs !== undefined) launchArgs = String(obj.launchArgs)
    settingsFile.setText(JSON.stringify({
      keybinding: keybinding,
      launchArgs: launchArgs
    }, null, 2) + "\n")
    settingsChanged()
  }

  property var _settingsFile: FileView {
    id: settingsFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.applyDefaults()
    onFileChanged: reload()
  }

  property var _manifestFile: FileView {
    path: root.pluginDir + "/manifest.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var m = JSON.parse(text())
        if (m && m.version) root.version = String(m.version)
      } catch (e) {}
    }
  }
}
