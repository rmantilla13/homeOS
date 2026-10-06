import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

// Rounded surface with an optional title row.
Rectangle {
    id: card
    property string title: ""
    property string actionText: ""
    signal actionClicked()
    default property alias content: body.data

    color: Theme.surface
    radius: Theme.radius

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing
        spacing: 16

        RowLayout {
            visible: card.title !== ""
            Layout.fillWidth: true
            Label {
                text: card.title
                color: Theme.text
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Label {
                visible: card.actionText !== ""
                text: card.actionText + "  ›"
                color: Theme.accent
                font.pixelSize: Theme.fontSm
                TapHandler { onTapped: card.actionClicked() }
            }
        }

        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
