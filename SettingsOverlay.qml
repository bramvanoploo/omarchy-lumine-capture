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
  // Last chord the Apply/Take-over button sent, for the status line; and the
  // silent flag so the silent start-up re-apply never writes a status line.
  property string lastAppliedChord: ""
  property bool silentReapply: false

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
    var home = Quickshell.env("HOME")
    return (home ? home : "~") + "/Pictures/screenshots"
  }

  // Checkboxes show the app's own general.to while the option is empty, the
  // way the Output folder shows the effective path. Derived, not seeded: the
  // app config arrives on its own FileView, later than the settings file.
  readonly property var toSelection: (to !== "" ? to
    : (configManager ? configManager.appTo : "")).split("")

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

  property bool suggestedKeyConflict: false
  property string suggestedKeyConflictMessage: ""
  property string statusText: ""

  // Record-key dialog: recording, live conflict check, suggested
  // alternatives, and take-over of a conflicting binding.
  property bool recordingDialogOpen: false
  property string recordedChord: ""
  property bool recordedConflict: false
  property string recordedConflictMessage: ""
  property var recordedSuggestions: []
  property bool isCheckingRecordedKey: false

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
  readonly property string daemonHint: {
    var daemon = configManager ? configManager.ocrDaemon || "" : ""
    for (var i = 0; i < LaunchArgs.DAEMON_ACTIONS.length; i++) {
      if (LaunchArgs.DAEMON_ACTIONS[i].value === daemon) return LaunchArgs.DAEMON_ACTIONS[i].hint
    }
    return ""
  }

  readonly property string ocrStatusText: {
    if (ocrStatus === "checking") return "OCR daemon: checking\u2026"
    if (ocrStatus === "running") return "OCR daemon: running"
    if (ocrStatus === "busy") {
      if (pendingOcrAction === "calibrate") return "OCR daemon: measuring this machine, a few seconds\u2026"
      return "OCR daemon: " + pendingOcrAction + "\u2026"
    }
    if (ocrStatus === "stopped") return "OCR daemon: not running"
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

  function openRecorder(mode) {
    recordingMode = mode
    recordedChord = ""
    recordedConflict = false
    recordedConflictMessage = ""
    recordedSuggestions = []
    isCheckingRecordedKey = false
    recordingDialogOpen = true
    Qt.callLater(function() { recordKeyCatcher.forceActiveFocus() })
  }

  function checkRecordedKey(chord) {
    if (!configManager || !chord) return
    isCheckingRecordedKey = true
    keyCheckProc.command = [configManager.conflictCheckerScript, "check-key", chord]
    keyCheckProc.running = true
  }

  function applyBinding(chord, unbind) {
    if (!configManager) return
    var map = copyKeybindings(configManager.keybindings)
    map[recordingMode] = chord
    keybindings = map
    lastAppliedChord = chord
    silentReapply = false
    configManager.saveSettings({ keybindings: map })
    var payload = {
      bindings: map,
      args_by_mode: configManager.perModeArgs,
      mode: recordingMode,
      unbind_conflicts: unbind
    }
    applyProc.command = [configManager.conflictCheckerScript, "apply-map", JSON.stringify(payload)]
    applyProc.running = true
  }

  // Write one option, then let the global shortcuts pick it up. The exec
  // commands in bindings.lua are fixed strings, so they are rewritten once the
  // typing settles.
  function saveOption(key, value) {
    if (!configManager) return
    var patch = {}
    patch[key] = value
    configManager.saveSettings(patch)
    loadCurrentSettings()
    reapplyTimer.restart()
  }

  // Rewrite the shortcuts so they run the commands the options add up to. The
  // chords come from the settings, not from the panel's copy of them: this runs
  // at shell start too, before the panel has ever been opened.
  function reapplyKeybinding() {
    if (!configManager) return
    var map = configManager.keybindings || {}
    var any = false
    var list = LaunchArgs.MODES
    for (var i = 0; i < list.length; i++) {
      var chord = String(map[list[i].value] || "").trim()
      if (chord !== "" && chord.toLowerCase() !== "none") {
        any = true
        break
      }
    }
    if (!any) return
    var payload = {
      bindings: map,
      args_by_mode: configManager.perModeArgs,
      mode: "",
      unbind_conflicts: false
    }
    applyProc.command = [configManager.conflictCheckerScript, "apply-map", JSON.stringify(payload)]
    silentReapply = true
    applyProc.running = true
  }

  function saveToLetters(values) {
    var letters = LaunchArgs.toLetters(values)
    // Picking exactly what the app already does keeps the option empty, so the
    // row keeps following LumineCapture when its config changes.
    var app = configManager ? configManager.appTo || "" : ""
    if (LaunchArgs.toLetters(letters.split("")) === LaunchArgs.toLetters(app.split(""))) letters = ""
    to = letters
    saveOption("to", letters)
  }

  function setOutputText(text) {
    output = text
    saveOption("output", text)
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

  // ---------- key chord recorder ----------

  function recordedKeyStr(k, text) {
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
    if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)
    if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1)
    var map = {}
    map[Qt.Key_Space] = "SPACE"; map[Qt.Key_Escape] = "ESCAPE"; map[Qt.Key_Return] = "RETURN"
    map[Qt.Key_Enter] = "RETURN"; map[Qt.Key_Tab] = "TAB"; map[Qt.Key_Backspace] = "BACKSPACE"
    map[Qt.Key_Delete] = "DELETE"; map[Qt.Key_Insert] = "INSERT"; map[Qt.Key_Home] = "HOME"
    map[Qt.Key_End] = "END"; map[Qt.Key_PageUp] = "PAGEUP"; map[Qt.Key_PageDown] = "PAGEDOWN"
    map[Qt.Key_Left] = "LEFT"; map[Qt.Key_Right] = "RIGHT"; map[Qt.Key_Up] = "UP"; map[Qt.Key_Down] = "DOWN"
    map[Qt.Key_Grave] = "GRAVE"; map[Qt.Key_Minus] = "MINUS"; map[Qt.Key_Equal] = "EQUAL"
    map[Qt.Key_Comma] = "COMMA"; map[Qt.Key_Period] = "PERIOD"; map[Qt.Key_Slash] = "SLASH"
    map[Qt.Key_Semicolon] = "SEMICOLON"; map[Qt.Key_Apostrophe] = "APOSTROPHE"; map[Qt.Key_Backslash] = "BACKSLASH"
    if (map[k]) return map[k]
    if (text && text.length === 1 && text !== " ") return text.toUpperCase()
    return ""
  }

  // =========================================================================
  // THE OVERLAY
  // =========================================================================
  PanelWindow {
    id: overlayWindow
    visible: root.open
    // Sit on the screen the bar lives on.
    screen: configManager && configManager.QsWindow && configManager.QsWindow.window
            ? configManager.QsWindow.window.screen : null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "lumine-capture-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open
                                   ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Escape closes the overlay; the record dialog answers it first.
    Item {
      id: panelKeyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.recordingDialogOpen) root.recordingDialogOpen = false
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
                color: root.ocrStatus === "running" ? Color.accent : Color.muted
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

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(120)
                    text: modelData.label
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  BorderSurface {
                    implicitWidth: Math.max(kbText.implicitWidth + Style.space(20), Style.space(150))
                    implicitHeight: Style.space(28)
                    color: Util.alpha(Color.foreground, 0.06)
                    borderSpec: Border.flat(Util.alpha(Color.foreground, 0.18), Style.normalBorderWidth)
                    radius: Style.cornerRadius > 0 ? 4 : 0
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: kbText
                      anchors.centerIn: parent
                      text: root.keybindings[modelData.value] ? root.keybindings[modelData.value] : "(none)"
                      color: root.keybindings[modelData.value] ? Color.foreground : Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Item { width: Style.space(1); height: 1 }

                  Button {
                    text: root.keybindings[modelData.value] ? "Record\u2026" : "Record shortcut\u2026"
                    fontSize: Style.font.caption
                    tooltipText: root.keybindings[modelData.value]
                      ? "Record a new shortcut for " + modelData.label + " (current: " + root.keybindings[modelData.value] + ")"
                      : "Record a global shortcut for " + modelData.label
                    onClicked: root.openRecorder(modelData.value)
                  }

                  Button {
                    visible: !!root.keybindings[modelData.value]
                    text: "Clear"
                    fontSize: Style.font.caption
                    tooltipText: "Remove the shortcut for " + modelData.label
                    onClicked: {
                      root.recordingMode = modelData.value
                      root.applyBinding("", false)
                    }
                  }
                }
              }
            }

            Text {
              visible: root.suggestedKeyConflict && suggestedKeyConflictMessage !== ""
              width: parent.width
              text: "\u26a0 " + suggestedKeyConflictMessage
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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
              description: "Keep a ready OCR engine in the background for later launches."
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
                width: Math.max(Style.space(120), parent.controlWidth - browseButton.implicitWidth - Style.space(8))
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
            }

        }
      }

      // =======================================================================
      // MODAL: Record shortcut dialog with live conflict check and resolution
      // (structure follows OmaGuake's "Record custom shortcut" modal)
      // =======================================================================
    Rectangle {
      id: recordModalScrim
      visible: root.recordingDialogOpen
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.7)
      radius: settingsCard.radius
      z: 100

      MouseArea {
        anchors.fill: parent
        onClicked: {} // swallow clicks
      }

      Rectangle {
        id: recordCard
        width: parent.width - Style.space(64)
        height: recordCol.implicitHeight + Style.space(32)
        anchors.centerIn: parent
        radius: Style.cornerRadius > 0 ? 8 : 0
        color: Color.background
        border.color: Color.accent
        border.width: 1

        // Key catcher
        Item {
          id: recordKeyCatcher
          anchors.fill: parent
          focus: root.recordingDialogOpen
          Keys.priority: Keys.BeforeItem

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.recordingDialogOpen = false
              event.accepted = true
              return
            }

            var mods = []
            if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
            if (event.modifiers & Qt.AltModifier) mods.push("ALT")
            if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
            if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

            var isMod = event.key === Qt.Key_Control || event.key === Qt.Key_Alt ||
                        event.key === Qt.Key_Meta || event.key === Qt.Key_Shift ||
                        event.key === Qt.Key_Super || event.key === Qt.Key_NumLock
            var keyStr = isMod ? "" : root.recordedKeyStr(event.key, event.text)

            if (isMod) {
              root.recordedChord = mods.join(" + ")
              event.accepted = true
            } else if (keyStr) {
              var chord = (mods.length > 0 ? mods.join(" + ") + " + " : "") + keyStr
              root.recordedChord = chord
              root.checkRecordedKey(chord)
              event.accepted = true
            }
          }
        }

        Column {
          id: recordCol
          anchors.fill: parent
          anchors.margins: Style.space(16)
          spacing: Style.space(14)

          Text {
            text: "Record shortcut" + (root.recordingMode !== "" ? " \u2014 " + root.modeName(root.recordingMode) : "")
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            color: Color.foreground
          }

          // Recording display box
          Rectangle {
            width: parent.width
            height: 60
            radius: Style.cornerRadius > 0 ? 6 : 0
            color: Util.alpha(Color.accent, 0.08)
            border.color: Color.accent
            border.width: 1

            Row {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                text: root.recordedChord ? "\uf11c" : "\uf111"
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                color: Color.accent
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.recordedChord ? root.recordedChord : "Press your key combination"
                font.family: Style.font.family
                font.pixelSize: root.recordedChord ? Style.font.heading : Style.font.body
                font.bold: !!root.recordedChord
                color: root.recordedChord ? Color.foreground : Color.muted
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // Live conflict / availability status
          Rectangle {
            visible: !!root.recordedChord
            width: parent.width
            height: recStatusText.implicitHeight + Style.space(16)
            radius: Style.cornerRadius > 0 ? 4 : 0
            color: root.recordedConflict ? Util.alpha(Color.urgent, 0.15) : Util.alpha(Color.accent, 0.15)
            border.color: root.recordedConflict ? Color.urgent : Color.accent
            border.width: 1

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              Text {
                text: root.recordedConflict ? "\uf071" : "\uf00c"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: root.recordedConflict ? Color.urgent : Color.accent
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: recStatusText
                width: parent.width - Style.space(32)
                text: root.isCheckingRecordedKey
                      ? "Checking for conflicts\u2026"
                      : (root.recordedConflict
                         ? root.recordedConflictMessage
                         : root.recordedChord + " is free")
                textFormat: Text.PlainText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                color: root.recordedConflict ? Color.urgent : Color.foreground
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // Suggested conflict-free alternatives
          Column {
            visible: root.recordedConflict && root.recordedSuggestions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Conflict-free alternatives"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              color: Color.foreground
            }

            Row {
              spacing: Style.space(6)

              Repeater {
                model: root.recordedSuggestions

                Button {
                  text: modelData
                  fontSize: Style.font.caption
                  tooltipText: "Use " + modelData + " instead"
                  onClicked: {
                    root.recordedChord = modelData
                    root.checkRecordedKey(modelData)
                  }
                }
              }
            }
          }

          // Take over the conflicting binding
          Row {
            visible: root.recordedConflict
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "The key is bound elsewhere."
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Color.muted
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              text: "Take over (disable conflicting binding)"
              fontSize: Style.font.caption
              tooltipText: "Comment out the conflicting Hyprland binding and assign this key to LumineCapture"
              onClicked: root.applyBinding(root.recordedChord, true)
            }
          }

          // Actions
          Row {
            anchors.right: parent.right
            spacing: Style.spacing.sm

            Button {
              id: recCancelBtn
              width: Math.max(recApplyBtn.implicitWidth, Style.space(120))
              text: "Cancel"
              onClicked: root.recordingDialogOpen = false
            }

            Button {
              id: recApplyBtn
              width: Math.max(implicitWidth, Style.space(120))
              text: "Apply"
              selected: true
              enabled: !!root.recordedChord && !root.recordedConflict && !root.isCheckingRecordedKey
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.applyBinding(root.recordedChord, false)
            }
          }
        }
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
              onClicked: root.zenityAskOpen = false
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

  // =========================================================================
  // Background work: status, key checks, applying the map, zenity lookup,
  // the OCR daemon, and the debounced re-apply of the shortcut.
  // =========================================================================
  Process {
    id: statusProc
    stdout: StdioCollector { id: statusOut }
    onExited: function(code) {
      try {
        var s = JSON.parse(statusOut.text)
        root.suggestedKeyConflict = s.suggested_key_conflict === true
        root.suggestedKeyConflictMessage = s.suggested_key_conflict_message || ""
      } catch (e) {
        root.suggestedKeyConflict = false
        root.suggestedKeyConflictMessage = ""
      }
    }
  }

  Process {
    id: keyCheckProc
    stdout: StdioCollector { id: keyCheckOut }
    onExited: function(code) {
      root.isCheckingRecordedKey = false
      try {
        var s = JSON.parse(keyCheckOut.text)
        root.recordedConflict = s.conflict === true
        root.recordedConflictMessage = s.conflict_message || ""
        root.recordedSuggestions = s.suggestions || []
      } catch (e) {
        root.recordedConflict = false
        root.recordedConflictMessage = ""
        root.recordedSuggestions = []
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut }
    onExited: function(code) {
      var r = null
      try { r = JSON.parse(applyOut.text) } catch (e) { r = null }
      var ok = code === 0 && r && r.success === true
      if (root.silentReapply) {
        root.silentReapply = false
        return
      }
      if (ok) {
        // The record dialog closes itself once the chord is in.
        if (root.recordingDialogOpen) root.recordingDialogOpen = false
        root.statusText = root.lastAppliedChord === ""
            ? "Keybinding removed."
            : "Keybinding applied: " + root.lastAppliedChord + " (" + root.modeName(root.recordingMode) + ")"
      } else {
        root.statusText = (r && r.error) ? r.error : "Could not apply the keybinding."
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
    stdout: StdioCollector { id: checkZenityOut }
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
      }
      root.externalFlowDone()
    }
  }

  Process {
    id: installZenityProc
    command: ["foot", "-T", "Install zenity", "--", "sh", "-c",
              "sudo pacman -S --noconfirm zenity; echo; echo 'Press Enter to close this window'; read -r _"]
    onExited: function(code) {
      // Terminal window closed — find out whether zenity arrived.
      checkZenityProc.running = true
    }
  }

  Process {
    id: browseProc
    stdout: StdioCollector { id: browseOut }
    onExited: function(code) {
      var path = String(browseOut.text).trim()
      if (code === 0 && path !== "") root.setOutputText(path)
      root.externalFlowDone()
    }
  }

  Process {
    id: ocrProc
    stdout: StdioCollector { id: ocrOut }
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
    stdout: StdioCollector { id: ocrStatusOut }
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
