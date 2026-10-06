import QtQuick
import QtQuick.Controls
import HomeOS

// Pill switch like Day | Week | Month.
Rectangle {
    id: seg
    property var options: []
    property int currentIndex: 0
    signal selected(int index)

    implicitWidth: row.implicitWidth + 12
    implicitHeight: 60
    radius: height / 2
    color: Theme.sunken

    Rectangle {
        id: thumb
        y: 6
        height: parent.height - 12
        radius: height / 2
        color: Theme.accent
        // Depend on row.width/count so this re-evaluates once the items exist.
        readonly property Item target: repeater.count > 0 && row.width > 0 ? repeater.itemAt(seg.currentIndex) : null
        x: row.x + (target ? target.x : 0)
        width: target ? target.width : 0
        Behavior on x { NumberAnimation { duration: Theme.quick; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: Theme.quick; easing.type: Easing.OutCubic } }
    }

    Row {
        id: row
        x: 6
        anchors.verticalCenter: parent.verticalCenter
        Repeater {
            id: repeater
            model: seg.options
            delegate: Item {
                required property string modelData
                required property int index
                width: label.implicitWidth + 48
                height: seg.height - 12
                Label {
                    id: label
                    anchors.centerIn: parent
                    text: modelData
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    color: index === seg.currentIndex ? Theme.accentInk : Theme.text
                }
                TapHandler { onTapped: { seg.currentIndex = index; seg.selected(index) } }
            }
        }
    }
}
