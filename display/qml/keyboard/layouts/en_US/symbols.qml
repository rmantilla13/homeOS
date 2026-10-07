import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

// The .?123 page and, behind its #+= key, the second symbols page, with the
// same widths as the letters (see main.qml). ABC goes back to the letters.
KeyboardLayoutLoader {
    property bool secondPage
    onVisibleChanged: if (!visible) secondPage = false
    sourceComponent: secondPage ? page2 : page1

    Component {
        id: page1
        KeyboardLayout {
            readonly property real unit: width / 11.4
            KeyboardRow {
                Key { text: "1"; weight: unit; Layout.fillWidth: false }
                Key { text: "2"; weight: unit; Layout.fillWidth: false }
                Key { text: "3"; weight: unit; Layout.fillWidth: false }
                Key { text: "4"; weight: unit; Layout.fillWidth: false }
                Key { text: "5"; weight: unit; Layout.fillWidth: false }
                Key { text: "6"; weight: unit; Layout.fillWidth: false }
                Key { text: "7"; weight: unit; Layout.fillWidth: false }
                Key { text: "8"; weight: unit; Layout.fillWidth: false }
                Key { text: "9"; weight: unit; Layout.fillWidth: false }
                Key { text: "0"; weight: unit; Layout.fillWidth: false }
                BackspaceKey { weight: unit }
            }
            KeyboardRow {
                FillerKey { weight: unit / 2; Layout.fillWidth: false }
                Key { text: "@"; weight: unit; Layout.fillWidth: false }
                Key { text: "#"; weight: unit; Layout.fillWidth: false }
                Key { text: "$"; weight: unit; Layout.fillWidth: false }
                Key { text: "&"; weight: unit; Layout.fillWidth: false }
                Key { text: "*"; weight: unit; Layout.fillWidth: false }
                Key { text: "("; weight: unit; Layout.fillWidth: false }
                Key { text: ")"; weight: unit; Layout.fillWidth: false }
                Key { text: "'"; weight: unit; Layout.fillWidth: false }
                Key { text: "\""; weight: unit; Layout.fillWidth: false }
                EnterKey { weight: unit }
            }
            KeyboardRow {
                Key { displayText: "#+="; functionKey: true; highlighted: true; weight: unit; Layout.fillWidth: false; onClicked: secondPage = true }
                Key { text: "%"; weight: unit; Layout.fillWidth: false }
                Key { text: "-"; weight: unit; Layout.fillWidth: false }
                Key { text: "+"; weight: unit; Layout.fillWidth: false }
                Key { text: "="; weight: unit; Layout.fillWidth: false }
                Key { text: "/"; weight: unit; Layout.fillWidth: false }
                Key { text: ";"; weight: unit; Layout.fillWidth: false }
                Key { text: ":"; weight: unit; Layout.fillWidth: false }
                Key { text: "!"; weight: unit; Layout.fillWidth: false }
                Key { text: "?"; weight: unit; Layout.fillWidth: false }
                Key { displayText: "#+="; functionKey: true; highlighted: true; weight: unit; onClicked: secondPage = true }
            }
            KeyboardRow {
                SymbolModeKey { displayText: "ABC"; weight: unit * 1.9; Layout.fillWidth: false }
                SpaceKey { weight: unit }
                SymbolModeKey { displayText: "ABC"; weight: unit * 1.4; Layout.fillWidth: false }
                HideKeyboardKey { visible: true; weight: unit * 1.4; Layout.fillWidth: false }
            }
        }
    }

    Component {
        id: page2
        KeyboardLayout {
            readonly property real unit: width / 11.4
            KeyboardRow {
                Key { text: "["; weight: unit; Layout.fillWidth: false }
                Key { text: "]"; weight: unit; Layout.fillWidth: false }
                Key { text: "{"; weight: unit; Layout.fillWidth: false }
                Key { text: "}"; weight: unit; Layout.fillWidth: false }
                Key { text: "#"; weight: unit; Layout.fillWidth: false }
                Key { text: "%"; weight: unit; Layout.fillWidth: false }
                Key { text: "^"; weight: unit; Layout.fillWidth: false }
                Key { text: "*"; weight: unit; Layout.fillWidth: false }
                Key { text: "+"; weight: unit; Layout.fillWidth: false }
                Key { text: "="; weight: unit; Layout.fillWidth: false }
                BackspaceKey { weight: unit }
            }
            KeyboardRow {
                FillerKey { weight: unit / 2; Layout.fillWidth: false }
                Key { text: "_"; weight: unit; Layout.fillWidth: false }
                Key { text: "\\"; weight: unit; Layout.fillWidth: false }
                Key { text: "|"; weight: unit; Layout.fillWidth: false }
                Key { text: "~"; weight: unit; Layout.fillWidth: false }
                Key { text: "<"; weight: unit; Layout.fillWidth: false }
                Key { text: ">"; weight: unit; Layout.fillWidth: false }
                Key { text: "€"; weight: unit; Layout.fillWidth: false }
                Key { text: "£"; weight: unit; Layout.fillWidth: false }
                Key { text: "¥"; weight: unit; Layout.fillWidth: false }
                EnterKey { weight: unit }
            }
            KeyboardRow {
                Key { displayText: "123"; functionKey: true; highlighted: true; weight: unit; Layout.fillWidth: false; onClicked: secondPage = false }
                Key { text: "•"; weight: unit; Layout.fillWidth: false }
                Key { text: "°"; weight: unit; Layout.fillWidth: false }
                Key { text: "…"; weight: unit; Layout.fillWidth: false }
                Key { text: "½"; weight: unit; Layout.fillWidth: false }
                Key { text: "¢"; weight: unit; Layout.fillWidth: false }
                Key { text: "§"; weight: unit; Layout.fillWidth: false }
                Key { text: "©"; weight: unit; Layout.fillWidth: false }
                Key { text: "«"; weight: unit; Layout.fillWidth: false }
                Key { text: "»"; weight: unit; Layout.fillWidth: false }
                Key { displayText: "123"; functionKey: true; highlighted: true; weight: unit; onClicked: secondPage = false }
            }
            KeyboardRow {
                SymbolModeKey { displayText: "ABC"; weight: unit * 1.9; Layout.fillWidth: false }
                SpaceKey { weight: unit }
                SymbolModeKey { displayText: "ABC"; weight: unit * 1.4; Layout.fillWidth: false }
                HideKeyboardKey { visible: true; weight: unit * 1.4; Layout.fillWidth: false }
            }
        }
    }
}
