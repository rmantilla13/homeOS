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
    Behavior on scale { NumberAnimation { duration: Theme.quick } }

    Icon {
        anchors.centerIn: parent
        name: btn.icon
        size: btn.iconSize
        color: btn.ink
    }
    // Claim the tap so handlers on items underneath (e.g. a photo that toggles
    // the viewer controls) don't also react.
    TapHandler { id: tap; gesturePolicy: TapHandler.WithinBounds; onTapped: btn.clicked() }
}
