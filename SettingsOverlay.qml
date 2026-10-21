import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LumineConfig.js" as LC

PopupCard {
  id: root

  property var configManager: null
  property bool isInstalled: false

  property string currentKeybinding: ""
  property string launchArgs: ""
  property bool suggestedKeyConflict: false
  property string suggestedKeyConflictMessage: ""
  property var keySuggestions: []
  property string statusText: ""

  // Key recording dialog
  property bool recordingDialogOpen: false
  property string recordedChord: ""
  property bool isCheckingRecordedKey: false

  // Conflict resolution
  property bool conflictDialogOpen: false
  property string conflictMessage: ""
  property var conflictSuggestions: []
  property string pendingChord: ""

  // LumineCapture config model
  property var sections: []
  property int configRev: 0
  property var collapsed: ({})
  readonly property string configPath: (Quickshell.env("HOME") || "") + "/.config/LumineCapture/config.toml"

  padding: Style.space(20)
  contentWidth: fittedContentWidth(Style.space(560))
  contentHeight: fittedContentHeight(contentCol.implicitHeight)

  onOpenChanged: {
    if (open) {
      loadCurrentSettings()
      refreshStatus()
      configView.reload()
      statusText = ""
    } else {
      recordingDialogOpen = false
      conflictDialogOpen = false
    }
  }

  function loadCurrentSettings() {
    if (configManager) {
      currentKeybinding = configManager.keybinding || ""
      launchArgs = configManager.launchArgs || ""
    }
  }

  function refreshStatus() {
    if (!configManager) return
    statusProc.command = [configManager.conflictCheckerScript, "status"]
    statusProc.running = true
  }




  function checkRecordedKey(chord) {
    if (!configManager || !chord) return
    isCheckingRecordedKey = true
    keyCheckProc.command = [configManager.conflictCheckerScript, "check-key", chord]
    keyCheckProc.running = true
  }

  function applyBinding(chord, unbind) {
    if (!configManager) return
    applyProc.command = [configManager.conflictCheckerScript, "apply", chord || "", launchArgs, unbind ? "true" : "false"]
    applyProc.running = true
  }

  function setKeybinding(chord) {
    currentKeybinding = chord
    if (configManager) configManager.saveSettings({ keybinding: chord })
    applyBinding(chord, false)
  }

  function saveLaunchArgs() {
    if (configManager) configManager.saveSettings({ launchArgs: launchArgs })
    // Re-apply the binding so the exec command picks up the new args
    if (currentKeybinding) applyBinding(currentKeybinding, false)
  }

  function takeOverChord() {
    applyBinding(pendingChord, true)
  }

  // ---------- LumineCapture config ----------

  function reloadConfigModel() {
    var raw = configView.text()
    if (!raw) { sections = []; return }
    sections = LC.parse(raw)
    configRev++
  }


  function saveConfig() {
    configView.setText(LC.serialize(sections) + "\n")
    statusText = "LumineCapture configuration saved."
  }

  function toggleSection(name) {
    var c = Object.assign({}, collapsed)
    c[name] = !c[name]
    collapsed = c
  }

  function commitItem(item, text) { LC.applyVal(item, text); saveConfig() }


  // ---------- key chord recorder ----------

  function modList(m) {
    var mods = []
    if (m & Qt.MetaModifier) mods.push("SUPER")
    if (m & Qt.ControlModifier) mods.push("CTRL")
    if (m & Qt.ShiftModifier) mods.push("SHIFT")
    if (m & Qt.AltModifier) mods.push("ALT")
    return mods
  }

  function keyName(k) {
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
    return map[k] || ""
  }

  Column {
    id: contentCol
    width: parent.width
    spacing: Style.space(14)

  Process {
    id: statusProc
    command: ["true"]
    stdout: StdioCollector { id: statusOut }
    onExited: function(code) {
      try {
        var s = JSON.parse(statusOut.text)
        suggestedKeyConflict = s.suggested_key_conflict === true
        suggestedKeyConflictMessage = s.suggested_key_conflict_message || ""
        keySuggestions = s.key_suggestions || []
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
      if (res && res.conflict) {
        conflictMessage = res.message || "Keybinding is already in use."
        conflictSuggestions = res.suggestions || []
        pendingChord = root.recordedChord
        conflictDialogOpen = true
      } else {
        applyBinding(root.recordedChord, false)
      }
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
        conflictDialogOpen = false
        statusText = "Keybinding applied."
        refreshStatus()
      } else {
        statusText = (res && res.error) ? res.error : "Applying keybinding failed."
      }
    }
  }
  FileView {
    id: configView
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.reloadConfigModel()
    onLoadFailed: { root.sections = []; root.configRev++ }
    onFileChanged: reload()
  }
  Process {
    id: defaultsProc
    command: ["lumine-capture", "--print-default-config"]
    stdout: StdioCollector { id: defaultsOut }
    onExited: function(code) {
      if (code === 0 && defaultsOut.text) {
        sections = LC.parse(defaultsOut.text)
        configRev++
        saveConfig()
      } else {
        statusText = "Could not read LumineCapture defaults."
      }
    }
  }

    // ===== Header =====
    Row {
      width: parent.width
      spacing: Style.space(10)

      Text {
        text: "\uf030"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.heading * 1.1
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        Text {
          text: "OmaLumineCapture"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.weight: Font.DemiBold
        }

        Text {
          text: "v" + (configManager ? configManager.version : "") + (root.isInstalled ? "" : "  \u00b7  app not installed")
          color: root.isInstalled ? Util.alpha(Color.foreground, 0.5) : Color.accent
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

    // ===== Capture section =====
    Text {
      text: "CAPTURE"
      color: Util.alpha(Color.foreground, 0.45)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.weight: Font.Bold
    }

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: Style.space(150)
        text: "Keybinding"
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
          text: root.currentKeybinding ? root.currentKeybinding : "(none)"
          color: root.currentKeybinding ? Color.foreground : Util.alpha(Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      Item { width: Style.space(1); height: 1 }

      BorderSurface {
        implicitWidth: recText.implicitWidth + Style.space(20)
        implicitHeight: Style.space(28)
        color: recMa.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.85)
        borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
        radius: Style.cornerRadius > 0 ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: recText
          anchors.centerIn: parent
          text: "Record\u2026"
          color: Color.background || "#0c0d13"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.Bold
        }

        MouseArea {
          id: recMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.recordingDialogOpen = true
            root.recordedChord = ""
            Qt.callLater(function() { recorderCatcher.forceActiveFocus() })
          }
        }
      }

      BorderSurface {
        implicitWidth: clrText.implicitWidth + Style.space(20)
        implicitHeight: Style.space(28)
        color: clrMa.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"
        borderSpec: Border.flat(Util.alpha(Color.foreground, 0.3), Style.normalBorderWidth)
        radius: Style.cornerRadius > 0 ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: clrText
          anchors.centerIn: parent
          text: "Clear"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: clrMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.currentKeybinding = ""; if (configManager) configManager.saveSettings({ keybinding: "" }); applyBinding("", false) }
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

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: Style.space(150)
        text: "Launch arguments"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }

      BorderSurface {
        width: parent.width - Style.space(158)
        implicitHeight: Style.space(28)
        color: Util.alpha(Color.foreground, 0.06)
        borderSpec: Border.flat(Util.alpha(Color.foreground, 0.18), Style.normalBorderWidth)
        radius: Style.cornerRadius > 0 ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter

        TextField {
          id: argsField
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          text: root.launchArgs
          placeholderText: "e.g. -r -t sc  (empty = editor)"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          onAccepted: { root.launchArgs = text; root.saveLaunchArgs() }
          onActiveFocusChanged: if (!activeFocus) { root.launchArgs = text; root.saveLaunchArgs() }
        }
      }
    }

    // ===== LumineCapture config section =====
    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: "LUMINECAPTURE CONFIG"
        color: Util.alpha(Color.foreground, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: Font.Bold
        anchors.verticalCenter: parent.verticalCenter
      }

      Item { width: Style.space(1); height: 1 }

      BorderSurface {
        implicitWidth: dftText.implicitWidth + Style.space(16)
        implicitHeight: Style.space(24)
        color: dftMa.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"
        borderSpec: Border.flat(Util.alpha(Color.foreground, 0.3), Style.normalBorderWidth)
        radius: Style.cornerRadius > 0 ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: dftText
          anchors.centerIn: parent
          text: "Restore defaults"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: dftMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { if (!defaultsProc.running) defaultsProc.running = true }
        }
      }
    }

    Text {
      width: parent.width
      text: root.sections.length === 0
            ? "No LumineCapture config found yet (" + root.configPath + "). It appears after the app's first launch, or press \"Restore defaults\"."
            : "Editing a field saves " + root.configPath + " immediately (applied on next launch)."
      color: Util.alpha(Color.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Flickable {
      width: parent.width
      height: Math.min(configList.implicitHeight + Style.space(8), Style.space(420))
      contentHeight: configList.implicitHeight + Style.space(8)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      visible: root.sections.length > 0

      Column {
        id: configList
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.sections

          Column {
            width: parent.width
            spacing: Style.space(4)

            property var sec: modelData
            property bool isCollapsed: !!root.collapsed[modelData.name]

            BorderSurface {
              width: parent.width
              implicitHeight: Style.space(26)
              color: secHeadMa.containsMouse ? Util.alpha(Color.foreground, 0.06) : "transparent"
              borderSpec: Border.flat(Util.alpha(Color.foreground, 0.12), Style.normalBorderWidth)
              radius: Style.cornerRadius > 0 ? 4 : 0

              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  text: sec.isCollapsed ? "\uf054" : "\uf078"
                  color: Util.alpha(Color.foreground, 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: sec.name
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.weight: Font.Bold
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: secHeadMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleSection(sec.name)
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !sec.isCollapsed

              Repeater {
                model: sec.items

                Row {
                  width: configList.width
                  spacing: Style.space(8)

                  property var item: modelData

                  Text {
                    width: Style.space(150)
                    text: modelData.key
                    color: Util.alpha(Color.foreground, 0.8)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Boolean toggle
                  BorderSurface {
                    visible: item.kind === "bool"
                    width: Style.space(36)
                    height: Style.space(20)
                    radius: 10
                    color: item.val ? Color.accent : Util.alpha(Color.foreground, 0.15)
                    borderSpec: Border.flat(item.val ? Color.accent : Util.alpha(Color.foreground, 0.25), Style.normalBorderWidth)
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: 7
                      color: Color.background || "#0c0d13"
                      y: 3
                      x: item.val ? 36 - 14 - 3 : 3
                      Behavior on x { NumberAnimation { duration: 120 } }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { item.val = !item.val; root.saveConfig(); root.configRev++ }
                    }
                  }

                  // Value field (num / str / arr)
                  BorderSurface {
                    visible: item.kind !== "bool"
                    width: configList.width - Style.space(166)
                    implicitHeight: Style.space(24)
                    color: Util.alpha(Color.foreground, 0.05)
                    borderSpec: Border.flat(Util.alpha(Color.foreground, 0.15), Style.normalBorderWidth)
                    radius: Style.cornerRadius > 0 ? 3 : 0
                    anchors.verticalCenter: parent.verticalCenter

                    TextField {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(6)
                      text: LC.displayVal(item)
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      onAccepted: root.commitItem(item, text)
                      onActiveFocusChanged: if (!activeFocus) root.commitItem(item, text)
                    }
                  }
                }
              }
            }
          }
        }
      }
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

    // ===== Recording overlay (inside the card) =====
    Rectangle {
      anchors.fill: parent
      visible: root.recordingDialogOpen
      color: Util.alpha(Color.background, 0.9)
      radius: Style.cornerRadius

      Column {
        anchors.centerIn: parent
        spacing: Style.space(12)

        Text {
          text: "Press your key combination"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
        }

        Text {
          text: root.recordedChord ? root.recordedChord : "\u2014"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.weight: Font.Bold
        }

        Text {
          text: "Esc \u00b7 cancel"
          color: Util.alpha(Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Item {
        id: recorderCatcher
        anchors.fill: parent
        focus: root.recordingDialogOpen

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.recordingDialogOpen = false
            event.accepted = true
            return
          }
          var isMod = event.key === Qt.Key_Meta || event.key === Qt.Key_Control ||
                      event.key === Qt.Key_Shift || event.key === Qt.Key_Alt ||
                      event.key === Qt.Key_Super || event.key === Qt.Key_NumLock
          var mods = modList(event.modifiers)
          if (isMod) {
            root.recordedChord = mods.join(" + ")
          } else {
            var kn = keyName(event.key)
            if (kn) {
              root.recordedChord = (mods.length ? mods.join(" + ") + " + " : "") + kn
              root.recordingDialogOpen = false
              root.checkRecordedKey(root.recordedChord)
            }
          }
          event.accepted = true
        }
      }
    }

    // ===== Conflict resolution overlay (inside the card) =====
    Rectangle {
      anchors.fill: parent
      visible: root.conflictDialogOpen
      color: Util.alpha(Color.background, 0.94)
      radius: Style.cornerRadius

      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(48)
        spacing: Style.space(12)

        Text {
          text: "Keybinding conflict"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
        }

        Text {
          text: root.conflictMessage
          color: Util.alpha(Color.foreground, 0.7)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.conflictSuggestions

          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(30)
            color: sugMa.containsMouse ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.accent, 0.08)
            borderSpec: Border.flat(Util.alpha(Color.accent, 0.4), Style.normalBorderWidth)
            radius: Style.cornerRadius > 0 ? 4 : 0

            Text {
              anchors.centerIn: parent
              text: "Use " + modelData + " instead"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: Font.Medium
            }

            MouseArea {
              id: sugMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.conflictDialogOpen = false; root.setKeybinding(modelData) }
            }
          }
        }

        Row {
          spacing: Style.space(10)
          anchors.right: parent.right

          BorderSurface {
            implicitWidth: tkText.implicitWidth + Style.space(18)
            implicitHeight: Style.space(30)
            color: tkMa.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.85)
            radius: Style.cornerRadius > 0 ? 4 : 0

            Text {
              id: tkText
              anchors.centerIn: parent
              text: "Take over (disable conflicting binding)"
              color: Color.background || "#0c0d13"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: Font.Bold
            }

            MouseArea {
              id: tkMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.takeOverChord()
            }
          }

          BorderSurface {
            implicitWidth: cxText.implicitWidth + Style.space(18)
            implicitHeight: Style.space(30)
            color: cxMa.containsMouse ? Util.alpha(Color.foreground, 0.12) : "transparent"
            borderSpec: Border.flat(Util.alpha(Color.foreground, 0.3), Style.normalBorderWidth)
            radius: Style.cornerRadius > 0 ? 4 : 0

            Text {
              id: cxText
              anchors.centerIn: parent
              text: "Cancel"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: cxMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.conflictDialogOpen = false
            }
          }
        }
      }
    }
  }
}
