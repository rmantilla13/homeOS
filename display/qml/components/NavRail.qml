import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Left-hand navigation. The active screen is a blue pill with white icon and label.
Rectangle {
    id: rail
    property int currentIndex: 0
    signal selected(int index)
    signal settingsRequested()

    readonly property var items: [
        { icon: "home",     label: qsTr("Home") },
        { icon: "calendar", label: qsTr("Calendar") },
        { icon: "chores",   label: qsTr("Chores") },
        { icon: "star",     label: qsTr("Rewards") },
        { icon: "photo",    label: qsTr("Media") },
        { icon: "meals",    label: qsTr("Meals") }
    ]

    color: Theme.surface

    // Highlight that glides to the active item.
    Rectangle {
        id: pill
        readonly property Item target: items.count > 0 && column.height > 0 ? items.itemAt(rail.currentIndex) : null
        x: target ? column.x + target.x : 0
        y: target ? column.y + target.y : 0
        width: target ? target.width : 0
        height: target ? target.height : 0
        radius: 26
        color: Theme.accent
        Behavior on y { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.25 } }
    }

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.topMargin: Theme.compact ? 16 : 28
        anchors.bottomMargin: Theme.compact ? 16 : 28
        spacing: Theme.compact ? 8 : 12

        Repeater {
            id: items
            model: rail.items
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: index === rail.currentIndex

                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Theme.compact ? 80 : 96
                Layout.preferredHeight: Theme.compact ? 80 : 92
                radius: 26
                color: "transparent"
                scale: navTap.pressed ? 0.94 : 1
                Behavior on scale { NumberAnimation { duration: Theme.quick } }

                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: modelData.icon
                        size: Theme.compact ? 26 : 30
                        color: active ? Theme.accentInk : Theme.textMuted
                        Behavior on color { ColorAnimation { duration: Theme.smooth } }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.label
                        font.pixelSize: 14
                        font.weight: active ? Font.DemiBold : Font.Medium
                        color: active ? Theme.accentInk : Theme.textMuted
                        Behavior on color { ColorAnimation { duration: Theme.smooth } }
                    }
                }
                TapHandler { id: navTap; onTapped: rail.selected(index) }
            }
        }

        Item { Layout.fillHeight: true }

        IconButton {
            Layout.alignment: Qt.AlignHCenter
            icon: "settings"
            fill: Theme.surfaceAlt
            ink: Theme.textMuted
            onClicked: rail.settingsRequested()
        }

        // Show the photo frame right away.
        IconButton {
            Layout.alignment: Qt.AlignHCenter
            icon: "moon"
            fill: Theme.surfaceAlt
            ink: Theme.textMuted
            onClicked: Device.sleepNow()
        }
    }
}
