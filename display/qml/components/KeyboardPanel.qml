import QtQuick
import QtQuick.VirtualKeyboard

// On-screen keyboard for the device (no physical keyboard). Loaded at runtime by
// Main.qml so the app still starts where the virtual keyboard isn't installed.
Item {
    InputPanel {
        id: panel
        width: parent.width
        y: Qt.inputMethod.visible ? parent.height - height : parent.height
        Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }
}
