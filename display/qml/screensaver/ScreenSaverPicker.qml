import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Choose what the screen shows when nobody is using it.
Dialog {
    id: picker
    modal: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent ? parent.width - 80 : 900, 900)
    padding: 32
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.smooth }
            NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: Theme.smooth; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.smooth } }

    background: Rectangle { radius: 32; color: Theme.surface }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }

    // Like every dialog and sheet, it closes when the display goes idle.
    Connections {
        target: Device
        function onIdleChanged() {
            if (Device.idle)
                picker.close()
        }
    }

    contentItem: ColumnLayout {
        spacing: 24
        RowLayout {
            Layout.fillWidth: true
            Column {
                Layout.fillWidth: true
                Label { text: qsTr("Screen saver"); color: Theme.text; font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                Label { text: qsTr("Shown after %1 minutes without a touch").arg(Math.round(Device.idleTimeoutSec / 60)); color: Theme.textMuted; font.pixelSize: Theme.fontSm }
            }
            IconButton { icon: "close"; fill: Theme.surfaceAlt; onClicked: picker.close() }
        }

        ScreenSaverOptions { Layout.fillWidth: true }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 12
            PillButton { text: qsTr("Done"); fill: Theme.surfaceAlt; ink: Theme.text; onClicked: picker.close() }
            PillButton {
                text: qsTr("Preview")
                onClicked: { picker.close(); Device.sleepNow() }
            }
        }
    }
}
