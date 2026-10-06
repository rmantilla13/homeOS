import QtQuick
import QtQuick.Controls
import HomeOS

// Small uppercase pill, e.g. "EMMA" or "FAMILY", tinted with a member color.
Rectangle {
    property string text: ""
    property color tint: Theme.accentSoft
    property color ink: Theme.accent

    implicitWidth: label.implicitWidth + 24
    implicitHeight: 30
    radius: height / 2
    color: tint

    Label {
        id: label
        anchors.centerIn: parent
        text: parent.text.toUpperCase()
        // Member inks are dark shades; lift them so they read on the night palette.
        color: Theme.dark ? Qt.lighter(parent.ink, 2.6) : parent.ink
        font.pixelSize: 13
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
    }
}
