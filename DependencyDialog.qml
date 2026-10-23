import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

PanelWindow {
  id: root

  property bool open: false
  property bool yayMissing: false

  signal canceled()
  signal confirmed()

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omalumine-dependency-dialog"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  property int selectedIndex: 1 // 0 = Cancel, 1 = Install

  onOpenChanged: {
    if (open) {
      selectedIndex = 1
      Qt.callLater(function() { dialogCatcher.forceActiveFocus() })
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.75)

    MouseArea {
      anchors.fill: parent
      onClicked: root.canceled()
    }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(48), Style.space(520))
      height: card.contentTopInset + card.contentBottomInset + contentColumn.implicitHeight
      anchors.centerIn: parent
      color: Color.background
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      padding: Style.space(26)
      radius: Style.cornerRadius

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: dialogCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: root.open

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.canceled()
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.selectedIndex = (root.selectedIndex === 0 ? 1 : 0)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (root.selectedIndex === 0) root.canceled()
            else root.confirmed()
            event.accepted = true
          }
        }

        Column {
          id: contentColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(18)

          Row {
            spacing: Style.space(16)

            BorderSurface {
              width: Style.space(46)
              height: Style.space(46)
              radius: Style.cornerRadius > 0 ? 8 : 2
              color: Util.alpha(Color.accent, 0.12)
              borderSpec: Border.flat(Util.alpha(Color.accent, 0.35), Style.normalBorderWidth)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                anchors.centerIn: parent
                text: "\uf030"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.heading * 1.3
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                text: "Install LumineCapture?"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.weight: Font.DemiBold
              }

              Text {
                text: "OmaLumineCapture needs LumineCapture to take screenshots."
                color: Util.alpha(Color.foreground, 0.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          BorderSurface {
            width: parent.width
            implicitHeight: innerCol.implicitHeight + Style.space(24)
            radius: Style.cornerRadius > 0 ? 6 : 0
            color: Util.alpha(Color.foreground, 0.04)
            borderSpec: Border.flat(Util.alpha(Color.foreground, 0.12), Style.normalBorderWidth)
            padding: Style.space(12)

            Column {
              id: innerCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  text: "\uf187"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "lumine-capture-bin"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: Font.Bold
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item { width: Style.space(10) }

                BorderSurface {
                  implicitWidth: repoText.implicitWidth + Style.space(12)
                  implicitHeight: repoText.implicitHeight + Style.space(6)
                  radius: Style.cornerRadius > 0 ? 4 : 0
                  color: Util.alpha(Color.accent, 0.12)
                  borderSpec: Border.flat(Util.alpha(Color.accent, 0.28), Style.normalBorderWidth)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: repoText
                    anchors.centerIn: parent
                    text: "AUR"
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Medium
                  }
                }
              }

              Text {
                width: parent.width
                text: "LumineCapture is a fast, lightweight Wayland screenshot tool. It is packaged in the AUR, so the AUR helper \"yay\" is used for the installation."
                color: Util.alpha(Color.foreground, 0.75)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.25
              }

              Row {
                visible: root.yayMissing
                width: parent.width
                spacing: Style.space(8)

                Text {
                  text: "\uf071"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "yay is not installed on this system. It will be installed from the AUR first, as it is required to install lumine-capture-bin."
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: root.yayMissing ? "Install yay and lumine-capture-bin now?"
                                    : "Install lumine-capture-bin now?"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Packages are installed in a terminal window without further confirmation (--noconfirm). Building from the AUR may take a few minutes."
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Row {
            anchors.right: parent.right
            spacing: Style.space(12)

            BorderSurface {
              readonly property bool selected: root.selectedIndex === 0
              width: Style.space(105)
              height: Style.space(36)
              color: selected ? Util.alpha(Color.foreground, 0.12) : "transparent"
              borderSpec: Border.flat(selected ? Color.accent : Util.alpha(Color.foreground, 0.35), Style.normalBorderWidth)
              radius: Style.cornerRadius > 0 ? 4 : 0

              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: "Cancel"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.weight: Font.Medium
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "Esc"
                  color: Util.alpha(Color.foreground, 0.45)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption * 0.85
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = 0
                onClicked: root.canceled()
              }
            }

            BorderSurface {
              readonly property bool selected: root.selectedIndex === 1
              width: Style.space(150)
              height: Style.space(36)
              color: selected ? Color.accent : Util.alpha(Color.accent, 0.88)
              borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
              radius: Style.cornerRadius > 0 ? 4 : 0

              Row {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: "\uf019"
                  color: Color.background || "#0c0d13"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.yayMissing ? "Install (yay + app)" : "Install app"
                  color: Color.background || "#0c0d13"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.weight: Font.Bold
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "\u21b5"
                  color: Util.alpha(Color.background || "#0c0d13", 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption * 0.9
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = 1
                onClicked: root.confirmed()
              }
            }
          }
        }
      }
    }
  }
}
