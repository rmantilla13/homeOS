import QtQuick
import QtQuick.Shapes
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Styles
import HomeOS

// The on-screen keyboard's look, after the iPad's: white letter keys and grey
// function keys on a light grey tray, or the dark version while the Theme is
// dark. A pressed letter turns grey and a pressed function key white; there is
// no preview bubble. Built in at QtQuick/VirtualKeyboard/Styles/homeos/ (see
// CMakeLists.txt) and picked by components/KeyboardPanel.qml. The key rows are
// in layouts/en_US/; docs/PI_SETUP.md has how to change either.
KeyboardStyle {
    id: look

    property color trayColor: Theme.dark ? "#2B2B2D" : "#D1D3D9"
    property color letterColor: Theme.dark ? "#6B6B6E" : "#FFFFFF"
    property color functionColor: Theme.dark ? "#464648" : "#ACB3BE"
    property color shadowColor: Theme.dark ? "#1C1C1E" : "#898A8D"
    property color inkColor: Theme.dark ? "#FFFFFF" : "#000000"
    Behavior on trayColor { ColorAnimation { duration: Theme.moodFade } }
    Behavior on letterColor { ColorAnimation { duration: Theme.moodFade } }
    Behavior on functionColor { ColorAnimation { duration: Theme.moodFade } }
    Behavior on shadowColor { ColorAnimation { duration: Theme.moodFade } }
    Behavior on inkColor { ColorAnimation { duration: Theme.moodFade } }

    // Half the gap between two keys (each key draws inside its cell).
    readonly property real keyGap: Math.round(6 * scaleHint)
    readonly property real keyRadius: Math.round(7 * scaleHint)
    readonly property real letterSize: Math.round(Theme.fontLg * scaleHint)
    readonly property real wordSize: Math.round(Theme.fontSm * scaleHint)
    readonly property real glyphSize: Math.round(34 * scaleHint)

    function faceColor(functionKey, pressed) {
        return functionKey !== pressed ? functionColor : letterColor
    }

    // About 310 px tall on the 1280 px wide panel (Qt's own style is 400).
    keyboardDesignWidth: 1280
    keyboardDesignHeight: 310
    keyboardRelativeLeftMargin: 4 / keyboardDesignWidth
    keyboardRelativeRightMargin: 4 / keyboardDesignWidth
    keyboardRelativeTopMargin: 6 / keyboardDesignHeight
    keyboardRelativeBottomMargin: 6 / keyboardDesignHeight

    // A key's face over a 1 px darker edge.
    component Cap: Item {
        id: cap
        property color face
        property color edge
        property real radius
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: cap.radius
            color: cap.edge
        }
        Rectangle {
            anchors.fill: parent
            radius: cap.radius
            color: cap.face
        }
    }

    // A key symbol drawn on a 24×24 grid, like components/Icon.qml.
    component Glyph: Item {
        id: glyph
        property string path
        property color color
        property bool filled: false
        property real size: 24
        implicitWidth: size
        implicitHeight: size
        layer.enabled: true
        layer.samples: 4
        // The fill is a shape of its own that shows or hides: Qt 6.8 doesn't
        // redraw a path whose fill turns from transparent to a color.
        Shape {
            width: 24
            height: 24
            scale: glyph.size / 24
            transformOrigin: Item.TopLeft
            visible: glyph.filled
            ShapePath {
                strokeWidth: -1
                fillColor: glyph.color
                PathSvg { path: glyph.path }
            }
        }
        Shape {
            width: 24
            height: 24
            scale: glyph.size / 24
            transformOrigin: Item.TopLeft
            ShapePath {
                strokeColor: glyph.color
                strokeWidth: 1.6
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: glyph.path }
            }
        }
    }

    readonly property var glyphs: ({
        "delete":   "M8.6 5.5H19a1.5 1.5 0 0 1 1.5 1.5v10a1.5 1.5 0 0 1-1.5 1.5H8.6a1.5 1.5 0 0 1-1.15-.54L2.8 12l4.65-5.96A1.5 1.5 0 0 1 8.6 5.5z M11.5 9.5l5 5 M16.5 9.5l-5 5",
        "shift":    "M12 3.8 3.6 12.4h4.6v6.8h7.6v-6.8h4.6z",
        "capslock": "M12 3.8 3.6 11.9h4.6v4.1h7.6v-4.1h4.6z M8.2 19.4h7.6",
        "hide":     "M3.2 3.5h17.6a1.2 1.2 0 0 1 1.2 1.2v9.6a1.2 1.2 0 0 1-1.2 1.2H3.2A1.2 1.2 0 0 1 2 14.3V4.7a1.2 1.2 0 0 1 1.2-1.2z M5.5 6.8h1 M8.75 6.8h1 M12 6.8h1 M15.25 6.8h1 M18.5 6.8h1 M5.5 9.6h1 M8.75 9.6h1 M12 9.6h1 M15.25 9.6h1 M18.5 9.6h1 M7.5 12.4h9 M9.5 18.6l2.5 2.2 2.5-2.2"
    })

    keyboardBackground: Rectangle {
        color: look.trayColor
    }

    // Letters, digits, symbols, and the #+= / 123 page keys (highlighted).
    keyPanel: KeyPanel {
        Cap {
            id: keyCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(control.highlighted, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Text {
            anchors.fill: keyCap
            text: control.displayText
            color: look.inkColor
            opacity: control.enabled ? 1 : 0.3
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: Theme.fontFamily
            font.pixelSize: control.displayText.length > 1 ? look.wordSize : look.letterSize
            // Lowercase caps unless shifted, as on the iPad.
            font.capitalization: control.uppercased ? Font.AllUppercase : Font.MixedCase
        }
    }

    backspaceKeyPanel: KeyPanel {
        Cap {
            id: backspaceCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(true, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Glyph {
            anchors.centerIn: backspaceCap
            size: look.glyphSize
            path: look.glyphs["delete"]
            color: look.inkColor
        }
    }

    // "return", or what the field asks for (go, search, done…) in the accent.
    enterKeyPanel: KeyPanel {
        id: enterPanel
        readonly property bool action: control.actionId !== EnterKeyAction.None && !control.pressed
        readonly property string label: {
            if (control.displayText.length > 0)
                return control.displayText
            switch (control.actionId) {
            case EnterKeyAction.Go: return qsTr("go")
            case EnterKeyAction.Search: return qsTr("search")
            case EnterKeyAction.Send: return qsTr("send")
            case EnterKeyAction.Next: return qsTr("next")
            case EnterKeyAction.Done: return qsTr("done")
            default: return qsTr("return")
            }
        }
        Cap {
            id: enterCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: enterPanel.action ? Theme.accent : look.faceColor(true, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Text {
            anchors.fill: enterCap
            text: enterPanel.label
            color: enterPanel.action ? Theme.accentInk : look.inkColor
            opacity: control.enabled ? 1 : 0.3
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            font.family: Theme.fontFamily
            font.pixelSize: look.wordSize
        }
    }

    hideKeyPanel: KeyPanel {
        Cap {
            id: hideCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(true, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Glyph {
            anchors.centerIn: hideCap
            size: look.glyphSize
            path: look.glyphs["hide"]
            color: look.inkColor
        }
    }

    // Tap for one capital, tap twice for caps lock. Lit like a letter key while on.
    shiftKeyPanel: KeyPanel {
        readonly property bool shifted: InputContext.shiftActive || InputContext.capsLockActive
        Cap {
            id: shiftCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(!parent.shifted, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Glyph {
            anchors.centerIn: shiftCap
            size: look.glyphSize
            path: InputContext.capsLockActive ? look.glyphs["capslock"] : look.glyphs["shift"]
            filled: parent.shifted
            color: look.inkColor
            opacity: control.enabled ? 1 : 0.3
        }
    }

    spaceKeyPanel: KeyPanel {
        Cap {
            id: spaceCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(false, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Text {
            anchors.centerIn: spaceCap
            text: qsTr("space")
            color: look.inkColor
            font.family: Theme.fontFamily
            font.pixelSize: look.wordSize
        }
    }

    // .?123, ABC
    symbolKeyPanel: KeyPanel {
        Cap {
            id: symbolCap
            anchors.fill: parent
            anchors.margins: look.keyGap
            face: look.faceColor(true, control.pressed)
            edge: look.shadowColor
            radius: look.keyRadius
        }
        Text {
            anchors.fill: symbolCap
            text: control.displayText
            color: look.inkColor
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: Theme.fontFamily
            font.pixelSize: look.wordSize
        }
    }

    // Hold a letter for its accents: a white strip above it, the choice in the accent.
    alternateKeysListItemWidth: Math.round(72 * scaleHint)
    alternateKeysListItemHeight: Math.round(64 * scaleHint)
    alternateKeysListBottomMargin: Math.round(10 * scaleHint)
    alternateKeysListDelegate: Item {
        id: alternateItem
        width: look.alternateKeysListItemWidth
        height: look.alternateKeysListItemHeight
        Text {
            anchors.centerIn: parent
            text: model.text
            color: alternateItem.ListView.isCurrentItem ? Theme.accentInk : look.inkColor
            font.family: Theme.fontFamily
            font.pixelSize: look.letterSize
        }
    }
    alternateKeysListHighlight: Rectangle {
        color: Theme.accent
        radius: look.keyRadius
    }
    alternateKeysListBackground: Item {
        Rectangle {
            readonly property real margin: Math.round(8 * look.scaleHint)
            x: -margin
            y: -margin
            width: parent.width + 2 * margin
            height: parent.height + 2 * margin
            radius: look.keyRadius + margin
            color: look.letterColor
            border.width: 1
            border.color: look.shadowColor
        }
    }

    // Word suggestions (only when a field allows prediction and a dictionary is installed).
    selectionListHeight: Math.round(56 * scaleHint)
    selectionListDelegate: SelectionListItem {
        id: selectionItem
        width: Math.round(selectionLabel.width + selectionLabel.anchors.leftMargin * 2)
        Text {
            id: selectionLabel
            anchors.left: parent.left
            anchors.leftMargin: Math.round(24 * look.scaleHint)
            anchors.verticalCenter: parent.verticalCenter
            text: display
            color: look.inkColor
            font.family: Theme.fontFamily
            font.pixelSize: look.wordSize
            font.weight: selectionItem.ListView.isCurrentItem ? Font.DemiBold : Font.Normal
        }
    }
    selectionListBackground: Rectangle {
        color: look.trayColor
    }
    selectionListAdd: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.quick }
    }
    selectionListRemove: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: Theme.quick }
    }

    navigationHighlight: Rectangle {
        color: "transparent"
        radius: look.keyRadius
        border.color: Theme.accent
        border.width: 3
    }

    selectionHandle: Rectangle {
        width: 20
        height: 20
        radius: 10
        color: Theme.accent
    }
}
