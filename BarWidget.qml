import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "bramvanoploo.omarchy-lumine-capture"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "")

  ConfigManager {
    id: config
    pluginDir: root.pluginDir
  }

  property bool settingsOpen: false
  property bool depDialogOpen: false
  property bool isInstalled: false
  property bool yayMissing: false
  property bool isInstalling: false
  property bool pendingOpen: false

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
          root.launchCapture()
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

  function launchCapture() {
    launchProc.cmd = ("lumine-capture " + config.launchArgs).trim()
    launchProc.running = true
  }

  function checkAndOpen() {
    if (root.isInstalling) return
    if (root.isInstalled) {
      root.launchCapture()
      return
    }
    root.pendingOpen = true
    if (!checkInstalledProc.running) checkInstalledProc.running = true
  }

  function startInstallation() {
    root.depDialogOpen = false
    root.isInstalling = true
    Quickshell.execDetached([config.installScript])
  }

  function toggleSettings() { settingsOpen = !settingsOpen }

  function close() {
    settingsOpen = false
    depDialogOpen = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf030"
    slotSize: Style.bar.iconSlot
    tooltipText: {
      var state = root.isInstalled ? "" : (root.isInstalling ? " (installing...)" : " (not installed)")
      var chord = config.keybinding ? " [" + config.keybinding + "]" : ""
      return "LumineCapture" + chord + state
    }

    onPressed: function(button) {
      if (button === Qt.RightButton) {
        root.toggleSettings()
      } else if (button === Qt.LeftButton) {
        root.checkAndOpen()
      }
    }
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
    function checkAndOpen(): void { root.checkAndOpen() }
    function openDependencyDialog(): void { root.depDialogOpen = true }
    function closeDependencyDialog(): void { root.depDialogOpen = false }
    function installDone(): void {
      root.isInstalling = false
      root.isInstalled = true
      root.pendingOpen = true
      root.launchCapture()
    }
    function resetInstallState(): void {
      root.isInstalling = false
      checkInstalledProc.running = true
    }
    function openRecorder(): void { settingsPopup.openRecorder() }
    function themeInfo(): string {
      return JSON.stringify({ theme: config.themeName, status: config.themeStatus })
    }
    function syncTheme(): void { config.syncTheme(true) }
  }

  Component.onCompleted: {
    checkInstalledProc.running = true
    checkYayProc.running = true
  }
}
