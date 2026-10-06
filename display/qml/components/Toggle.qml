import QtQuick
import HomeOS

// On/off switch. It doesn't flip itself: it asks with toggled(), and the
// owner binds `checked` to the real setting, so it can never show a state the
// device isn't in.
Item {
    id: toggle
    property bool checked: false
    signal toggled(bool checked)

    implicitWidth: 76
    implicitHeight: 44
    opacity: enabled ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: Theme.quick } }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: toggle.checked ? Theme.accent : Qt.rgba(Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 0.32)
        Behavior on color { ColorAnimation { duration: Theme.smooth } }

        Rectangle {
            width: parent.height - 8
            height: width
            radius: width / 2
            y: 4
            x: toggle.checked ? parent.width - width - 4 : 4
            color: "white"
            border.color: Qt.rgba(0, 0, 0, 0.06)
            scale: tap.pressed ? 0.9 : 1
            Behavior on x { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
            Behavior on scale { NumberAnimation { duration: 90 } }
        }
    }

    // A finger-sized hit area around the track.
    TapHandler {
        id: tap
        target: null
        margin: 12
        gesturePolicy: TapHandler.WithinBounds
        onTapped: toggle.toggled(!toggle.checked)
    }
}
