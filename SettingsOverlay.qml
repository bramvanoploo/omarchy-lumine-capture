import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "LaunchArgs.js" as LaunchArgs
import "ui" as LocalUi

// A centered full-screen overlay, the way OmaLumine's Apple-commands panel
// does it: a dim scrim over the whole screen, the card floating in the middle.
Item {
  id: root

  property var configManager: null
  property bool isInstalled: false
  // The bar this panel belongs to: its foreground tints the section headers.
  property var bar: null

  property var keybindings: ({ "": "", "full": "", "window": "", "region": "", "region-ocr": "" })
  // Which capture mode the record dialog is assigning a shortcut for.
  property string recordingMode: ""
  property alias reapplyTimer: reapplyTimer

  // Mirrors of the launch options in ConfigManager, edited here and written
  // back one at a time.
  property bool monitor: false
  property string delay: ""
  property string to: ""
  property bool toNothing: false
  property string output: ""
  property bool nonotify: false

  // Daemon preference: "serve" runs it on launch and the knob follows that
  // intent, so the daemon's 15-minute idle exit never flips the knob by itself.
  readonly property bool daemonOn: configManager ? configManager.ocrDaemon === "serve" : false

  // Where shots actually go: the Output folder when set, else
  // lumine-capture's default (its "screenshots" dir under the Pictures dir).
  readonly property string effectiveOutput: {
    if (configManager && configManager.expandedOutput !== "") return configManager.expandedOutput
    if (configManager && configManager.defaultOutput !== "") return configManager.defaultOutput
    var home = Quickshell.env("HOME")
    return (home ? home : "~") + "/Pictures/screenshots"
  }

  // Checkboxes show the app's own general.to while the option is empty, the
  // way the Output folder shows the effective path. Derived, not seeded: the
  // app config arrives on its own FileView, later than the settings file.
  readonly property var toSelection: (to !== "" ? to
    : (configManager ? configManager.effectiveTo : "cs")).split("")

  // What the app itself is set to do, read from general.to of its own config.
  // The panel shows it while "Send to" holds no user choice, the way the
  // Output folder shows the resolved default.
  readonly property string appToSend: LaunchArgs.toLabels(
    configManager ? configManager.appTo || "" : "")

  property string zenityPath: ""
  property bool zenityAskOpen: false
  // Set when the user confirms the zenity install: the next zenity check that
  // finds the binary opens the folder picker on its own (m00440: no manual
  // re-click of Browse after installing).
  property bool zenityPendingBrowse: false
  property bool ocrBusy: false
  // "" = never checked, "checking", "running", "stopped" — feeds the header
  // subtitle, which is where the daemon status lives now.
  property string ocrStatus: ""
  property string pendingOcrAction: ""

  property string statusText: ""

  // Keybinding custom dialog state
  property bool recordingDialogOpen: false

  // Open state, driven by the bar widget (clicks, IPC).
  property bool open: false

  onOpenChanged: {
    if (open) {
      loadCurrentSettings()
      refreshStatus()
      refreshOcrStatus()
      statusText = ""
      checkZenityProc.running = true
      Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() })
    } else {
      recordingDialogOpen = false
      zenityAskOpen = false
    }
  }

  // The launch options decide what the global shortcut runs, and they can move
  // without the panel being involved: settings.json edited by hand, an upgrade
  // that adds options, a hyprland config reset. So the shortcut is re-applied a
  // moment after start. conflict-checker.py leaves the file untouched when the
  // block already runs this command, so a start with nothing to fix leaves the
  // compositor alone.
  Component.onCompleted: reapplyTimer.restart()

  // Emitted when the user closes the overlay; the owner must reset its own
  // open flag, because assigning root.open here would break the two-way
  // binding and leave the panel unopenable.
  signal closed()
  // The panel sits on the overlay layer, so external windows (the zenity
  // picker, the foot install terminal) can never rise above it. They close
  // it up front and ask BarWidget to reopen it when the flow ends.
  signal externalFlowDone()

  function close() {
    root.closed()
  }

  function loadCurrentSettings() {
    if (!configManager) return
    keybindings = copyKeybindings(configManager.keybindings)
    monitor = configManager.monitor === true
    delay = configManager.delay || ""
    to = configManager.to || ""
    toNothing = configManager.toNothing === true
    output = configManager.output || ""
    nonotify = configManager.nonotify === true
  }

  // The launch options LumineCapture will be started with.
  readonly property string launchArgs: configManager ? configManager.launchArgs : ""
  readonly property var launchWarnings: {
    if (!configManager || !configManager.launchWarnings) return []
    return configManager.launchWarnings.filter(function(w) {
      return !w.toLowerCase().startsWith("the daemon action")
    })
  }

  function formatChordDisplay(chord) {
    if (!chord) return ""
    return chord
      .replace(/\bBRACKETRIGHT\b/g, "]")
      .replace(/\bBRACKETLEFT\b/g, "[")
      .replace(/\bMINUS\b/g, "-")
      .replace(/\bEQUAL\b/g, "=")
      .replace(/\bSEMICOLON\b/g, ";")
      .replace(/\bAPOSTROPHE\b/g, "'")
      .replace(/\bCOMMA\b/g, ",")
      .replace(/\bPERIOD\b/g, ".")
      .replace(/\bSLASH\b/g, "/")
      .replace(/\bBACKSLASH\b/g, "\\")
      .replace(/\bGRAVE\b/g, "`")
  }

  readonly property string ocrStatusText: {
    if (ocrStatus === "checking") return "OCR daemon: checking\u2026"
    if (ocrStatus === "running") return "OCR daemon: running"
    if (ocrStatus === "busy") {
      if (pendingOcrAction === "calibrate") return "OCR daemon: measuring this machine, a few seconds\u2026"
      return "OCR daemon: " + pendingOcrAction + "\u2026"
    }
    if (ocrStatus === "stopped") {
      if (daemonOn) return "OCR daemon: enabled (idle/standby)"
      return "OCR daemon: disabled"
    }
    return ""
  }

  function refreshStatus() {
    if (!configManager) return
    statusProc.command = [configManager.conflictCheckerScript, "status"]
    statusProc.running = true
  }

  function copyKeybindings(src) {
    // Own plain object, so assigning one chord always counts as a change.
    src = src || {}
    var out = {}
    var list = LaunchArgs.MODES
    for (var i = 0; i < list.length; i++) {
      var v = src[list[i].value]
      out[list[i].value] = (v === undefined || v === null) ? "" : String(v).trim()
    }
    return out
  }

  function modeName(mode) {
    var list = LaunchArgs.MODES
    for (var i = 0; i < list.length; i++)
      if (list[i].value === mode) return list[i].label
    return mode
  }

  function hasConflictResolution(mode) {
    if (!configManager || !configManager.conflictResolutions) return false
    return !!configManager.conflictResolutions[mode]
  }

  function openRecorder(mode) {
    if (mode === "window") return
    recordingMode = mode
    recordingDialogOpen = true
  }

  property bool isRemovingKey: false

  function removeKeybinding(mode) {
    if (!configManager || isRemovingKey) return
    isRemovingKey = true

    // Optimistically update UI immediately so removal is instantaneous
    var next = root.copyKeybindings(root.keybindings)
    next[mode] = ""
    root.keybindings = next

    var payload = {
      mode: mode,
      args_by_mode: configManager.perModeArgs
    }
    removeProc.command = [configManager.conflictCheckerScript, "remove-key", JSON.stringify(payload)]
    removeProc.running = true
  }

  function saveOption(key, value) {
    if (!configManager) return
    var patch = {}
    patch[key] = value
    configManager.saveSettings(patch)
    loadCurrentSettings()
    reapplyTimer.restart()
  }

  property bool pendingSync: false

  function reapplyKeybinding() {
    if (!configManager) return
    if (syncProc.running) {
      pendingSync = true
      return
    }
    pendingSync = false
    var payload = {
      args_by_mode: configManager.perModeArgs
    }
    syncProc.command = [configManager.conflictCheckerScript, "sync", JSON.stringify(payload)]
    syncProc.running = true
  }

  function saveToLetters(values) {
    var letters = LaunchArgs.toLetters(values)
    to = letters
    saveOption("to", letters)
  }

  function setOutputText(text) {
    var t = String(text || "").trim()
    // If the field still holds the resolved default path while the setting itself
    // was empty, keep it empty so the user's config stays on the app default.
    if (output === "" && t === effectiveOutput) return
    output = t
    saveOption("output", t)
  }

  function browseOutput() {
    if (!zenityPath) {
      zenityAskOpen = true
      return
    }
    var start = configManager ? configManager.expandedOutput : ""
    browseProc.command = [zenityPath, "--file-selection", "--directory",
                          "--title=Where should the shots be saved?",
                          "--filename=" + (start || (Quickshell.env("HOME") || "/")) + "/"]
    root.closed()
    browseProc.running = true
  }

  // Closes the confirmation, then runs sudo pacman in a foot window. The foot
  // client stays alive until its window closes, so installZenityProc.onExited
  // is exactly "the installation terminal dialog has closed"; it re-checks
  // for zenity, whose onExited hook opens the picker when the install worked.
  function installZenity() {
    if (installZenityProc.running)
      return
    zenityAskOpen = false
    zenityPendingBrowse = true
    root.closed()
    installZenityProc.running = true
  }

  // serve outlives the panel, so it goes out detached; the rest answer on
  // stdout, which updates the daemon status in the header subtitle.
  function runOcrDaemon(action) {
    if (!configManager || ocrBusy) return
    if (action === "serve") {
      Quickshell.execDetached(["lumine-capture", "--ocr-daemon", "serve"])
      ocrStatus = "busy"; pendingOcrAction = "serve"
      ocrStatusTimer.restart()
      return
    }
    ocrBusy = true
    pendingOcrAction = action
    ocrStatus = "busy"
    ocrProc.command = ["lumine-capture", "--ocr-daemon", action]
    ocrProc.running = true
  }

  function applyOcrStatus(code, stdout) {
    // Quickshell Process can deliver null/empty stdout on onExited; the
    // "not running" regex would then stick the state at "running" forever.
    // Fall back to the exit code: 0 = running, non-zero = not running.
    var out = (stdout === undefined || stdout === null) ? "" : String(stdout)
    // Through the IPC bridge a null stdout arrives as the literal string "null";
    // judged as text it reads "not the stopped wording" -> false "running".
    if (out.trim() === "null") out = ""
    if (out !== "")
      ocrStatus = /not running|inactive|stopped|no daemon/i.test(out) ? "stopped" : "running"
    else if (code === 0) ocrStatus = "running"
    else ocrStatus = "stopped"
  }

  function refreshOcrStatus() {
    ocrStatus = "checking"
    ocrStatusProc.command = ["lumine-capture", "--ocr-daemon", "status"]
    ocrStatusProc.running = true
  }

  // =========================================================================
  // THE OVERLAY
  // =========================================================================
  PanelWindow {
    id: overlayWindow
    visible: root.open
    // Sit on the screen the bar lives on.
    screen: root.QsWindow && root.QsWindow.window
            ? root.QsWindow.window.screen : null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "lumine-capture-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open
                                   ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Escape closes the overlay; the record or zenity dialog answers it first.
    Item {
      id: panelKeyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.zenityAskOpen) { root.zenityAskOpen = false; Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() }) }
          else if (root.recordingDialogOpen) { root.recordingDialogOpen = false; Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() }) }
          else root.close()
          event.accepted = true
        }
      }
    }

    // Scrim: the screen behind goes quiet, a click here closes the panel.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.65)

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    // The card, centred.
    BorderSurface {
      id: settingsCard
      anchors.centerIn: parent
      width: Math.min(Style.space(760), parent.width - Style.space(48))
      height: Math.min(Style.space(600), parent.height - Style.space(48))
      color: Color.popups.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      radius: Style.cornerRadius

      // Swallow clicks on the card so the scrim never sees them.
      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: cardHead
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(24)
        height: headBlock.implicitHeight
        // Header: title row + separator, stacked top-down (Column inside an
        // Item ignores anchors; this container hosts the modal as a sibling).
        Column {
          id: headBlock
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(14)

          // ===== Header: icon tile, name + version, close =====
          Row {
            width: parent.width
            spacing: Style.space(12)

          Rectangle {
            width: Style.space(38)
            height: Style.space(38)
            radius: Style.cornerRadius > 0 ? 8 : 0
            color: Util.alpha(Color.accent, 0.16)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              anchors.centerIn: parent
              text: "\uf030"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.title
            }
          }

          Column {
            id: headerTextCol
            spacing: Style.space(2)

              Row {
                spacing: Style.space(8)

                Text {
                  text: "OmaLumineCapture"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.weight: Font.DemiBold
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(18)
                  width: versionText.implicitWidth + Style.space(12)
                  radius: Style.cornerRadius > 0 ? 4 : 0
                  color: Util.alpha(Color.accent, 0.15)
                  border.color: Util.alpha(Color.accent, 0.4)
                  border.width: 1

                  Text {
                    id: versionText
                    anchors.centerIn: parent
                    text: "v" + (configManager ? configManager.version : "")
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Bold
                  }
                }
              }

              // The OCR daemon status lives here: one glance on opening.
              Text {
                visible: root.ocrStatusText !== ""
                text: root.ocrStatusText
                color: (root.daemonOn || root.ocrStatus === "running") ? Color.accent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
          }

          Item { width: parent.width - Style.space(38) - headerTextCol.implicitWidth - Style.space(30) - Style.space(36); height: Style.space(1) }

          BorderSurface {
            width: Style.space(30)
            height: Style.space(30)
            radius: Style.cornerRadius > 0 ? 6 : 0
            color: closeMa.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\uf00d"
              color: Util.alpha(Color.foreground, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: closeMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }

            PanelSeparator {
              id: headerSeparator
              width: parent.width
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }
          }
        }

        // ===== Scrollable body: fills the card below the header =====
        // (availableHeight is unavailable in a Quickshell PanelWindow content
        // root, so compute the remaining height from the card.)
        Flickable {
          id: scroller
          anchors.top: cardHead.bottom
          anchors.topMargin: Style.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(24)
          anchors.rightMargin: Style.space(24)
          anchors.bottomMargin: Style.space(24)
          contentWidth: width
          contentHeight: contentCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

        Column {
          id: contentCol
          width: parent.width
          spacing: Style.space(12)

            // ===== Keybinding =====
            PanelSectionHeader {
              text: "KEYBINDINGS"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            HintText {
              width: parent.width
              text: "Each capture mode gets its own global shortcut, running the launch options below with that mode. Set a shortcut here, or use the capture button's panel."
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: LaunchArgs.MODES

                Item {
                  id: modeRowWrapper
                  required property var modelData
                  readonly property bool isWindowMode: modelData.value === "window"
                  width: parent.width
                  implicitHeight: modeRow.implicitHeight
                  opacity: isWindowMode ? 0.45 : 1.0

                  Row {
                    id: modeRow
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      width: Style.space(110)
                      text: modelData.label
                      color: modeRowWrapper.isWindowMode ? Color.muted : Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    BorderSurface {
                      width: Style.space(210)
                      implicitWidth: Style.space(210)
                      implicitHeight: Style.space(28)
                      color: Util.alpha(Color.foreground, 0.06)
                      borderSpec: Border.flat(Util.alpha(Color.foreground, 0.18), Style.normalBorderWidth)
                      radius: Style.cornerRadius > 0 ? 4 : 0
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        id: kbText
                        anchors.centerIn: parent
                        width: parent.width - Style.space(16)
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: modeRowWrapper.isWindowMode
                          ? "(unavailable)"
                          : (root.keybindings[modelData.value] ? root.formatChordDisplay(root.keybindings[modelData.value]) : "(none)")
                        color: modeRowWrapper.isWindowMode ? Color.muted : (root.keybindings[modelData.value] ? Color.foreground : Color.muted)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    Item { width: Style.space(4); height: 1 }

                    Button {
                      text: root.keybindings[modelData.value] ? "Change keybinding\u2026" : "Choose custom keybinding\u2026"
                      fontSize: Style.font.caption
                      enabled: !modeRowWrapper.isWindowMode
                      opacity: enabled ? 1.0 : 0.4
                      tooltipText: modeRowWrapper.isWindowMode
                        ? "Capturing the active window only works with KDE."
                        : (root.keybindings[modelData.value]
                          ? "Change the custom shortcut for " + modelData.label + " (current: " + root.formatChordDisplay(root.keybindings[modelData.value]) + ")"
                          : "Choose a custom keybinding for " + modelData.label)
                      onClicked: if (!modeRowWrapper.isWindowMode) root.openRecorder(modelData.value)
                    }

                    Button {
                      visible: !modeRowWrapper.isWindowMode && !!root.keybindings[modelData.value]
                      text: "Remove"
                      fontSize: Style.font.caption
                      enabled: !modeRowWrapper.isWindowMode && !root.isRemovingKey
                      opacity: enabled ? 1.0 : 0.4
                      tooltipText: root.hasConflictResolution(modelData.value)
                        ? "Remove shortcut and restore conflicting keybinding to its original state"
                        : "Remove the shortcut for " + modelData.label
                      onClicked: root.removeKeybinding(modelData.value)
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    visible: modeRowWrapper.isWindowMode
                    enabled: modeRowWrapper.isWindowMode
                    hoverEnabled: modeRowWrapper.isWindowMode
                    cursorShape: modeRowWrapper.isWindowMode ? Qt.ForbiddenCursor : Qt.ArrowCursor
                    PanelToolTip {
                      visible: modeRowWrapper.isWindowMode && parent.containsMouse
                      text: "Capturing the active window only works with KDE."
                    }
                  }
                }
              }
            }

            // ===== Behaviour: app-wide switches, not per-launch flags =====
            PanelSeparator {
              width: parent.width
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            PanelSectionHeader {
              text: "BEHAVIOUR"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Toggle {
              id: daemonToggle
              width: parent.width
              label: "OCR daemon"
              description: "Keep ready OCR engine in background on launch (automatically exits after 15 min idle)."
              titleSize: Style.font.bodySmall
              // The knob carries the user's preference ("serve" = on), not the
              // live status: the daemon idles itself out after 15 minutes and
              // the next launch brings it back, so a status-bound knob would
              // flip itself off in the user's face. Live status lives in the
              // header subtitle. User clicks handled in onClicked, never onCheckedChanged.
              checked: root.daemonOn
              onClicked: {
                var next = !root.daemonOn
                // Persist the preference first, then move the daemon itself.
                root.saveOption("ocrDaemon", next ? "serve" : "")
                root.runOcrDaemon(next ? "serve" : "stop")
              }
              enabled: root.ocrStatus !== "checking" && root.ocrStatus !== "busy"
            }

            Toggle {
              width: parent.width
              label: "Only the monitor under the pointer"
              description: "Capture the screen the pointer sits on, instead of every screen."
              titleSize: Style.font.bodySmall
              checked: root.monitor
              onClicked: { root.monitor = !root.monitor; root.saveOption("monitor", root.monitor) }
            }

            Toggle {
              width: parent.width
              label: "Nothing happens when you finish"
              description: "Finishing a shot does nothing unless you choose, whatever the app's own setting says."
              titleSize: Style.font.bodySmall
              checked: root.toNothing
              onClicked: { root.toNothing = !root.toNothing; root.saveOption("toNothing", root.toNothing) }
            }

            Toggle {
              width: parent.width
              label: "No notifications"
              description: "Skip the \u201csaved\u201d, \u201ccopied\u201d and OCR outcome notifications."
              titleSize: Style.font.bodySmall
              checked: root.nonotify
              onClicked: { root.nonotify = !root.nonotify; root.saveOption("nonotify", root.nonotify) }
            }

            // ===== Launch options: one control per lumine-capture flag =====
            PanelSeparator {
              width: parent.width
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            PanelSectionHeader {
              text: "LAUNCH OPTIONS"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            // Grouped by the kind of control: picks, then fields, then switches.
            // The explanation sits under the control it explains, indented to
            // the label column, so the rows read as one block.

            FormRow {
              label: "Send to"

              // Plugin-local copy of the theme MultiSelect: no search field.
              LocalUi.MultiSelect {
                id: toSelect
                width: Math.min(parent.controlWidth, Style.space(330))
                showLabel: false
                foreground: Color.foreground
                accent: Color.accent
                noSelectionText: "App default"
                options: LaunchArgs.TO_OPTIONS
                anchors.verticalCenter: parent.verticalCenter
                Binding { target: toSelect; property: "values"; value: root.toSelection }
                onChanged: function(values) { root.saveToLetters(values) }
              }
            }

            HintText {
              indentLabel: true
              text: root.appToSend !== ""
                ? "What to do with the shot. Clear all choices to let the app do "
                  + "what it is set to do: " + root.appToSend + "."
                : "What to do with the shot. Left on its own, the app's own choice is used."
            }

            FormRow {
              label: "Output folder"

              TextField {
                id: outputField
                width: Math.max(Style.space(120), parent.controlWidth - browseButton.implicitWidth - Style.space(8) - (clearOutputButton.visible ? clearOutputButton.implicitWidth + Style.space(8) : 0))
                // Empty means "the app default": show the resolved default path.
                text: root.output !== "" ? root.output : root.effectiveOutput
                placeholderText: "the app's own screenshots folder"
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(4)
                font.pixelSize: Style.font.bodySmall
                foreground: Color.foreground
                accent: Color.accent
                // No shell metacharacters: the path goes to bash -c and to a Hyprland exec.
                validator: RegularExpressionValidator { regularExpression: /^[^"'`$\\|<>;\n\r]*$/ }
                Binding { target: outputField; property: "text"; value: root.output !== "" ? root.output : root.effectiveOutput }
                property bool editedHere: false
                onAccepted: root.setOutputText(text)
                onActiveFocusChanged: {
                  if (activeFocus) editedHere = true
                  else if (editedHere) { editedHere = false; root.setOutputText(text) }
                }
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: browseButton
                text: "Browse\u2026"
                fontSize: Style.font.caption
                tooltipText: root.zenityPath !== "" ? "Pick a folder" : "Pick a folder (needs zenity — will offer to install)"
                onClicked: root.browseOutput()
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: clearOutputButton
                visible: root.output !== ""
                text: "Clear"
                fontSize: Style.font.caption
                tooltipText: "Use the app's default screenshots folder"
                onClicked: {
                  root.output = ""
                  root.saveOption("output", "")
                }
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            HintText {
              indentLabel: true
              text: "Saved shots go here, created if missing. Clear to use the app default (" + (root.configManager ? root.configManager.defaultOutput : root.effectiveOutput) + "). A folder here also saves the shot, even when Save is not ticked."
            }

            // What the combination cannot do, in the app's own words.
            Text {
              visible: text !== ""
              width: parent.width
              text: root.launchWarnings ? root.launchWarnings.join("\n") : ""
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // ===== Status =====
            Text {
              visible: root.statusText !== ""
              width: parent.width
              text: root.statusText
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

        }
      }
    }

    // =======================================================================
    // zenity install confirmation — shown when Browse is clicked while zenity
    // is missing. Confirm runs pacman in a foot window (sudo password goes
    // there); when that window closes, the folder picker opens by itself.
    // =======================================================================
    Rectangle {
      id: zenityAskScrim
      visible: root.zenityAskOpen
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.7)
      radius: settingsCard.radius
      z: 110

      MouseArea {
        anchors.fill: parent
        onClicked: {} // swallow clicks
      }

      Rectangle {
        width: parent.width - Style.space(96)
        height: zenityAskCol.implicitHeight + Style.space(32)
        anchors.centerIn: parent
        radius: Style.cornerRadius > 0 ? 8 : 0
        color: Color.background
        border.color: Color.accent
        border.width: 1

        Item {
          anchors.fill: parent
          focus: root.zenityAskOpen
          Keys.priority: Keys.BeforeItem

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.zenityAskOpen = false
              Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() })
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.installZenity()
              event.accepted = true
            }
          }
        }

        Column {
          id: zenityAskCol
          width: parent.width - Style.space(32)
          anchors.centerIn: parent
          spacing: Style.space(14)

          Text {
            width: parent.width
            text: "zenity is needed"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.weight: Font.DemiBold
          }

          Text {
            width: parent.width
            text: "To pick a different folder for the screenshots, zenity must be installed. Run \"sudo pacman -S --noconfirm zenity\" now? It opens in a terminal window so you can enter your sudo password; when that window closes, the folder picker opens by itself."
            color: Util.alpha(Color.foreground, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            lineHeight: 1.25
          }

          Row {
            anchors.right: parent.right
            spacing: Style.spacing.sm

            Button {
              width: Math.max(implicitWidth, Style.space(120))
              text: "Cancel"
              onClicked: {
                root.zenityAskOpen = false
                Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() })
              }
            }

            Button {
              width: Math.max(implicitWidth, Style.space(120))
              text: "Install zenity"
              selected: true
              onClicked: root.installZenity()
            }
          }
        }
      }
    }

    // =======================================================================
    // MODAL: Record shortcut dialog with live conflict check and resolution
    // Sits at top-level overlayWindow, covering screen with proper dialog size
    // =======================================================================
    LocalUi.KeybindingDialog {
      id: kbDialog
      targetWindow: overlayWindow
      dialogOpen: root.recordingDialogOpen
      mode: root.recordingMode
      modeLabel: root.modeName(root.recordingMode)
      currentChord: root.keybindings[root.recordingMode] || ""
      conflictCheckerScript: configManager ? configManager.conflictCheckerScript : ""
      argsByMode: configManager ? configManager.perModeArgs : ({})
      hasPriorConflict: root.hasConflictResolution(root.recordingMode)
      priorConflictOwner: root.hasConflictResolution(root.recordingMode) && configManager && configManager.conflictResolutions[root.recordingMode] ? configManager.conflictResolutions[root.recordingMode].owner : ""
      priorConflictChord: root.hasConflictResolution(root.recordingMode) && configManager && configManager.conflictResolutions[root.recordingMode] ? (configManager.conflictResolutions[root.recordingMode].original_chord || configManager.conflictResolutions[root.recordingMode].target_chord) : ""
      onApplied: function(res) {
        root.recordingDialogOpen = false
        if (res && res.keybindings) {
          root.keybindings = root.copyKeybindings(res.keybindings)
        }
        if (configManager && res) {
          configManager.saveSettings({
            keybindings: res.keybindings || root.keybindings,
            conflictResolutions: res.conflict_resolutions || res.conflictResolutions || {}
          })
        }
        root.statusText = res.message || "Keybinding updated."
        Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() })
      }
      onCancelled: function() {
        root.recordingDialogOpen = false
        Qt.callLater(function() { panelKeyCatcher.forceActiveFocus() })
      }
    }
  }

  // =========================================================================
  // Background work: status, key checks, applying the map, zenity lookup,
  // the OCR daemon, and the debounced re-apply of the shortcut.
  // =========================================================================
  Process {
    id: statusProc
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: {
        try {
          if (!text) return
          var idx = text.indexOf("{")
          var jsonStr = idx >= 0 ? text.substring(idx) : text
          var s = JSON.parse(jsonStr)
          if (s && s.keybindings) {
            root.keybindings = root.copyKeybindings(s.keybindings)
          }
        } catch (e) {
        }
      }
    }
  }

  Process {
    id: removeProc
    stdout: StdioCollector {
      id: removeOut
      waitForEnd: true
      onStreamFinished: {
        root.isRemovingKey = false
        try {
          if (!text) return
          var idx = text.indexOf("{")
          var jsonStr = idx >= 0 ? text.substring(idx) : text
          var res = JSON.parse(jsonStr)
          if (res && res.success === true) {
            if (res.keybindings) {
              root.keybindings = root.copyKeybindings(res.keybindings)
            }
            if (configManager) {
              configManager.saveSettings({
                keybindings: res.keybindings || root.keybindings,
                conflictResolutions: res.conflict_resolutions || res.conflictResolutions || {}
              })
            }
            root.statusText = res.message || "Keybinding removed."
          } else {
            if (configManager) root.keybindings = root.copyKeybindings(configManager.keybindings)
            root.statusText = (res && res.error) ? res.error : "Could not remove keybinding."
          }
        } catch (e) {
          if (configManager) root.keybindings = root.copyKeybindings(configManager.keybindings)
          root.statusText = "Error removing keybinding."
        }
      }
    }
    onExited: function(code) {
      root.isRemovingKey = false
    }
  }

  Process {
    id: syncProc
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    onExited: function(code) {
      if (root.pendingSync) {
        root.reapplyKeybinding()
      }
    }
  }

  Timer {
    id: reapplyTimer
    interval: 900
    onTriggered: root.reapplyKeybinding()
  }

  Process {
    id: checkZenityProc
    command: ["/usr/bin/which", "zenity"]
    stdout: StdioCollector { id: checkZenityOut; waitForEnd: true }
    onExited: function(code) {
      // 2nd arg of onExited is the exit status, not stdout; captured text
      // needs a StdioCollector on the stdout property (see themeSyncProc).
      var out = String(checkZenityOut.text).trim()
      root.zenityPath = code === 0 && out.startsWith("/") ? out : ""
      if (root.zenityPendingBrowse) {
        root.zenityPendingBrowse = false
        if (root.zenityPath) {
          root.browseOutput()
          return
        }
        root.externalFlowDone()
      }
    }
  }

  Process {
    id: installZenityProc
    command: ["xdg-terminal-exec", "--app-id=org.omarchy.terminal", "--title=Install zenity", "-e", "sh", "-c",
              "sudo pacman -S --noconfirm zenity; echo; echo 'Press Enter to close this window'; read -r _"]
    onExited: function(code) {
      // Terminal window closed — find out whether zenity arrived.
      checkZenityProc.running = true
    }
  }

  Process {
    id: browseProc
    stdout: StdioCollector { id: browseOut; waitForEnd: true }
    onExited: function(code) {
      var path = String(browseOut.text).trim()
      if (code === 0 && path !== "") root.setOutputText(path)
      root.externalFlowDone()
    }
  }

  Process {
    id: ocrProc
    stdout: StdioCollector { id: ocrOut; waitForEnd: true }
    onExited: function(code) {
      root.ocrBusy = false
      // serve/stop/calibrate move the daemon, so the truth comes from status.
      root.refreshOcrStatus()
      var out = String(ocrOut.text).trim()
      if (code !== 0)
        root.statusText = "OCR daemon: " + root.pendingOcrAction + " failed" + (out !== "" ? ": " + out : ".")
    }
  }

  Process {
    id: ocrStatusProc
    // onExited(code, exitStatus): the 2nd arg is the process's exit-status
    // number, NOT stdout; captured text needs a StdioCollector on the stdout
    // property (see themeSyncProc in ConfigManager.qml).
    stdout: StdioCollector { id: ocrStatusOut; waitForEnd: true }
    onExited: function (code) {
      root.applyOcrStatus(code, String(ocrStatusOut.text))
    }
  }

  // `serve` is detached and answers on its own schedule; re-read status after
  // it has had a moment to come up.
  Timer {
    id: ocrStatusTimer
    interval: 1500
    onTriggered: root.refreshOcrStatus()
  }

  // =========================================================================
  // Inline pieces: a label column with controls beside it, and the line of
  // explanation under a control.
  // =========================================================================

  component FormRow: Row {
    id: formRow
    width: parent.width
    spacing: Style.space(8)

    property string label: ""

    // Children go into the controls column, not into the row itself.
    default property alias controls: controlsColumn.data

    Text {
      id: labelColumn
      width: Style.space(120)
      text: formRow.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      id: controlsColumn
      spacing: Style.space(8)
      // Room left for the control, once the label column is off. Callers read
      // this as `parent.controlWidth` from inside the row.
      readonly property int controlWidth: formRow.width - labelColumn.width - formRow.spacing
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component HintText: Text {
    // Indent to line up under the control of the FormRow above.
    property bool indentLabel: false
    x: indentLabel ? Style.space(128) : 0
    width: parent.width - x
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
