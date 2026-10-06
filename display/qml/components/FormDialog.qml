import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

// Touch-first modal shell for wall create / confirm forms.
Dialog {
    id: dialog
    property alias titleText: titleLabel.text
    property alias canSubmit: submitButton.enabled
    property string submitText: qsTr("Add")
    default property alias body: bodyColumn.data
    signal submitted()

    anchors.centerIn: Overlay.overlay
    modal: true
    width: Math.min(Overlay.overlay ? Overlay.overlay.width - 48 : 860, 860)
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
        ColumnLayout {
            id: bodyColumn
            Layout.fillWidth: true
            spacing: 16
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
    }

    onClosed: Qt.inputMethod.hide()
}
