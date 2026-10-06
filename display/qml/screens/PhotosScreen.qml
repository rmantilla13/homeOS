import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Family photo wall. Tap a photo to view it full screen and swipe through.
Item {
    id: photosScreen

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            Label {
                text: qsTr("Photos")
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            PillButton {
                text: qsTr("▶  Slideshow")
                enabled: Store.photos.length > 0
                onClicked: Device.sleepNow()
            }
        }

        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: width / 4
            cellHeight: cellWidth * 0.75
            model: Store.photos
            delegate: Item {
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight
                PhotoTile {
                    anchors.fill: parent
                    anchors.margins: 8
                    radius: 18
                    photo: modelData
                    TapHandler { onTapped: { viewer.currentIndex = index; viewer.open() } }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: Store.photos.length === 0
                text: qsTr("No photos yet. Add some from the homeOS iPhone app.")
                color: Theme.textMuted
                font.pixelSize: Theme.fontMd
            }
        }
    }

    Popup {
        id: viewer
        property int currentIndex: 0
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        padding: 0
        modal: true
        background: Rectangle { color: "black" }

        SwipeView {
            id: swipe
            anchors.fill: parent
            currentIndex: viewer.currentIndex
            Repeater {
                model: viewer.opened ? Store.photos : []
                delegate: PhotoTile {
                    required property var modelData
                    photo: modelData
                    color: "black"
                    fillMode: Image.PreserveAspectFit
                }
            }
        }
        PillButton {
            anchors { top: parent.top; right: parent.right; margins: 32 }
            text: "✕"
            implicitWidth: Theme.touchTarget
            fill: "#66000000"
            onClicked: viewer.close()
        }
    }
}
