import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components
import QtQuick.VirtualKeyboard.Plugins

// Dial pad for phone numbers (Qt.ImhDialableCharactersOnly).
KeyboardLayout {
    inputMethod: PlainInputMethod {}
    inputMode: InputEngine.InputMode.Numeric

    KeyboardColumn {
        Layout.fillWidth: false
        Layout.fillHeight: true
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: height * 1.7
        KeyboardRow {
            Key { text: "1" }
            Key { text: "2" }
            Key { text: "3" }
            BackspaceKey {}
        }
        KeyboardRow {
            Key { text: "4" }
            Key { text: "5" }
            Key { text: "6" }
            EnterKey {}
        }
        KeyboardRow {
            Key { text: "7" }
            Key { text: "8" }
            Key { text: "9" }
            HideKeyboardKey { visible: true }
        }
        KeyboardRow {
            Key { text: "*" }
            Key { text: "0" }
            Key { text: "#" }
            Key { text: "+" }
        }
    }
}
