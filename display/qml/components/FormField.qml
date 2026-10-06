import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

// Large text field used in wall create dialogs.
TextField {
    id: field
    Layout.fillWidth: true
    Layout.preferredHeight: Theme.touchTarget
    font.pixelSize: Theme.fontMd
    color: Theme.text
    placeholderTextColor: Theme.textMuted
    leftPadding: 24
    rightPadding: 24
    inputMethodHints: Qt.ImhNoPredictiveText
    background: Rectangle {
        radius: 18
        color: Theme.surfaceAlt
        border.width: field.activeFocus ? 2 : 0
        border.color: Theme.accent
    }
}
