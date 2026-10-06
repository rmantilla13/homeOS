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

    readonly property var items: [
        { icon: "home",     label: qsTr("Home") },
        { icon: "calendar", label: qsTr("Calendar") },
        { icon: "chores",   label: qsTr("Chores") },
        { icon: "star",     label: qsTr("Rewards") },
        { icon: "photo",    label: qsTr("Photos") },
        { icon: "meals",    label: qsTr("Meals") }
    ]

    color: Theme.surface

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Theme.compact ? 16 : 28
        anchors.bottomMargin: Theme.compact ? 16 : 28
        spacing: Theme.compact ? 8 : 12

        Repeater {
            model: rail.items
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: index === rail.currentIndex

                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Theme.compact ? 80 : 96
                Layout.preferredHeight: Theme.compact ? 80 : 92
                radius: 26
                color: active ? Theme.accent : "transparent"
                Behavior on color { ColorAnimation { duration: 180 } }

                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Icon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: modelData.icon
                        size: Theme.compact ? 26 : 30
                        color: active ? Theme.accentInk : Theme.textMuted
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.label
                        font.pixelSize: 14
                        font.weight: active ? Font.DemiBold : Font.Medium
                        color: active ? Theme.accentInk : Theme.textMuted
                    }
                }
                TapHandler { onTapped: rail.selected(index) }
            }
        }

        Item { Layout.fillHeight: true }

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
