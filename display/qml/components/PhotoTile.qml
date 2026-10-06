import QtQuick
import QtQuick.Controls
import HomeOS

// Shows a photo from storage, or a gradient placeholder for demo data.
Rectangle {
    id: tile
    property var photo: null
    property bool showCaption: true
    property int fillMode: Image.PreserveAspectCrop

    clip: true
    color: Theme.surfaceAlt
    gradient: photo && !photo.url ? placeholder : null

    Gradient {
        id: placeholder
        GradientStop { position: 0; color: tile.photo && tile.photo.color ? tile.photo.color : Theme.accent }
        GradientStop { position: 1; color: tile.photo && tile.photo.color2 ? tile.photo.color2 : Theme.surfaceAlt }
    }

    Image {
        anchors.fill: parent
        source: tile.photo && tile.photo.url ? tile.photo.url : ""
        fillMode: tile.fillMode
        asynchronous: true
        sourceSize.width: 1920
    }

    Label {
        visible: tile.showCaption
        anchors { left: parent.left; bottom: parent.bottom; margins: 20 }
        text: tile.photo ? (tile.photo.caption || "") : ""
        color: "white"
        font.pixelSize: Theme.fontSm
        font.weight: Font.DemiBold
        style: Text.Raised
        styleColor: "#55000000"
    }
}
