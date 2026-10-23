import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property var targetWindow: null
  property bool dialogOpen: false
  property string mode: ""
  property string modeLabel: ""
  property string currentChord: ""
  property string conflictCheckerScript: ""
  property var argsByMode: ({})

  // Wayland shortcuts inhibitor: blocks Hyprland/compositor shortcuts while recording
  ShortcutInhibitor {
    id: shortcutInhibitor
    window: root.targetWindow !== null ? root.targetWindow : root.QsWindow.window
    enabled: root.dialogOpen
  }

  // Prior conflict information for this mode (Requirement 5)
  property bool hasPriorConflict: false
  property string priorConflictOwner: ""
  property string priorConflictChord: ""
  property bool resetPriorConflictChoice: true

  // Dialog internal state
  property string recordedChord: ""
  property string recordedBaseKey: ""
  property string recordError: ""
  readonly property bool hasValidChord: {
    if (!recordedChord) return false
    var parts = recordedChord.split(" + ")
    return parts.length >= 2 && !!recordedBaseKey
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

  property bool isChecking: false
  property bool isApplying: false
  property string _checkResultText: ""
  property string _applyResultText: ""
  property bool hasConflict: false
  property string conflictOwner: ""
  property string conflictOwnerScope: "system"
  property string conflictOtherMode: ""
  property var userSuggestions: []
  property var conflictSuggestions: []
  property string selectedConflictNewChord: ""

  signal applied(var result)
  signal cancelled()

  visible: dialogOpen
  anchors.fill: parent
  color: Qt.rgba(0, 0, 0, 0.72)
  z: 200

  onDialogOpenChanged: {
    if (dialogOpen) {
      recordedChord = ""
      recordedBaseKey = ""
      recordError = ""
      isChecking = false
      isApplying = false
      _checkResultText = ""
      _applyResultText = ""
      hasConflict = false
      conflictOwner = ""
      conflictOwnerScope = "system"
      conflictOtherMode = ""
      userSuggestions = []
      conflictSuggestions = []
      selectedConflictNewChord = ""
      resetPriorConflictChoice = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  MouseArea {
    anchors.fill: parent
    onClicked: {} // Block clicks from falling through
  }

  // Key combination catcher
  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: root.dialogOpen
    Keys.priority: Keys.BeforeItem

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.cancelled()
        event.accepted = true
        return
      }

      var mods = []
      if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
      if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
      if (event.modifiers & Qt.AltModifier) mods.push("ALT")
      if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && mods.length === 0) {
        if (!root.hasConflict && root.hasValidChord && !root.isChecking && !root.isApplying) {
          root.applyNormal()
        } else if (root.hasConflict && root.selectedConflictNewChord !== "" && !root.isApplying) {
          root.applyReassign()
        } else if (!root.hasValidChord) {
          root.recordError = "Cannot apply: Please record a valid key combination first (hold a modifier like SUPER, CTRL, or ALT and press a key)."
        }
        event.accepted = true
        return
      }

      var isModOnly = event.key === Qt.Key_Control || event.key === Qt.Key_Alt ||
                      event.key === Qt.Key_Meta || event.key === Qt.Key_Shift ||
                      event.key === Qt.Key_Super || event.key === Qt.Key_NumLock ||
                      event.key === Qt.Key_Hyper || event.key === Qt.Key_AltGr

      if (isModOnly) {
        root.recordedBaseKey = ""
        root.recordedChord = mods.join(" + ")
        root.recordError = ""
        root.hasConflict = false
        root.conflictOwner = ""
        event.accepted = true
        return
      }

      var keyStr = root.keyToStr(event.key, event.text, event.nativeScanCode)
      if (!keyStr) {
        root.recordError = "Key cannot be recorded: The pressed key (Qt code 0x" + event.key.toString(16) + (event.nativeScanCode ? ", scan code " + event.nativeScanCode : "") + ") is not recognized as a valid keybinding."
        event.accepted = true
        return
      }

      if (mods.length === 0) {
        root.recordedBaseKey = ""
        root.recordedChord = keyStr
        root.recordError = "Single key '" + root.formatChordDisplay(keyStr) + "' cannot be used alone. Keybindings require at least 2 keys (at least one modifier like SUPER, CTRL, or ALT, plus a key)."
        root.hasConflict = false
        root.conflictOwner = ""
        event.accepted = true
        return
      }

      root.recordError = ""
      var chord = mods.join(" + ") + " + " + keyStr
      root.recordedBaseKey = keyStr
      root.recordedChord = chord
      root.checkChord(chord)
      event.accepted = true
    }
  }

  function keyToStr(key, text, scanCode) {
    if (key >= Qt.Key_F1 && key <= Qt.Key_F24)
      return "F" + (key - Qt.Key_F1 + 1)
    if (key >= Qt.Key_0 && key <= Qt.Key_9)
      return String.fromCharCode(48 + (key - Qt.Key_0))
    if (key >= Qt.Key_A && key <= Qt.Key_Z)
      return String.fromCharCode(65 + (key - Qt.Key_A))

    // Direct symbol characters from text
    if (text && text.length === 1) {
      var symMap = {
        "]": "BRACKETRIGHT", "[": "BRACKETLEFT",
        "}": "BRACKETRIGHT", "{": "BRACKETLEFT",
        "-": "MINUS", "_": "MINUS",
        "=": "EQUAL", "+": "EQUAL",
        ";": "SEMICOLON", ":": "SEMICOLON",
        "'": "APOSTROPHE", "\"": "APOSTROPHE",
        ",": "COMMA", "<": "COMMA",
        ".": "PERIOD", ">": "PERIOD",
        "/": "SLASH", "?": "SLASH",
        "\\": "BACKSLASH", "|": "BACKSLASH",
        "`": "GRAVE", "~": "GRAVE"
      }
      if (symMap[text]) return symMap[text]
      var cu = text.toUpperCase()
      if (cu >= "A" && cu <= "Z") return cu
      if (cu >= "0" && cu <= "9") return cu
    }

    // Specific Qt Key constants
    if (key === Qt.Key_BracketRight || key === Qt.Key_BraceRight) return "BRACKETRIGHT"
    if (key === Qt.Key_BracketLeft || key === Qt.Key_BraceLeft) return "BRACKETLEFT"
    if (key === Qt.Key_Minus || key === Qt.Key_Underscore) return "MINUS"
    if (key === Qt.Key_Equal || key === Qt.Key_Plus) return "EQUAL"
    if (key === Qt.Key_Semicolon || key === Qt.Key_Colon) return "SEMICOLON"
    if (key === Qt.Key_Apostrophe || key === Qt.Key_QuoteDbl) return "APOSTROPHE"
    if (key === Qt.Key_Comma || key === Qt.Key_Less) return "COMMA"
    if (key === Qt.Key_Period || key === Qt.Key_Greater) return "PERIOD"
    if (key === Qt.Key_Slash || key === Qt.Key_Question) return "SLASH"
    if (key === Qt.Key_Backslash || key === Qt.Key_Bar) return "BACKSLASH"
    if (key === Qt.Key_QuoteLeft || key === Qt.Key_AsciiTilde) return "GRAVE"

    // Fallback to XKB scancodes for symbol keys
    if (scanCode === 35) return "BRACKETRIGHT"
    if (scanCode === 34) return "BRACKETLEFT"
    if (scanCode === 20) return "MINUS"
    if (scanCode === 21) return "EQUAL"
    if (scanCode === 51) return "BACKSLASH"
    if (scanCode === 47) return "SEMICOLON"
    if (scanCode === 48) return "APOSTROPHE"
    if (scanCode === 49) return "GRAVE"
    if (scanCode === 59) return "COMMA"
    if (scanCode === 60) return "PERIOD"
    if (scanCode === 61) return "SLASH"

    if (key === Qt.Key_Return || key === Qt.Key_Enter) return "RETURN"
    if (key === Qt.Key_Space) return "SPACE"
    if (key === Qt.Key_Tab) return "TAB"
    if (key === Qt.Key_Backspace) return "BACKSPACE"
    if (key === Qt.Key_Delete) return "DELETE"
    if (key === Qt.Key_Insert) return "INSERT"
    if (key === Qt.Key_Home) return "HOME"
    if (key === Qt.Key_End) return "END"
    if (key === Qt.Key_PageUp) return "PAGEUP"
    if (key === Qt.Key_PageDown) return "PAGEDOWN"
    if (key === Qt.Key_Print || key === Qt.Key_SysReq) return "PRINT"
    if (key === Qt.Key_Pause) return "PAUSE"
    if (key === Qt.Key_Left) return "LEFT"
    if (key === Qt.Key_Right) return "RIGHT"
    if (key === Qt.Key_Up) return "UP"
    if (key === Qt.Key_Down) return "DOWN"
    return ""
  }

  function checkChord(chord) {
    if (!chord || !conflictCheckerScript) return
    isChecking = true
    _checkResultText = ""
    selectedConflictNewChord = ""
    if (checkProc.running) {
      checkProc.running = false
    }
    checkProc.command = [conflictCheckerScript, "check-key", chord, mode]
    checkProc.running = true
  }

  function applyNormal() {
    var payload = {
      mode: mode,
      chord: recordedChord,
      resolution_type: "none",
      reset_previous_conflict: hasPriorConflict && resetPriorConflictChoice,
      args_by_mode: argsByMode
    }
    runApply(payload)
  }

  function applyReassign() {
    var payload = {
      mode: mode,
      chord: recordedChord,
      resolution_type: "reassign",
      reassigned_chord: selectedConflictNewChord,
      conflicting_owner: conflictOwner,
      conflicting_scope: conflictOwnerScope,
      other_mode: conflictOtherMode,
      reset_previous_conflict: hasPriorConflict && resetPriorConflictChoice,
      args_by_mode: argsByMode
    }
    runApply(payload)
  }

  function applyTakeover() {
    var payload = {
      mode: mode,
      chord: recordedChord,
      resolution_type: "takeover",
      conflicting_owner: conflictOwner,
      conflicting_scope: conflictOwnerScope,
      other_mode: conflictOtherMode,
      reset_previous_conflict: hasPriorConflict && resetPriorConflictChoice,
      args_by_mode: argsByMode
    }
    runApply(payload)
  }

  function runApply(payload) {
    if (isApplying) return
    isApplying = true
    _applyResultText = ""
    applyProc.command = [conflictCheckerScript, "apply-key", JSON.stringify(payload)]
    applyProc.running = true
  }

  // Dialog Card Container
  Rectangle {
    id: card
    width: Math.min(parent.width - Style.space(32), Style.space(680))
    height: Math.min(col.implicitHeight + Style.space(48), parent.height - Style.space(32))
    anchors.centerIn: parent
    radius: Style.cornerRadius > 0 ? 8 : 0
    color: Color.background
    border.color: Color.accent
    border.width: 1
    clip: true

    Flickable {
      id: flick
      anchors.fill: parent
      anchors.margins: Style.space(16)
      contentWidth: width
      contentHeight: col.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      clip: true

      ScrollBar.vertical: ScrollBar {
        policy: flick.contentHeight > flick.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
      }

      Column {
        id: col
        width: parent.width
        spacing: Style.space(12)

        // Header Title
        Text {
          text: "Choose keybinding — " + root.modeLabel
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
          color: Color.foreground
        }

        // Subtitle / current state
        Text {
          text: "Current keybinding: " + (root.currentChord ? root.formatChordDisplay(root.currentChord) : "(none)")
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.muted
        }

        // Requirement 5: Offer to reset previously conflicting keybinding
        BorderSurface {
          visible: root.hasPriorConflict
          width: parent.width
          implicitHeight: priorCol.implicitHeight + Style.space(16)
          color: Util.alpha(Color.accent, 0.08)
          borderSpec: Border.flat(Color.accent, 1)
          radius: Style.cornerRadius > 0 ? 6 : 0

          Column {
            id: priorCol
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Row {
              spacing: Style.space(8)
              Text {
                text: "\uf05a"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.accent
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "Reset previous conflicting shortcut?"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: Color.foreground
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              text: root.modeLabel + " previously took over its keybinding from \u201c"
                    + root.priorConflictOwner + "\u201d (original: " + root.formatChordDisplay(root.priorConflictChord) + "). "
                    + "Would you like to restore \u201c" + root.priorConflictOwner + "\u201d back to its original keybinding?"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Color.foreground
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.resetPriorConflictChoice
                  ? "\u2611 Restore \u201c" + root.priorConflictOwner + "\u201d to " + root.formatChordDisplay(root.priorConflictChord)
                  : "\u2610 Restore \u201c" + root.priorConflictOwner + "\u201d to " + root.formatChordDisplay(root.priorConflictChord)
                selected: root.resetPriorConflictChoice
                fontSize: Style.font.caption
                tooltipText: "Toggle whether to restore " + root.priorConflictOwner + " back to " + root.formatChordDisplay(root.priorConflictChord)
                onClicked: {
                  root.resetPriorConflictChoice = !root.resetPriorConflictChoice
                }
              }

              Text {
                text: root.resetPriorConflictChoice ? "(Recommended)" : "(Keep modified/disabled)"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.muted
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // Key Recording Box
        Rectangle {
          width: parent.width
          height: 56
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
              text: root.recordedChord ? root.formatChordDisplay(root.recordedChord) : "Press your key combination on keyboard\u2026"
              font.family: Style.font.family
              font.pixelSize: root.recordedChord ? Style.font.heading : Style.font.body
              font.bold: !!root.recordedChord
              color: root.recordedChord ? Color.foreground : Color.muted
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        // Live availability & Conflict / Error Status
        Rectangle {
          id: statusBar
          visible: !!root.recordedChord || !!root.recordError
          width: parent.width
          height: statusCol.implicitHeight + Style.space(16)
          radius: Style.cornerRadius > 0 ? 4 : 0
          color: root.recordError !== ""
                 ? Util.alpha(Color.urgent, 0.22)
                 : (!root.hasValidChord
                    ? Util.alpha(Color.urgent, 0.12)
                    : (root.hasConflict ? Util.alpha(Color.urgent, 0.22) : Util.alpha(Color.accent, 0.15)))
          border.color: root.recordError !== ""
                 ? Color.urgent
                 : (!root.hasValidChord
                    ? Util.alpha(Color.urgent, 0.5)
                    : (root.hasConflict ? Color.urgent : Color.accent))
          border.width: 1

          Row {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              text: root.recordError !== ""
                    ? "\uf06a"
                    : (!root.hasValidChord ? "\uf071" : (root.hasConflict ? "\uf071" : "\uf00c"))
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: root.recordError !== ""
                     ? Color.urgent
                     : (!root.hasValidChord ? Color.urgent : (root.hasConflict ? Color.urgent : Color.accent))
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: statusCol
              width: parent.width - Style.space(32)
              spacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                text: root.recordError !== ""
                      ? root.recordError
                      : (!root.hasValidChord
                         ? "Incomplete combination: Modifiers only (" + root.formatChordDisplay(root.recordedChord) + "). Press a key (letters, numbers, symbols like ], or F1-F12) to complete (2+ keys required)."
                         : (root.isChecking
                            ? "Checking for conflicts\u2026"
                            : (root.hasConflict
                               ? "\u26a0 " + root.formatChordDisplay(root.recordedChord) + " is already in use!"
                               : "\u2713 " + root.formatChordDisplay(root.recordedChord) + " is available.")))
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.hasConflict || root.recordError !== ""
                wrapMode: Text.WordWrap
                color: root.recordError !== "" || root.hasConflict ? Color.urgent : (!root.hasValidChord ? Color.foreground : Color.foreground)
              }

              Text {
                visible: root.hasConflict && !root.isChecking && root.hasValidChord && !root.recordError
                width: parent.width
                text: "Currently used by: \u201c" + root.conflictOwner + "\u201d"
                      + (root.conflictOwnerScope === "plugin" ? " (" + root.conflictOtherMode + " mode)" : "")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                color: root.hasConflict ? Color.foreground : Color.muted
              }
            }
          }
        }

        // 3 Options when Conflict is Detected
        Column {
          visible: root.hasConflict && !root.isChecking && root.hasValidChord
          width: parent.width
          spacing: Style.space(10)

          // OPTION 1: Change the keybinding you are trying to apply
          BorderSurface {
            width: parent.width
            implicitHeight: opt1Col.implicitHeight + Style.space(16)
            color: Util.alpha(Color.foreground, 0.04)
            borderSpec: Border.flat(Util.alpha(Color.foreground, 0.14), 1)
            radius: Style.cornerRadius > 0 ? 6 : 0

            Column {
              id: opt1Col
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                text: "1. Change keybinding for " + root.modeLabel
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: Color.foreground
              }

              Text {
                text: "Pick one of these free suggestions for " + root.modeLabel + " (or press a new combination):"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.muted
              }

              Row {
                spacing: Style.space(6)
                Repeater {
                  model: root.userSuggestions
                  Button {
                    text: root.formatChordDisplay(modelData)
                    fontSize: Style.font.caption
                    tooltipText: "Try " + root.formatChordDisplay(modelData) + " instead"
                    onClicked: {
                      root.recordedBaseKey = modelData.split(" + ").pop()
                      root.recordedChord = modelData
                      root.checkChord(modelData)
                    }
                  }
                }
              }
            }
          }

          // OPTION 2: Change the conflicting keybinding
          BorderSurface {
            width: parent.width
            implicitHeight: opt2Col.implicitHeight + Style.space(16)
            color: Util.alpha(Color.foreground, 0.04)
            borderSpec: Border.flat(root.selectedConflictNewChord !== "" ? Color.accent : Util.alpha(Color.foreground, 0.14), 1)
            radius: Style.cornerRadius > 0 ? 6 : 0

            Column {
              id: opt2Col
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                text: "2. Move \u201c" + root.conflictOwner + "\u201d to a new keybinding"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: Color.foreground
              }

              Text {
                text: "Assign \u201c" + root.conflictOwner + "\u201d to a suggested free shortcut, freeing " + root.formatChordDisplay(root.recordedChord) + " for " + root.modeLabel + ":"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.muted
              }

              Row {
                spacing: Style.space(6)
                Repeater {
                  model: root.conflictSuggestions
                  Button {
                    text: root.formatChordDisplay(modelData)
                    fontSize: Style.font.caption
                    selected: root.selectedConflictNewChord === modelData
                    tooltipText: "Move " + root.conflictOwner + " to " + root.formatChordDisplay(modelData)
                    onClicked: {
                      root.selectedConflictNewChord = modelData
                    }
                  }
                }
              }

              Row {
                visible: root.selectedConflictNewChord !== ""
                spacing: Style.space(8)

                Button {
                  text: "Apply " + root.formatChordDisplay(root.recordedChord) + " & Move \u201c" + root.conflictOwner + "\u201d \u2192 " + root.formatChordDisplay(root.selectedConflictNewChord)
                  fontSize: Style.font.caption
                  selected: true
                  enabled: !root.isApplying
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: root.applyReassign()
                }
              }
            }
          }

          // OPTION 3: Apply without assigning a replacement to the conflicting functionality
          BorderSurface {
            width: parent.width
            implicitHeight: opt3Col.implicitHeight + Style.space(16)
            color: Util.alpha(Color.foreground, 0.04)
            borderSpec: Border.flat(Util.alpha(Color.foreground, 0.14), 1)
            radius: Style.cornerRadius > 0 ? 6 : 0

            Column {
              id: opt3Col
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                text: "3. Apply without replacement (disable \u201c" + root.conflictOwner + "\u201d)"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: Color.foreground
              }

              Text {
                text: "\u201c" + root.conflictOwner + "\u201d will stop working and have no keybinding assigned."
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.muted
              }

              Button {
                text: "Take Over (disable \u201c" + root.conflictOwner + "\u201d)"
                fontSize: Style.font.caption
                enabled: !root.isApplying
                opacity: enabled ? 1.0 : 0.4
                tooltipText: "Assign " + root.formatChordDisplay(root.recordedChord) + " to " + root.modeLabel + " without reassigning " + root.conflictOwner
                onClicked: root.applyTakeover()
              }
            }
          }
        }

        // Dialog Footer Actions
        Row {
          anchors.right: parent.right
          spacing: Style.spacing.sm

          Button {
            width: Math.max(applyBtn.implicitWidth, Style.space(120))
            text: "Cancel"
            onClicked: root.cancelled()
          }

          Button {
            id: applyBtn
            visible: !root.hasConflict
            width: Math.max(implicitWidth, Style.space(120))
            text: root.isApplying ? "Applying\u2026" : (root.hasPriorConflict && root.resetPriorConflictChoice
              ? "Apply & Reset \u201c" + root.priorConflictOwner + "\u201d"
              : "Apply")
            selected: true
            enabled: root.hasValidChord && !root.hasConflict && !root.isChecking && !root.isApplying
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.applyNormal()
          }
        }
      }
    }
  }

  // Background processes
  Process {
    id: checkProc
    stdout: StdioCollector {
      id: checkOut
      waitForEnd: true
      onStreamFinished: {
        root._checkResultText = text
        root.parseCheckResult(text)
      }
    }
    onExited: function(code) {
      root.isChecking = false
      if (!root._checkResultText && checkOut.text) {
        root.parseCheckResult(checkOut.text)
      }
    }
  }

  function parseCheckResult(raw) {
    root.isChecking = false
    try {
      if (!raw) return
      var idx = raw.indexOf("{")
      var jsonStr = idx >= 0 ? raw.substring(idx) : raw
      var s = JSON.parse(jsonStr)
      if (s.valid === false) {
        root.recordError = s.message || "Invalid key combination."
        root.hasConflict = false
        root.conflictOwner = ""
        root.userSuggestions = []
        root.conflictSuggestions = []
        return
      }
      root.recordError = ""
      root.hasConflict = s.conflict === true
      root.conflictOwner = s.owner || ""
      root.conflictOwnerScope = s.owner_scope || "system"
      root.conflictOtherMode = s.other_mode || ""
      root.userSuggestions = s.suggestions_for_user || []
      root.conflictSuggestions = s.suggestions_for_conflicting || []
    } catch (e) {
      root.hasConflict = false
      root.conflictOwner = ""
      root.userSuggestions = []
      root.conflictSuggestions = []
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      id: applyOut
      waitForEnd: true
      onStreamFinished: {
        root._applyResultText = text
        root.parseApplyResult(text, 0)
      }
    }
    onExited: function(code) {
      root.isApplying = false
      if (!root._applyResultText && applyOut.text) {
        root.parseApplyResult(applyOut.text, code)
      }
    }
  }

  function parseApplyResult(raw, code) {
    root.isApplying = false
    try {
      if (!raw) return
      var idx = raw.indexOf("{")
      var jsonStr = idx >= 0 ? raw.substring(idx) : raw
      var res = JSON.parse(jsonStr)
      if (res && res.success === true) {
        root.applied(res)
      } else {
        root.recordError = (res && res.error) ? res.error : "Failed to apply keybinding."
      }
    } catch (e) {
      root.recordError = "Failed to apply keybinding."
    }
  }
}
