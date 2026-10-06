import QtQuick
import QtQuick.Controls
import HomeOS

// Colored circle with the member's initial (photo avatars come with M3).
Rectangle {
    property var member: ({})
    property int size: 64
    property bool selected: false

    width: size
    height: size
    radius: size / 2
    color: member.color || Theme.accent
    border.width: selected ? 5 : 0
    border.color: Theme.text

    Label {
        anchors.centerIn: parent
        text: member.initial || ""
        color: "white"
        font.pixelSize: parent.size * 0.45
        font.weight: Font.Bold
    }
}
