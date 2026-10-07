import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

// Letters, laid out like the iPad's landscape keyboard. Widths are in letter
// keys (`unit`): each row is 11.4 wide and its last key takes what's left, so
// delete is 1.4, return 1.9, the right shift 1.4. The a row starts half a key
// in. Hold a letter for its accents.
KeyboardLayout {
    inputMode: InputEngine.InputMode.Latin
    readonly property real unit: width / 11.4

    KeyboardRow {
        Key { text: "q"; weight: unit; Layout.fillWidth: false }
        Key { text: "w"; weight: unit; Layout.fillWidth: false }
        Key { text: "e"; weight: unit; Layout.fillWidth: false; alternativeKeys: "êeëèé" }
        Key { text: "r"; weight: unit; Layout.fillWidth: false }
        Key { text: "t"; weight: unit; Layout.fillWidth: false }
        Key { text: "y"; weight: unit; Layout.fillWidth: false; alternativeKeys: "ÿyý" }
        Key { text: "u"; weight: unit; Layout.fillWidth: false; alternativeKeys: "ūûüuùú" }
        Key { text: "i"; weight: unit; Layout.fillWidth: false; alternativeKeys: "îïīiìí" }
        Key { text: "o"; weight: unit; Layout.fillWidth: false; alternativeKeys: "œøõôöòóo" }
        Key { text: "p"; weight: unit; Layout.fillWidth: false }
        BackspaceKey { weight: unit }
    }
    KeyboardRow {
        FillerKey { weight: unit / 2; Layout.fillWidth: false }
        Key { text: "a"; weight: unit; Layout.fillWidth: false; alternativeKeys: "aäåãâàá" }
        Key { text: "s"; weight: unit; Layout.fillWidth: false; alternativeKeys: "ßs" }
        Key { text: "d"; weight: unit; Layout.fillWidth: false }
        Key { text: "f"; weight: unit; Layout.fillWidth: false }
        Key { text: "g"; weight: unit; Layout.fillWidth: false }
        Key { text: "h"; weight: unit; Layout.fillWidth: false }
        Key { text: "j"; weight: unit; Layout.fillWidth: false }
        Key { text: "k"; weight: unit; Layout.fillWidth: false }
        Key { text: "l"; weight: unit; Layout.fillWidth: false }
        EnterKey { weight: unit }
    }
    KeyboardRow {
        ShiftKey { weight: unit; Layout.fillWidth: false }
        Key { text: "z"; weight: unit; Layout.fillWidth: false }
        Key { text: "x"; weight: unit; Layout.fillWidth: false }
        Key { text: "c"; weight: unit; Layout.fillWidth: false; alternativeKeys: "çc" }
        Key { text: "v"; weight: unit; Layout.fillWidth: false }
        Key { text: "b"; weight: unit; Layout.fillWidth: false }
        Key { text: "n"; weight: unit; Layout.fillWidth: false; alternativeKeys: "ñn" }
        Key { text: "m"; weight: unit; Layout.fillWidth: false }
        Key { text: ","; weight: unit; Layout.fillWidth: false; alternativeKeys: ",!" }
        Key { text: "."; weight: unit; Layout.fillWidth: false; alternativeKeys: ".?" }
        ShiftKey { weight: unit }
    }
    KeyboardRow {
        SymbolModeKey { displayText: ".?123"; weight: unit * 1.9; Layout.fillWidth: false }
        SpaceKey { weight: unit }
        SymbolModeKey { displayText: ".?123"; weight: unit * 1.4; Layout.fillWidth: false }
        HideKeyboardKey { visible: true; weight: unit * 1.4; Layout.fillWidth: false }
    }
}
