import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LaunchArgs.js" as LaunchArgs

BarWidget {
  id: root
  moduleName: "bramvanoploo.omarchy-lumine-capture"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "")

  ConfigManager {
    id: config
    pluginDir: root.pluginDir
  }

  property bool settingsOpen: false
  property bool panelOpen: false
  property bool depDialogOpen: false
  property bool isInstalled: false
  property bool yayMissing: false
  property bool isInstalling: false
  property bool pendingOpen: false
  property string pendingMode: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: checkInstalledProc
    command: ["pacman", "-Q", "lumine-capture-bin"]
    onExited: function(exitCode) {
      root.isInstalled = (exitCode === 0)
      if (root.pendingOpen) {
        root.pendingOpen = false
        if (root.isInstalled) {
          root.launchCapture(root.pendingMode)
        } else {
          checkYayProc.running = true
          root.depDialogOpen = true
        }
      }
    }
  }

  Process {
    id: checkYayProc
    command: ["bash", "-c", "command -v yay"]
    onExited: function(exitCode) { root.yayMissing = (exitCode !== 0) }
  }

  Process {
    id: launchProc
    property string cmd: "lumine-capture"
    command: ["bash", "-c", cmd]
  }

  // "" means the mode from the launch options — the legacy entry points
  // (bar keyboard, IPC) keep honoring the Mode setting.
  function launchCapture(mode) {
    var args = (mode === undefined || mode === "")
      ? config.launchArgs
      : (config.perModeArgs[mode] !== undefined ? config.perModeArgs[mode] : "")
    launchProc.cmd = ("lumine-capture " + args).trim()
    launchProc.running = true
  }

  function checkAndOpen(mode) {
    if (root.isInstalling) return
    if (root.isInstalled) {
      root.launchCapture(mode)
      return
    }
    root.pendingOpen = true
    root.pendingMode = mode || ""
    if (!checkInstalledProc.running) checkInstalledProc.running = true
  }

  function startInstallation() {
    root.depDialogOpen = false
    root.isInstalling = true
    Quickshell.execDetached([config.installScript])
  }

  function toggleSettings() {
    panelOpen = false
    settingsOpen = !settingsOpen
  }

  function togglePanel() {
    settingsOpen = false
    panelOpen = !panelOpen
  }

  function close() {
    settingsOpen = false
    panelOpen = false
    depDialogOpen = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf030"
    slotSize: Style.bar.iconSlot
    tooltipText: "OmaLumineCapture"

    onPressed: function(button) {
      if (button === Qt.RightButton) {
        root.toggleSettings()
      } else if (button === Qt.LeftButton) {
        root.togglePanel()
      }
    }
  }

  // Where shots land: the Output option when set, else lumine-capture's
  // default (its config's relative "screenshots" under the Pictures dir).
  readonly property string screenshotsDir: {
    if (config.expandedOutput !== "") return config.expandedOutput
    var home = Quickshell.env("HOME")
    return (home ? home : "~") + "/Pictures/screenshots"
  }

  ModePanel {
    id: modePanel
    configManager: config
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.panelOpen
    triggerMode: "click"
    chords: config.keybindings
    onPicked: function(mode) {
      root.panelOpen = false
      root.checkAndOpen(mode)
    }
    onSettingsRequested: {
      root.panelOpen = false
      root.settingsOpen = true
    }
    onScreenshotsRequested: Qt.openUrlExternally("file://" + root.screenshotsDir)
  }

  SettingsOverlay {
    id: settingsPopup
    anchorItem: root
    bar: root.bar
    owner: root
    configManager: config
    isInstalled: root.isInstalled
    open: root.settingsOpen
  }

  DependencyDialog {
    id: dependencyDialog
    open: root.depDialogOpen
    yayMissing: root.yayMissing
    onCanceled: { root.depDialogOpen = false }
    onConfirmed: { root.startInstallation() }
  }

  IpcHandler {
    target: "omalumine.bar"
    function toggleSettings(): void { root.toggleSettings() }
    function openSettings(): void { root.settingsOpen = true }
    function closeSettings(): void { root.settingsOpen = false }
    function checkAndOpen(): void { root.checkAndOpen("") }
    function captureMode(mode: string): void { root.checkAndOpen(mode) }
    function openPanel(): void { root.settingsOpen = false; root.panelOpen = true }
    function closePanel(): void { root.panelOpen = false }
    function openScreenshots(): void { Qt.openUrlExternally("file://" + root.screenshotsDir) }
    function openDependencyDialog(): void { root.depDialogOpen = true }
    function closeDependencyDialog(): void { root.depDialogOpen = false }
    function installDone(): void {
      root.isInstalling = false
      root.isInstalled = true
      root.launchCapture(root.pendingMode)
    }
    function resetInstallState(): void {
      root.isInstalling = false
      checkInstalledProc.running = true
    }
    function openRecorder(): void { settingsPopup.openRecorder("") }
    function themeInfo(): string {
      return JSON.stringify({ theme: config.themeName, status: config.themeStatus })
    }
    function syncTheme(): void { config.syncTheme(true) }
  }
}
