import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// The three screen saver styles as tappable cards. Used by the picker on the
// Media page and by the settings sheet.
RowLayout {
    id: options
    property real cardHeight: 230
    spacing: 16

    readonly property var styles: [
        { key: "photos",  icon: "photo", title: qsTr("Photos"),  body: qsTr("One photo at a time, slowly drifting") },
        { key: "collage", icon: "grid",  title: qsTr("Collage"), body: qsTr("A changing mosaic of family photos") },
        { key: "video",   icon: "video", title: qsTr("Video"),   body: qsTr("Family videos full screen, muted") }
    ]

    Repeater {
        model: options.styles
        delegate: Rectangle {
            required property var modelData
            readonly property bool selected: Device.screensaver === modelData.key
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: options.cardHeight
            radius: 24
            color: selected ? Theme.accentSoft : Theme.surfaceAlt
            border.width: selected ? 3 : 0
            border.color: Theme.accent
            scale: optTap.pressed ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: Theme.quick } }
            Behavior on color { ColorAnimation { duration: Theme.smooth } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: options.cardHeight < 200 ? 18 : 22
                spacing: options.cardHeight < 200 ? 6 : 10
                Rectangle {
                    width: 64; height: 64; radius: 32
                    color: selected ? Theme.accent : Theme.surface
                    Behavior on color { ColorAnimation { duration: Theme.smooth } }
                    Icon { anchors.centerIn: parent; name: modelData.icon; size: 30; color: selected ? Theme.accentInk : Theme.text }
                }
                Item { Layout.fillHeight: true }
                Label { text: modelData.title; color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true
                    text: modelData.body
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs + 1
                }
            }
            TapHandler { id: optTap; onTapped: Device.screensaver = modelData.key }
        }
    }
}
