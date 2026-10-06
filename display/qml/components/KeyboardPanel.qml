import QtQuick
import QtQuick.VirtualKeyboard

// On-screen keyboard for the device (no physical keyboard). Loaded at runtime by
// Main.qml so the app still starts where the virtual keyboard isn't installed.
Item {
    // Height the keyboard currently covers, so screens can keep inputs above it.
    readonly property real visibleHeight: Qt.inputMethod.visible ? panel.height : 0

    InputPanel {
        id: panel
        width: parent.width
        y: Qt.inputMethod.visible ? parent.height - height : parent.height
        Behavior on y { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    }
}
