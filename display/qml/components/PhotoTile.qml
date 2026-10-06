import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import HomeOS

// A photo (or a video's poster) with rounded corners, falling back to a
// gradient in the item's own colors while loading or when there's no image.
Rectangle {
    id: tile
    property var photo: null
    property bool showCaption: true
    property int fillMode: Image.PreserveAspectCrop
    readonly property string source: photo ? (photo.imageUrl || (photo.kind === "video" ? "" : photo.url) || "") : ""

    color: photo && photo.tint ? photo.tint : Theme.surfaceAlt
    gradient: photo && !image.visible ? placeholder : null

    Gradient {
        id: placeholder
        GradientStop { position: 0; color: tile.photo && tile.photo.color ? tile.photo.color : Theme.accent }
        GradientStop { position: 1; color: tile.photo && tile.photo.color2 ? tile.photo.color2 : (tile.photo && tile.photo.tintDeep ? tile.photo.tintDeep : Theme.surfaceAlt) }
    }

    Image {
        id: image
        anchors.fill: parent
        source: tile.source
        visible: status === Image.Ready
        fillMode: tile.fillMode
        asynchronous: true
        sourceSize.width: 1920
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
    }

    // Clip to the rounded shape (a plain clip would cut square corners).
    layer.enabled: radius > 0
    layer.effect: OpacityMask {
        maskSource: Rectangle { width: tile.width; height: tile.height; radius: tile.radius }
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
