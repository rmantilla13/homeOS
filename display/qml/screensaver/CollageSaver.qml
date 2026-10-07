import QtQuick
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// A mosaic of family photos, each cropped to fill its tile. The screen saver
// gives it the next layout each time it starts (classic, grid, mosaic, trio,
// columns); with fewer photos than tiles it takes a smaller one, so no tile
// is empty or shows a photo twice. Portrait photos go to tall tiles where
// there's a choice. Every few seconds one tile cross-fades to a photo that
// isn't showing and hasn't been for a minute, so photos don't hop between
// tiles.
Item {
    id: collage
    property string layoutName: "classic"
    property int interval: 4000
    property int restMs: 60000
    readonly property var shown: slots.length ? slots[0].current : null

    readonly property real gap: 12
    property var layout: null
    property var slots: []
    // Key -> when the photo left the screen (ms).
    property var seen: ({})
    property int lastTile: -1

    function keys() { return slots.map(s => Picks.keyOf(s.current)) }
    function aspectOf(index) {
        // Before the first layout pass the size can still be 0: assume the panel.
        return Picks.tileAspect(layout, layout.tiles[index], width > 0 ? width : 1280, height > 0 ? height : 800, gap)
    }

    // Lays the tiles out for the photos there are and fills each one.
    function fill() {
        for (const s of slots)
            s.destroy()
        const photos = Store.photos
        layout = Picks.layout(layoutName, photos.length)
        lastTile = -1
        const made = []
        const now = Date.now()
        for (let i = 0; layout && i < layout.tiles.length; ++i) {
            const photo = Picks.pick(photos, aspectOf(i), made.map(s => Picks.keyOf(s.current)), seen, now, restMs)
            const s = tile.createObject(collage, { spec: layout.tiles[i] })
            s.swap(photo)
            made.push(s)
        }
        slots = made
    }

    // One tile takes a photo that isn't showing; nothing changes when no
    // photo may go there yet.
    function step() {
        if (!layout || !slots.length)
            return
        const i = Picks.chooseTile(layout.tiles, lastTile, Math.random())
        const now = Date.now()
        const photo = Picks.pick(Store.photos, aspectOf(i), keys(), seen, now, restMs)
        if (!photo)
            return
        const leaving = Picks.keyOf(slots[i].current)
        if (leaving)
            seen[leaving] = now
        slots[i].swap(photo)
        lastTile = i
    }

    // New or deleted photos: lay out again when the count calls for another
    // layout, else replace only photos that are gone. A URL signed again
    // keeps the photo (and its loaded image) where it is.
    function refresh() {
        const photos = Store.photos
        const wanted = Picks.layout(layoutName, photos.length)
        if (!wanted || !layout || wanted.name !== layout.name) {
            fill()
            return
        }
        const present = photos.map(p => Picks.keyOf(p))
        const now = Date.now()
        for (let i = 0; i < slots.length; ++i) {
            if (present.indexOf(Picks.keyOf(slots[i].current)) >= 0)
                continue
            const photo = Picks.pick(photos, aspectOf(i), keys(), seen, now, 0)
            if (photo)
                slots[i].swap(photo)
        }
    }

    // After the screen saver has set layoutName.
    Component.onCompleted: Qt.callLater(fill)
    Connections {
        target: Store
        function onMediaChanged() { collage.refresh() }
    }

    Timer {
        objectName: "collageTimer"
        interval: collage.interval
        running: collage.slots.length > 0 && Store.photos.length > collage.slots.length
        repeat: true
        onTriggered: collage.step()
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
            // A layout replaced meanwhile (this tile is about to go) still has a size.
            readonly property int cols: collage.layout ? collage.layout.cols : 1
            readonly property int rows: collage.layout ? collage.layout.rows : 1
            readonly property real cellW: (collage.width - collage.gap * (cols + 1)) / cols
            readonly property real cellH: (collage.height - collage.gap * (rows + 1)) / rows
            x: collage.gap + spec.c * (cellW + collage.gap)
            y: collage.gap + spec.r * (cellH + collage.gap)
            width: spec.w * cellW + (spec.w - 1) * collage.gap
            height: spec.h * cellH + (spec.h - 1) * collage.gap

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
