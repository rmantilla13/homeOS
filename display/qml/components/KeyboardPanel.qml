import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Settings
import HomeOS

// On-screen keyboard for the device (no physical keyboard). Loaded at runtime by
// Main.qml so the app still starts where the virtual keyboard isn't installed.
//
// It sits in a Layer above the dialogs, so it can be typed on while a modal
// one is open. Its look is keyboard/style.qml and its keys are
// keyboard/layouts/en_US/ (see docs/PI_SETUP.md).
Item {
    id: root
    // Height the keyboard currently covers, so screens can keep inputs above it.
    readonly property real visibleHeight: Qt.inputMethod.visible ? panel.height : 0

    Component.onCompleted: {
        VirtualKeyboardSettings.styleName = "homeos"
        VirtualKeyboardSettings.layoutPath = Qt.resolvedUrl("../keyboard/layouts")
        VirtualKeyboardSettings.locale = "en_US"
        VirtualKeyboardSettings.activeLocales = ["en_US"]
        tray.open()
    }

    Layer {
        id: tray
        z: 2 // over the dialogs, under the toast (see Main.qml)
        width: root.width
        height: panel.height
        // Parked below the window while hidden, so it never takes a tap
        // meant for what's underneath.
        y: Qt.inputMethod.visible ? root.height - height : root.height
        Behavior on y { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

        // Window-sized and at the window's origin: the panel places its text
        // selection handles relative to its parent.
        Item {
            y: -tray.y
            width: root.width
            height: root.height
            InputPanel {
                id: panel
                y: tray.y
                width: parent.width
            }
        }
    }
}
