import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Choose what the screen shows when nobody is using it.
Dialog {
    id: picker
    modal: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent ? parent.width - 80 : 900, 900)
    padding: 32
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.smooth }
            NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: Theme.smooth; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.quick } }

    background: Rectangle { radius: 32; color: Theme.surface }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }

    readonly property var options: [
        { key: "photos",  icon: "photo", title: qsTr("Photos"),  body: qsTr("One photo at a time, slowly drifting") },
        { key: "collage", icon: "grid",  title: qsTr("Collage"), body: qsTr("A mosaic of family photos that keeps changing") },
        { key: "video",   icon: "video", title: qsTr("Video"),   body: qsTr("Family videos full screen, muted") }
    ]

    contentItem: ColumnLayout {
        spacing: 24
        RowLayout {
            Layout.fillWidth: true
            Column {
                Layout.fillWidth: true
                Label { text: qsTr("Screen saver"); color: Theme.text; font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                Label { text: qsTr("Shown after %1 minutes without a touch").arg(Math.round(Device.idleTimeoutSec / 60)); color: Theme.textMuted; font.pixelSize: Theme.fontSm }
            }
            IconButton { icon: "close"; fill: Theme.surfaceAlt; onClicked: picker.close() }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            Repeater {
                model: picker.options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool selected: Device.screensaver === modelData.key
                    Layout.fillWidth: true
                    Layout.preferredHeight: 230
                    radius: 24
                    color: selected ? Theme.accentSoft : Theme.surfaceAlt
                    border.width: selected ? 3 : 0
                    border.color: Theme.accent
                    scale: optTap.pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.quick } }
                    Behavior on color { ColorAnimation { duration: Theme.smooth } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 10
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
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontXs + 1
                        }
                    }
                    TapHandler { id: optTap; onTapped: Device.screensaver = modelData.key }
                }
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 12
            PillButton { text: qsTr("Done"); fill: Theme.surfaceAlt; ink: Theme.text; onClicked: picker.close() }
            PillButton {
                text: qsTr("Preview")
                onClicked: { picker.close(); Device.sleepNow() }
            }
        }
    }
}
