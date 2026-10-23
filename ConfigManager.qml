import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "LaunchArgs.js" as LaunchArgs
import "LumineConfig.js" as LumineConfig

QtObject {
  id: root

  property string pluginDir: ""
  readonly property string homeDir: Quickshell.env("HOME") || ""
  property string version: "0.2.0"
  readonly property string pluginId: "bramvanoploo.omarchy-lumine-capture"
  readonly property string configPath: (homeDir ? homeDir : "~") + "/.config/omarchy/plugins/" + pluginId + "/settings.json"
  readonly property string conflictCheckerScript: pluginDir + "/scripts/conflict-checker.py"
  readonly property string installScript: pluginDir + "/scripts/install-dependency.sh"
  readonly property string themeSyncScript: pluginDir + "/scripts/sync-theme.py"
  readonly property string themeNameFile: (homeDir ? homeDir : "~") + "/.local/state/omarchy/current/theme.name"

  // One global shortcut per capture mode; the keys are the mode values of
  // LaunchArgs.MODES, "" is the editor. "" = that mode has no shortcut.
  // The old single "keybinding" setting is migrated to the editor mode.
  // There is no shipped default: the user records their own after installing.
  property var keybindings: ({ "": "", "full": "", "window": "", "region": "", "region-ocr": "" })

  // One property per lumine-capture command line option the panel exposes.
  // LaunchArgs.js is what turns them into arguments, and reads them back.
  property string mode: ""               // "" editor | full | window | region | region-ocr
  property bool monitor: false           // -m, --monitor
  property string delay: ""              // -d, --delay <SECONDS>; "" = no flag
  property string to: ""                 // -t, --to <LETTERS>; "" = general.to of the app
  // general.to read from the app's own config, for the panel to show what an
  // untouched "Send to" means. "" when the app config is missing or has no to.
  property string appTo: ""
  property bool toNothing: false         // -t bare: do nothing by default
  property string output: ""             // -o, --output <DIR>; "" = the app's own folder
  property bool nonotify: false          // -n, --nonotify
  property string ocrDaemon: ""          // --ocr-daemon serve|status|stop|calibrate
  property string extraArgs: ""          // settings.json only: flags the panel has no control for

  // The output directory as lumine-capture should see it: "~" means the home
  // directory to a shell, and to nothing at all in a Hyprland exec command.
  readonly property string expandedOutput: {
    var p = output
    if (p === "~" || p.indexOf("~/") === 0) return (homeDir ? homeDir : "~") + p.slice(1)
    return p
  }

  readonly property var built: LaunchArgs.buildArgs({
    mode: mode,
    monitor: monitor,
    delay: delay,
    to: to,
    toNothing: toNothing,
    output: expandedOutput,
    nonotify: nonotify,
    ocrDaemon: ocrDaemon,
    extraArgs: extraArgs
  })

  // What the bar icon and the global keybinding run after `lumine-capture`.
  readonly property string launchArgs: built.args
  readonly property var launchWarnings: built.warnings

  // The same options per shortcut mode: {mode value: arguments}. Each binding
  // runs the global options with its own mode, built by the same LaunchArgs
  // code the settings panel warns with.
  readonly property var perModeArgs: buildPerModeArgs()

  function buildPerModeArgs() {
    var opts = {
      mode: mode,
      monitor: monitor,
      delay: delay,
      to: to,
      toNothing: toNothing,
      output: expandedOutput,
      nonotify: nonotify,
      ocrDaemon: ocrDaemon,
      extraArgs: extraArgs
    }
    var out = {}
    var list = LaunchArgs.MODES
    for (var i = 0; i < list.length; i++)
      out[list[i].value] = LaunchArgs.buildArgsForMode(opts, list[i].value).args
    return out
  }

  // LumineCapture mirrors the Omarchy theme. The poller re-runs the sync script
  // on a timer: cheap (it exits when the theme fingerprint is unchanged) and it
  // survives Omarchy replacing the theme files atomically.
  property string themeName: ""
  property string themeStatus: ""

  signal settingsChanged()

  function syncTheme(force) {
    themeSyncProc.command = [themeSyncScript, force ? "--force" : "--check"]
    themeSyncProc.running = true
  }

  property var _themeSyncProc: Process {
    id: themeSyncProc
    command: ["true"]
    stdout: StdioCollector { id: themeSyncOut }
    onExited: function(code) {
      var res = null
      try { res = JSON.parse(themeSyncOut.text) } catch (e) {}
      if (!res || !res.success) {
        themeStatus = (res && res.error) ? res.error : "Theme sync failed."
      } else if (res.changed) {
        themeStatus = "LumineCapture colors updated from the Omarchy theme"
                      + (res.theme ? " (" + res.theme + ")." : ".")
      } else {
        themeStatus = "LumineCapture already matches the Omarchy theme."
      }
    }
  }

  property var _themeTimer: Timer {
    interval: 4000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.syncTheme(false)
  }

  // Store as the user typed it: a half-written "3," shows up in the field and
  // the launcher warns about it, instead of silently vanishing.
  function setDelay(raw) {
    delay = String(raw === undefined || raw === null ? "" : raw).trim()
  }

  // Read a whole command line into the options. Older settings kept one free
  // text field of launch arguments; migrating is this, applied once on load.
  function applyLaunchArgs(raw) {
    var o = LaunchArgs.parseArgs(raw)
    mode = o.mode
    monitor = o.monitor
    delay = o.delay
    to = o.to
    toNothing = o.toNothing
    output = o.output
    nonotify = o.nonotify
    ocrDaemon = o.ocrDaemon
    extraArgs = o.extraArgs
  }

  function optionKeys() {
    return ["mode", "monitor", "delay", "to", "toNothing", "output", "nonotify", "ocrDaemon", "extraArgs"]
  }

  function loadSettings(raw) {
    if (!raw || !raw.trim()) { applyDefaults(); return }
    try {
      var data = JSON.parse(raw)
      if (data.keybindings !== undefined) {
        keybindings = normalizeKeybindings(data.keybindings)
      } else if (data.keybinding !== undefined) {
        // Pre-per-mode settings: the one shortcut belonged to the editor.
        keybindings = normalizeKeybindings({ "": String(data.keybinding) })
      }

      var keys = optionKeys()
      var structured = false
      for (var i = 0; i < keys.length; i++) {
        if (data[keys[i]] !== undefined) { structured = true; break }
      }

      if (structured) {
        if (data.mode !== undefined) mode = String(data.mode)
        if (data.monitor !== undefined) monitor = (data.monitor === true)
        setDelay(data.delay)
        if (data.to !== undefined) to = LaunchArgs.toLetters(data.to)
        if (data.toNothing !== undefined) toNothing = (data.toNothing === true)
        if (data.output !== undefined) output = LaunchArgs.cleanPath(data.output)
        if (data.nonotify !== undefined) nonotify = (data.nonotify === true)
        if (data.ocrDaemon !== undefined) ocrDaemon = String(data.ocrDaemon)
        if (data.extraArgs !== undefined) extraArgs = String(data.extraArgs)
      } else if (data.launchArgs !== undefined) {
        // Pre-option settings: split the free text into the options it used.
        applyLaunchArgs(String(data.launchArgs))
      }
    } catch (e) {
      applyDefaults()
    }
  }

  function normalizeKeybindings(src) {
    // Plain JS object with every mode key present, chords trimmed.
    var out = {}
    var list = LaunchArgs.MODES
    src = src || {}
    for (var i = 0; i < list.length; i++) {
      var v = src[list[i].value]
      out[list[i].value] = (v === undefined || v === null) ? "" : String(v).trim()
    }
    return out
  }

  function applyDefaults() {
    keybindings = ({ "": "", "full": "", "window": "", "region": "", "region-ocr": "" })
    mode = ""
    monitor = false
    delay = ""
    to = ""
    toNothing = false
    output = ""
    nonotify = false
    ocrDaemon = ""
    extraArgs = ""
  }

  function settingsObject() {
    return {
      keybindings: keybindings,
      mode: mode,
      monitor: monitor,
      delay: delay,
      to: to,
      toNothing: toNothing,
      output: output,
      nonotify: nonotify,
      ocrDaemon: ocrDaemon,
      extraArgs: extraArgs
    }
  }

  function saveSettings(obj) {
    obj = obj || {}
    if (obj.keybindings !== undefined) keybindings = normalizeKeybindings(obj.keybindings)
    if (obj.mode !== undefined) mode = String(obj.mode)
    if (obj.monitor !== undefined) monitor = (obj.monitor === true)
    if (obj.delay !== undefined) setDelay(obj.delay)
    if (obj.to !== undefined) to = LaunchArgs.toLetters(obj.to)
    if (obj.toNothing !== undefined) toNothing = (obj.toNothing === true)
    if (obj.output !== undefined) output = LaunchArgs.cleanPath(obj.output)
    if (obj.nonotify !== undefined) nonotify = (obj.nonotify === true)
    if (obj.ocrDaemon !== undefined) ocrDaemon = String(obj.ocrDaemon)
    if (obj.extraArgs !== undefined) extraArgs = String(obj.extraArgs)
    settingsFile.setText(JSON.stringify(settingsObject(), null, 2) + "\n")
    settingsChanged()
  }

  function resetOptions() {
    var d = LaunchArgs.defaultOptions()
    mode = d.mode
    monitor = d.monitor
    delay = d.delay
    to = d.to
    toNothing = d.toNothing
    output = d.output
    nonotify = d.nonotify
    ocrDaemon = d.ocrDaemon
    extraArgs = d.extraArgs
    settingsFile.setText(JSON.stringify(settingsObject(), null, 2) + "\n")
    settingsChanged()
  }

  // FileView never loads by itself — without these the persisted settings
  // and the manifest version stayed empty at shell start.
  Component.onCompleted: {
    settingsFile.reload()
    manifestFile.reload()
    appConfigFile.reload()
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

  property var _themeNameFile: FileView {
    path: root.themeNameFile
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.themeName = text().trim()
    onLoadFailed: root.themeName = ""
    onFileChanged: reload()
  }

  // The app's config is the source of truth for its defaults; we read it, never write it.
  property var _appConfigFile: FileView {
    id: appConfigFile
    path: (homeDir ? homeDir : "~") + "/.config/LumineCapture/config.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.appTo = LumineConfig.value(text(), "general", "to")
    onLoadFailed: root.appTo = ""
    onFileChanged: reload()
  }

  property var _manifestFile: FileView {
    id: manifestFile
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
