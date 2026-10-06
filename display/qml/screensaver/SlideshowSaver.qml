import QtQuick
import HomeOS
import HomeOS.Core

// Full-screen photos that cross-fade, each slowly zooming and drifting
// (the "Ken Burns" effect) so the picture never sits perfectly still.
Item {
    id: show
    property int interval: 10000
    readonly property var shown: showA ? a.photo : b.photo

    property int index: 0
    property bool showA: true
    function photoAt(i) { return Store.photos.length ? Store.photos[i % Store.photos.length] : null }

    Component.onCompleted: { a.photo = photoAt(0); a.drift.restart() }

    Timer {
        interval: show.interval
        running: Store.photos.length > 1
        repeat: true
        onTriggered: {
            show.index++
            const next = show.showA ? b : a
            next.photo = show.photoAt(show.index)
            next.drift.restart()
            show.showA = !show.showA
        }
    }

    component Slide: PhotoTile {
        id: slide
        property alias drift: driftAnim
        property int variant: 0
        anchors.fill: parent
        showCaption: false
        color: "black"
        radius: 0
        transformOrigin: [Item.TopLeft, Item.BottomRight, Item.TopRight, Item.BottomLeft][variant % 4]
        Behavior on opacity { NumberAnimation { duration: 1600; easing.type: Easing.InOutQuad } }
        NumberAnimation {
            id: driftAnim
            target: slide
            property: "scale"
            from: 1.0
            to: 1.12
            duration: show.interval + 1600
            easing.type: Easing.InOutSine
            onStarted: slide.variant++
        }
    }

    Slide { id: a; opacity: show.showA ? 1 : 0 }
    Slide { id: b; opacity: show.showA ? 0 : 1 }
}
