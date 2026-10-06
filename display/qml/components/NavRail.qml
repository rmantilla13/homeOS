import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Left-hand navigation. Icons are emoji for now; swap for an SVG icon set.
Rectangle {
    id: rail
    property int currentIndex: 0
    signal selected(int index)

    readonly property var items: [
        { icon: "🏠", label: qsTr("Home") },
        { icon: "📅", label: qsTr("Calendar") },
        { icon: "✅", label: qsTr("Chores") },
        { icon: "⭐", label: qsTr("Rewards") },
        { icon: "🖼️", label: qsTr("Photos") },
        { icon: "🍽️", label: qsTr("Planner") }
    ]

    color: Theme.surface

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 32
        anchors.bottomMargin: 32
        spacing: 12

        Repeater {
            model: rail.items
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: index === rail.currentIndex

                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 104
                Layout.preferredHeight: 104
                radius: 28
                color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15) : "transparent"

                Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.icon
                        font.family: Theme.emojiFont
                        font.pixelSize: 40
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.label
                        font.pixelSize: Theme.fontXs
                        font.weight: active ? Font.DemiBold : Font.Normal
                        color: active ? Theme.accent : Theme.textMuted
                    }
                }
                TapHandler { onTapped: rail.selected(index) }
            }
        }

        Item { Layout.fillHeight: true }

        // Tap to show the photo frame right away.
        Label {
            Layout.alignment: Qt.AlignHCenter
            text: "🌙"
            font.family: Theme.emojiFont
            font.pixelSize: 36
            TapHandler { onTapped: Device.sleepNow() }
        }
    }
}
