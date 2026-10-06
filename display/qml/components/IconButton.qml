import QtQuick
import HomeOS

// Round icon button (prev/next, close, mic, send).
Rectangle {
    id: btn
    property string icon: ""
    property color fill: Theme.surface
    property color ink: Theme.text
    property real iconSize: 24
    signal clicked()

    implicitWidth: Theme.touchTarget
    implicitHeight: Theme.touchTarget
    radius: width / 2
    color: fill
    opacity: enabled ? 1 : 0.4
    scale: tap.pressed ? 0.94 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }

    Icon {
        anchors.centerIn: parent
        name: btn.icon
        size: btn.iconSize
        color: btn.ink
    }
    TapHandler { id: tap; onTapped: btn.clicked() }
}
