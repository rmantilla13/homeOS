import QtQuick
import HomeOS
import HomeOS.Core

// A mosaic of family photos: one large tile and four small ones. Every few
// seconds a random tile cross-fades to a photo that isn't already showing.
Item {
    id: collage
    property int interval: 4000
    readonly property var shown: slots.length ? slots[0].current : null

    readonly property real gap: 12
    readonly property real cellW: (width - gap * 5) / 4
    readonly property real cellH: (height - gap * 3) / 2
    // Slot rectangles in a 4x2 grid; the first spans 2x2.
    readonly property var layout: [
        { c: 0, r: 0, w: 2, h: 2 },
        { c: 2, r: 0, w: 1, h: 1 }, { c: 3, r: 0, w: 1, h: 1 },
        { c: 2, r: 1, w: 1, h: 1 }, { c: 3, r: 1, w: 1, h: 1 }
    ]
    property var slots: []
    property int nextPhoto: 0

    function photoAt(i) { return Store.photos.length ? Store.photos[i % Store.photos.length] : null }
    function showing(url) { return slots.some(s => s.current && s.current.url === url) }

    Component.onCompleted: {
        const made = []
        for (let i = 0; i < layout.length; ++i) {
            const s = tile.createObject(collage, { spec: layout[i] })
            s.swap(photoAt(nextPhoto++))
            made.push(s)
        }
        slots = made
    }

    Timer {
        interval: collage.interval
        running: Store.photos.length > collage.layout.length
        repeat: true
        onTriggered: {
            // Pick a tile (the big one less often) and the next photo not on screen.
            const i = Math.random() < 0.2 ? 0 : 1 + Math.floor(Math.random() * (collage.slots.length - 1))
            let p = collage.photoAt(collage.nextPhoto++)
            for (let guard = 0; p && collage.showing(p.url) && guard < Store.photos.length; ++guard)
                p = collage.photoAt(collage.nextPhoto++)
            collage.slots[i].swap(p)
        }
    }

    Component {
        id: tile
        Item {
            id: cell
            property var spec
            property var current: null
            property bool showA: true
            // The first fill paints immediately. Later swaps keep the slow crossfade.
            property bool crossfade: false
            x: collage.gap + spec.c * (collage.cellW + collage.gap)
            y: collage.gap + spec.r * (collage.cellH + collage.gap)
            width: spec.w * collage.cellW + (spec.w - 1) * collage.gap
            height: spec.h * collage.cellH + (spec.h - 1) * collage.gap

            function swap(photo) {
                current = photo
                if (showA) b.photo = photo; else a.photo = photo
                showA = !showA
                if (crossfade)
                    pulse.restart()
                crossfade = true
            }

            PhotoTile { id: a; anchors.fill: parent; radius: 22; showCaption: false; opacity: cell.showA ? 1 : 0
                        Behavior on opacity { enabled: cell.crossfade; NumberAnimation { duration: 1200; easing.type: Easing.InOutQuad } } }
            PhotoTile { id: b; anchors.fill: parent; radius: 22; showCaption: false; opacity: cell.showA ? 0 : 1
                        Behavior on opacity { enabled: cell.crossfade; NumberAnimation { duration: 1200; easing.type: Easing.InOutQuad } } }

            // A gentle "breath" as the tile changes.
            SequentialAnimation {
                id: pulse
                NumberAnimation { target: cell; property: "scale"; to: 0.97; duration: 500; easing.type: Easing.OutQuad }
                NumberAnimation { target: cell; property: "scale"; to: 1.0; duration: 900; easing.type: Easing.OutBack }
            }
        }
    }
}
