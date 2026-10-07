import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Touch-first modal shell for wall create / confirm forms. While the on-screen
// keyboard is up it fits in the room above it: the body scrolls, the title and
// the buttons stay put, and the field being typed in stays in view. Like every
// dialog and sheet here, it closes when the display goes idle.
Dialog {
    id: dialog
    property alias titleText: titleLabel.text
    property alias canSubmit: submitButton.enabled
    property string submitText: qsTr("Add")
    default property alias body: bodyColumn.data
    signal submitted()

    // Height the keyboard covers (0 while it's down, or without one).
    readonly property real keyboardHeight: Qt.inputMethod.visible ? Qt.inputMethod.keyboardRectangle.height : 0
    // Free space kept above it and between it and the keyboard.
    readonly property real gap: Theme.compact ? 16 : 24
    readonly property real room: (parent ? parent.height : 800) - keyboardHeight - 2 * gap

    parent: Overlay.overlay
    modal: true
    width: Math.min(parent ? parent.width - 48 : 860, 860)
    height: Math.min(implicitHeight, room)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: Math.round(gap + (room - height) / 2)
    // Only once it's up: opening shouldn't slide it in from the top.
    Behavior on y { enabled: dialog.opened; NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: dialog.opened; NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    padding: Theme.compact ? 28 : 40
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape
    background: Rectangle { radius: Theme.radius; color: Theme.surface }

    contentItem: ColumnLayout {
        spacing: 20
        Label {
            id: titleLabel
            Layout.fillWidth: true
            color: Theme.text
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
        }
        FocusFlickable {
            id: bodyFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: bodyColumn.implicitHeight
            contentHeight: bodyColumn.implicitHeight
            ColumnLayout {
                id: bodyColumn
                width: bodyFlick.width
                spacing: 16
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            Item { Layout.fillWidth: true }
            PillButton {
                text: qsTr("Cancel")
                fill: Theme.surfaceAlt
                ink: Theme.text
                onClicked: dialog.close()
            }
            PillButton {
                id: submitButton
                text: dialog.submitText
                onClicked: dialog.submitted()
            }
        }

        Connections {
            target: Device
            function onIdleChanged() {
                if (Device.idle)
                    dialog.close()
            }
        }
    }

    onAboutToShow: bodyFlick.contentY = 0
    onClosed: Qt.inputMethod.hide()
}
