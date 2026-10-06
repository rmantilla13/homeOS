import QtQuick
import QtQuick.Controls
import HomeOS

// Large touch-friendly button.
AbstractButton {
    id: control
    property color fill: Theme.accent
    property color ink: "white"

    implicitHeight: Theme.touchTarget
    implicitWidth: Math.max(Theme.touchTarget * 2, label.implicitWidth + 56)
    opacity: enabled ? 1 : 0.4
    scale: pressed ? 0.96 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }

    background: Rectangle {
        radius: height / 2
        color: control.fill
    }
    contentItem: Label {
        id: label
        text: control.text
        color: control.ink
        font.pixelSize: Theme.fontSm
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
