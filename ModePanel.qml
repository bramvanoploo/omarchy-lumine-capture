// Capture-mode picker, opened under the bar icon: a row of large icon
// buttons (one per lumine-capture mode, each launching that capture), and a
// row below for the settings panel and the screenshots folder. The card is
// sized by its content.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "LaunchArgs.js" as LaunchArgs

PopupCard {
  id: root

  // {mode value: chord} from the config, shown in each tooltip.
  property var chords: ({})
  // For the version pill in the header, same source as the settings panel.
  property var configManager: null

  readonly property var modeHints: ({
    "": "Open the capture editor",
    "full": "Capture the whole screen",
    "window": "Capture the focused window",
    "region": "Capture a selected region",
    "region-ocr": "Select a region and read its text"
  })

  // FontAwesome glyph per mode value.
  readonly property var modeIconGlyphs: ({
    "": "\uf040",       // pencil — the editor
    "full": "\uf065",   // expand — full screen
    "window": "\uf2d0", // window maximize
    "region": "\uf125", // crop — region
    "region-ocr": "\uf15c" // file lines — region, straight to OCR
  })

  // Which mode was picked; the owner launches it and closes us.
  signal picked(string mode)
  signal settingsRequested()
  signal screenshotsRequested()
  // The shot delay was edited; the owner re-applies the shortcuts so the
  // chords run commands with the new -d flag.
  signal delayChanged()

  // Fixed sizes: the rows bind their width off the delegates, so deriving
  // button widths from the rows would be a binding loop (zero widths).
  readonly property int modeBtnWidth: Style.space(48)
  readonly property int modeBtnHeight: Style.space(34)
  readonly property int actionBtnHeight: Style.space(26)
  // The card fits its content: the PopupWindow clips anything outside the card,
  // and a clipped button cannot be pressed.
  readonly property int rowWidth: modeBtnWidth * LaunchArgs.MODES.length
    + Style.space(6) * (LaunchArgs.MODES.length - 1)
  readonly property int actionBtnWidth: (rowWidth - Style.space(6)) / 2

  // The card hugs the capture-mode row: contentWidth = that row exactly.
  contentWidth: fittedContentWidth(rowWidth + padding * 2)
  contentHeight: fittedContentHeight(headerRow.height + Style.space(8) + modeBtnHeight
    + Style.space(8) + delayColumn.height + Style.space(8) + actionBtnHeight)

  contentItem: Column {
    // The card's inner area: contentWidth includes the padding.
    width: root.contentWidth - root.padding * 2
    spacing: Style.space(8)

    // --- header: icon + plugin name + version, like the settings panel ---
    Row {
      id: headerRow
      width: parent.width
      spacing: Style.space(10)

      Text {
        text: "\uf030"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        anchors.verticalCenter: parent.verticalCenter
      }

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
        height: Style.space(16)
        width: panelVersionText.implicitWidth + Style.space(10)
        radius: Style.cornerRadius > 0 ? 4 : 0
        color: Util.alpha(Color.accent, 0.15)
        border.color: Util.alpha(Color.accent, 0.4)
        border.width: 1

        Text {
          id: panelVersionText
          anchors.centerIn: parent
          text: "v" + (root.configManager ? root.configManager.version : "")
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.Bold
        }
      }
    }

    // --- capture modes, big icon buttons filling the row ---
    Row {
      id: modeRow
      spacing: Style.space(6)

      Repeater {
        model: LaunchArgs.MODES

        Button {
          id: modeBtn
          required property var modelData
          // Fixed size: the row width binds off the delegates, so deriving the
          // button width from the row would be a binding loop (zero widths).
          width: modeBtnWidth
          height: modeBtnHeight
          horizontalPadding: 0
          verticalPadding: 0
          // Icon glyphs come from the bar's icon font.
          fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
          iconText: root.modeIconGlyphs[modelData.value] || "\uf030"
          iconSize: Math.round(Style.bar.iconFont * 1.4)
          foreground: root.chords[modelData.value] ? Color.foreground : Util.alpha(Color.foreground, 0.55)
          tooltipText: modelData.label + " — " + (root.modeHints[modelData.value] || "")
            + (root.chords[modelData.value] ? "\nShortcut: " + root.chords[modelData.value] : "\nNo shortcut")
          onClicked: root.picked(modelData.value)
        }
      }
    }

    // --- shot delay, between the modes and the actions ---
    Column {
      id: delayColumn
      width: parent.width
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(4)
        Text {
          text: "Delay"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          width: parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2
          text: ""
        }
        Text {
          color: Util.alpha(Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: parseInt(root.configManager ? root.configManager.delay : "0", 10) > 0
            ? parseInt(root.configManager.delay, 10) + "s" : "No delay"
        }
      }

      PanelSlider {
        id: delaySlider
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 10
        integer: true // snap to whole seconds
        tickCount: 11
        // The config re-reads the committed value back into `value`, so the
        // Binding element puts the knob back on the config after each drag.
        Binding { target: delaySlider; property: "value"; value: parseInt(root.configManager ? root.configManager.delay : "0", 10) || 0 }
        // Live drags only move the in-memory mirror the launcher reads;
        // saving the settings file on every pixel would hammer the disk.
        onMoved: function(v) { if (root.configManager) root.configManager.setDelay(String(Math.round(v))) }
        onReleased: function(v) {
          if (!root.configManager) return
          var next = String(Math.round(v))
          if (next !== root.configManager.delay) root.configManager.setDelay(next)
          var patch = {}
          patch["delay"] = next
          root.configManager.saveSettings(patch)
          root.delayChanged()
        }
      }
    }

    // --- actions below: settings panel and screenshots folder ---
    Row {
      id: actionRow
      spacing: Style.space(6)

      Button {
        width: actionBtnWidth
        height: actionBtnHeight
        fontFamily: Style.font.family
        iconText: "\uf013" // gear
        iconSize: Style.font.bodySmall
        text: "Settings"
        fontSize: Style.font.bodySmall
        tooltipText: "Open the LumineCapture settings"
        onClicked: root.settingsRequested()
      }

      Button {
        width: actionBtnWidth
        height: actionBtnHeight
        fontFamily: Style.font.family
        iconText: "\uf07b" // open folder
        iconSize: Style.font.bodySmall
        text: "Screenshots"
        fontSize: Style.font.bodySmall
        tooltipText: "Open the folder the shots are saved to"
        onClicked: root.screenshotsRequested()
      }
    }
  }
}
