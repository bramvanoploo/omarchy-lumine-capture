import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LaunchArgs.js" as LaunchArgs

PopupCard {
  id: root

  property var configManager: null
  property bool isInstalled: false

  property var keybindings: ({ "": "", "full": "", "window": "", "region": "", "region-ocr": "" })
  // Which capture mode the record dialog is assigning a shortcut for.
  property string recordingMode: ""
  // Last chord the Apply/Take-over button sent, for the status line; and the
  // silent flag so the silent start-up re-apply never writes a status line.
  property string lastAppliedChord: ""
  property bool silentReapply: false

  // Mirrors of the launch options in ConfigManager, edited here and written
  // back one at a time.
  property string mode: ""
  property bool monitor: false
  property string delay: ""
  property string to: ""
  property bool toNothing: false
  property string output: ""
  property bool nonotify: false
  property string ocrDaemon: ""

  // Where shots actually go: the Output folder when set, else
  // lumine-capture's default (its "screenshots" dir under the Pictures dir).
  readonly property string effectiveOutput: {
    if (configManager && configManager.expandedOutput !== "") return configManager.expandedOutput
    var home = Quickshell.env("HOME")
    return (home ? home : "~") + "/Pictures/screenshots"
  }

  property var toSelection: []
  property string zenityPath: ""
  property bool ocrBusy: false
  property string pendingOcrAction: ""

  property bool suggestedKeyConflict: false
  property string suggestedKeyConflictMessage: ""
  property string statusText: ""

  // Record-key dialog (OmaGuake style): recording, live conflict check,
  // suggested alternatives, and take-over of a conflicting binding.
  property bool recordingDialogOpen: false
  property string recordedChord: ""
  property bool recordedConflict: false
  property string recordedConflictMessage: ""
  property var recordedSuggestions: []
  property bool isCheckingRecordedKey: false

  padding: Style.space(20)
  contentWidth: fittedContentWidth(Style.space(520))
  // The record dialog is a modal inside the card, so the card must grow to fit it.
  contentHeight: fittedContentHeight(Math.max(
    contentCol.implicitHeight,
    recordingDialogOpen ? recordCol.implicitHeight + Style.space(40) : 0
  ))

  onOpenChanged: {
    if (open) {
      loadCurrentSettings()
      refreshStatus()
      statusText = ""
      checkZenityProc.running = true
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

  function loadCurrentSettings() {
    if (!configManager) return
    keybindings = copyKeybindings(configManager.keybindings)
    mode = configManager.mode || ""
    monitor = configManager.monitor === true
    delay = configManager.delay || ""
    to = configManager.to || ""
    toNothing = configManager.toNothing === true
    output = configManager.output || ""
    nonotify = configManager.nonotify === true
    ocrDaemon = configManager.ocrDaemon || ""
    toSelection = to.split("")
  }

  // The launch options LumineCapture will be started with.
  readonly property string launchArgs: configManager ? configManager.launchArgs : ""
  readonly property var launchWarnings: configManager ? configManager.launchWarnings : []
  readonly property string modeHint: {
    for (var i = 0; i < LaunchArgs.MODES.length; i++) {
      if (LaunchArgs.MODES[i].value === mode) return LaunchArgs.MODES[i].hint
    }
    return ""
  }
  readonly property string daemonHint: {
    for (var i = 0; i < LaunchArgs.DAEMON_ACTIONS.length; i++) {
      if (LaunchArgs.DAEMON_ACTIONS[i].value === ocrDaemon) return LaunchArgs.DAEMON_ACTIONS[i].hint
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

  function modeLabel(mode) {
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
    to = letters
    saveOption("to", letters)
  }

  function setDelayText(text) {
    delay = text
    saveOption("delay", text)
  }

  function browseOutput() {
    if (!zenityPath) return
    var start = configManager ? configManager.expandedOutput : ""
    browseProc.command = [zenityPath, "--file-selection", "--directory",
                          "--title=Where should the shots be saved?",
                          "--filename=" + (start || (Quickshell.env("HOME") || "/")) + "/"]
    browseProc.running = true
  }

  // serve outlives the panel, so it goes out detached; the rest answer on
  // stdout, which lands in the status line.
  function runOcrDaemon(action) {
    if (!configManager || ocrBusy) return
    if (action === "serve") {
      Quickshell.execDetached(["lumine-capture", "--ocr-daemon", "serve"])
      statusText = "OCR daemon: serving in the background."
      return
    }
    ocrBusy = true
    pendingOcrAction = action
    statusText = action === "calibrate"
        ? "OCR daemon: measuring this machine, a few seconds\u2026"
        : "OCR daemon: " + action + "\u2026"
    ocrProc.command = ["lumine-capture", "--ocr-daemon", action]
    ocrProc.running = true
  }

  function resetOptions() {
    if (!configManager) return
    configManager.resetOptions()
    loadCurrentSettings()
    statusText = "Launch options cleared: the app's own settings decide."
    reapplyTimer.restart()
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
    if (text && text.length === 1 && text.trim().length > 0) return text.toUpperCase()
    return ""
  }

  // The launch options make the panel taller than a laptop screen, so it scrolls.
  Flickable {
    id: scroller
    width: parent.width
    height: parent.height
    contentWidth: width
    contentHeight: contentCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: contentCol
      width: parent.width
      spacing: Style.space(10)

      // ---------- background jobs ----------

      Process {
        id: statusProc
        command: ["true"]
        stdout: StdioCollector { id: statusOut }
        onExited: function(code) {
          try {
            var s = JSON.parse(statusOut.text)
            suggestedKeyConflict = s.suggested_key_conflict === true
            suggestedKeyConflictMessage = s.suggested_key_conflict_message || ""
          } catch (e) {}
        }
      }

      Process {
        id: keyCheckProc
        command: ["true"]
        stdout: StdioCollector { id: keyCheckOut }
        onExited: function(code) {
          root.isCheckingRecordedKey = false
          var res = null
          try { res = JSON.parse(keyCheckOut.text) } catch (e) {}
          if (!res) return
          root.recordedConflict = res.conflict === true
          root.recordedConflictMessage = res.message || ""
          root.recordedSuggestions = res.suggestions || []
        }
      }

      Process {
        id: applyProc
        command: ["true"]
        stdout: StdioCollector { id: applyOut }
        onExited: function(code) {
          var res = null
          try { res = JSON.parse(applyOut.text) } catch (e) {}
          if (res && res.success) {
            root.recordingDialogOpen = false
            if (!root.silentReapply) {
              root.statusText = root.lastAppliedChord
                ? "Keybinding applied: " + root.lastAppliedChord + " (" + root.modeLabel(root.recordingMode) + ")"
                : "Keybinding removed."
            }
            refreshStatus()
          } else if (!root.silentReapply) {
            root.statusText = (res && res.error) ? res.error : "Applying keybinding failed."
          }
        }
      }

      // Typing in the delay, output path or extra arguments settles before the
      // keybinding is rewritten: one hyprctl reload for the whole edit, not one
      // per keystroke.
      Timer {
        id: reapplyTimer
        interval: 900
        onTriggered: root.reapplyKeybinding()
      }

      Process {
        id: checkZenityProc
        command: ["bash", "-c", "command -v zenity"]
        stdout: StdioCollector { id: zenityOut }
        onExited: function(code) { root.zenityPath = code === 0 ? zenityOut.text.trim() : "" }
      }

      Process {
        id: browseProc
        command: ["true"]
        stdout: StdioCollector { id: browseOut }
        onExited: function(code) {
          var picked = browseOut.text.trim()
          if (code === 0 && picked !== "") root.saveOption("output", picked)
        }
      }

      Process {
        id: ocrProc
        command: ["true"]
        stdout: StdioCollector { id: ocrOut }
        stderr: StdioCollector { id: ocrErr }
        onExited: function(code) {
          root.ocrBusy = false
          var out = (ocrOut.text + " " + ocrErr.text).trim().replace(/\n+/g, " ")
          var action = root.pendingOcrAction
          root.pendingOcrAction = ""
          root.statusText = "OCR daemon " + action + ": " + (out || "(no output, exit " + code + ")")
        }
      }

      // ===== Header =====
      Row {
        width: parent.width
        spacing: Style.space(14)

        Text {
          text: "\uf030"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Math.max(Style.font.heading, Math.round(headerTextCol.implicitHeight))
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: headerTextCol
          anchors.verticalCenter: parent.verticalCenter
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

          Text {
            visible: !root.isInstalled
            text: "lumine-capture is not installed"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Item { width: Style.space(1); height: 1; anchors.verticalCenter: parent.verticalCenter }

        Item {
          width: parent.width - childrenRect.width - Style.space(11)
          height: 1
        }

        BorderSurface {
          width: Style.space(26)
          height: Style.space(26)
          radius: Style.cornerRadius > 0 ? 4 : 0
          color: closeMa.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: "\uf00d"
            color: Util.alpha(Color.foreground, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: closeMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.open = false
          }
        }
      }

      // ===== Keybinding =====
      PanelSeparator {
        foreground: bar.foreground
      }

      PanelSectionHeader {
        text: "KEYBINDING"
        foreground: bar.foreground
        fontFamily: bar.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(8)

        HintText {
          width: parent.width
          text: "Each capture mode gets its own global shortcut, running the launch options below with that mode. Set a shortcut here, or use the capture button's panel."
        }

        Repeater {
          model: LaunchArgs.MODES

          Row {
            required property var modelData
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: Style.space(100)
              text: modelData.label
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            BorderSurface {
              implicitWidth: Math.max(kbText.implicitWidth + Style.space(20), Style.space(130))
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

      // ===== Launch options: one control per lumine-capture flag =====

      PanelSeparator {
        foreground: bar.foreground
      }

      PanelSectionHeader {
        text: "LAUNCH OPTIONS"
        foreground: bar.foreground
        fontFamily: bar.fontFamily
      }

      // Grouped by the kind of control: picks, then fields, then switches.

      // ===== Picks =====

      // Mode decides what the shot is, and it is what people set by hand.
      FormRow {
        label: "Mode"

        Dropdown {
          id: modeDrop
          width: Math.min(parent.controlWidth, Style.space(250))
          showLabel: false
          foreground: Color.foreground
          accent: Color.accent
          options: LaunchArgs.MODES
          anchors.verticalCenter: parent.verticalCenter
          Binding { target: modeDrop; property: "value"; value: root.mode }
          onChanged: function(next) {
            root.mode = next
            root.saveOption("mode", next)
          }
        }
      }

      HintText { text: root.modeHint }

      FormRow {
        label: "Send to"

        MultiSelect {
          id: toSelect
          width: Math.min(parent.controlWidth, Style.space(330))
          showLabel: false
          foreground: Color.foreground
          accent: Color.accent
          placeholderText: "Choose what to do with the shot"
          noSelectionText: "App default"
          options: LaunchArgs.TO_OPTIONS
          anchors.verticalCenter: parent.verticalCenter
          Binding { target: toSelect; property: "values"; value: root.toSelection }
          onChanged: function(values) { root.saveToLetters(values) }
        }
      }

      HintText { text: "What to do with the shot. Left on its own, the app's own choice is used." }

      FormRow {
        label: "OCR daemon"

        Dropdown {
          id: daemonDrop
          width: Math.min(parent.controlWidth, Style.space(250))
          showLabel: false
          foreground: Color.foreground
          accent: Color.accent
          options: LaunchArgs.DAEMON_ACTIONS
          anchors.verticalCenter: parent.verticalCenter
          Binding { target: daemonDrop; property: "value"; value: root.ocrDaemon }
          onChanged: function(next) {
            root.ocrDaemon = next
            root.saveOption("ocrDaemon", next)
            // The choice is the request: run that daemon action right away.
            root.runOcrDaemon(next)
          }
        }
      }

      HintText { text: root.daemonHint }

      // ===== Fields =====

      FormRow {
        label: "Delay"

        TextField {
          id: delayField
          width: Style.space(84)
          text: root.delay
          placeholderText: "none"
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          font.pixelSize: Style.font.bodySmall
          foreground: Color.foreground
          accent: Color.accent
          validator: RegularExpressionValidator { regularExpression: /^\d{1,4}([.,]\d{1,2})?$/ }
          // Typing takes the binding over, so the value comes back by Binding.
          Binding { target: delayField; property: "text"; value: root.delay }
          // Only write back a field the person actually edited: the popup
          // stealing focus away must not save the text that the Binding put there.
          property bool editedHere: false
          onAccepted: root.setDelayText(text)
          onActiveFocusChanged: {
            if (activeFocus) editedHere = true
            else if (editedHere) { editedHere = false; root.setDelayText(text) }
          }
          anchors.verticalCenter: parent.verticalCenter
        }

        Repeater {
          model: ["0.5", "1", "3", "10"]

          Button {
            text: modelData + "s"
            fontSize: Style.font.caption
            tooltipText: "Delay the shot " + modelData + " seconds"
            onClicked: { delayField.text = modelData; root.setDelayText(modelData) }
          }
        }

        Button {
          visible: root.delay !== ""
          text: "Clear"
          fontSize: Style.font.caption
          tooltipText: "Take the shot straight away"
          onClicked: { delayField.text = ""; root.setDelayText("") }
        }
      }

      HintText { text: "Seconds between launching and taking the shot. Empty takes it straight away." }

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
          enabled: root.zenityPath !== ""
          tooltipText: root.zenityPath !== "" ? "Pick a folder" : "Needs zenity for a folder picker"
          onClicked: root.browseOutput()
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      HintText { text: "Saved shots go here, created if missing. Clear the field to use the app default (" + root.effectiveOutput + "). A folder here also saves the shot, even when Save is not ticked." }

      // ===== Switches =====

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
        label: "No notifications for this launch"
        description: "Skip the \u201csaved\u201d, \u201ccopied\u201d and OCR outcome notifications."
        titleSize: Style.font.bodySmall
        checked: root.nonotify
        onClicked: { root.nonotify = !root.nonotify; root.saveOption("nonotify", root.nonotify) }
      }

      // What the combination cannot do, in the app's own words.
      Text {
        visible: text !== ""
        width: parent.width
        text: root.launchWarnings.join("\n")
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Button {
        text: "Clear launch options"
        fontSize: Style.font.caption
        tooltipText: "Back to what LumineCapture's own config.toml decides"
        onClicked: root.resetOptions()
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

  // =========================================================================
  // MODAL: Record shortcut dialog with live conflict check and resolution
  // (structure follows OmaGuake's "Record custom shortcut" modal)
  // =========================================================================
  Rectangle {
    id: recordModalScrim
    visible: root.recordingDialogOpen
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.7)
    radius: Style.cornerRadius
    z: 100

    MouseArea {
      anchors.fill: parent
      onClicked: {} // swallow clicks
    }

    Rectangle {
      id: recordCard
      width: parent.width - Style.space(32)
      height: recordCol.implicitHeight + Style.space(32)
      anchors.centerIn: parent
      radius: Style.cornerRadius
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
          text: "Record shortcut" + (root.recordingMode !== "" ? " \u2014 " + root.modeLabel(root.recordingMode) : "")
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

  // =========================================================================
  // Inline pieces: a label column with controls beside it, a section header,
  // and the line of explanation under a control.
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
      width: Style.space(150)
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
    width: parent.width
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
