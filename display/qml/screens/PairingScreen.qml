import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// First-run screen: shows a 6-digit code that a parent enters in the iOS app.
Rectangle {
    color: Theme.background

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 40

        Label {
            Layout.alignment: Qt.AlignHCenter
            text: "Ohana"
            color: Theme.accent
            font.pixelSize: Theme.fontXl
            font.weight: Font.Bold
        }
        Label {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Pair this display with your family")
            color: Theme.text
            font.pixelSize: Theme.fontLg
        }

        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: 20
            Repeater {
                model: Store.pairingCode ? Store.pairingCode.split("") : ["", "", "", "", "", ""]
                delegate: Rectangle {
                    required property string modelData
                    width: 130; height: 170
                    radius: 24
                    color: Theme.surface
                    Label {
                        anchors.centerIn: parent
                        text: modelData
                        color: Theme.text
                        font.pixelSize: 110
                        font.weight: Font.DemiBold
                    }
                }
            }
        }

        BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            running: Store.pairingCode === ""
            visible: running
        }

        Label {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            text: Store.pairingCode
                  ? qsTr("On your iPhone, open Ohana → Settings → Pair a display,\nand enter this code. It refreshes every 10 minutes.")
                  : (Store.lastError ? qsTr("Can't reach Ohana cloud. Retrying…") : qsTr("Getting a pairing code…"))
            color: Theme.textMuted
            font.pixelSize: Theme.fontMd
        }
    }
}
