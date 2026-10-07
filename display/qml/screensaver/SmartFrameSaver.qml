import QtQuick
import Qt5Compat.GraphicalEffects
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// One photo at a time like Photos, but two portrait photos share the screen
// side by side instead of one being cropped to the screen's shape. A
// portrait photo left without a partner stands whole over a blurred copy of
// itself. Landscape photos fill the screen.
Item {
    id: frame
    property int interval: 10000
    readonly property real gap: 12
    readonly property var frames: Picks.frames(Store.photos)
    property int index: 0
    property bool showA: true
    readonly property var shown: {
        const photos = showA ? a.photos : b.photos
        return photos.length ? photos[0] : null
    }

    function frameAt(i) { return frames.length ? frames[i % frames.length] : [] }

    Component.onCompleted: { a.photos = frameAt(0); a.drift.restart() }
    // Photos that arrive after an empty start.
    onFramesChanged: {
        const page = showA ? a : b
        if (!page.photos.length && frames.length) {
            page.photos = frameAt(index)
            page.drift.restart()
        }
    }

    Timer {
        interval: frame.interval
        running: frame.frames.length > 1
        repeat: true
        onTriggered: {
            frame.index++
            const next = frame.showA ? b : a
            next.photos = frame.frameAt(frame.index)
            next.drift.restart()
            frame.showA = !frame.showA
        }
    }

    component Page: Item {
        id: page
        property var photos: []
        property alias drift: driftAnim
        readonly property bool pair: photos.length === 2
        readonly property var single: photos.length === 1 ? photos[0] : null
        readonly property bool lonePortrait: single !== null && Picks.photoShape(single) === -1
        anchors.fill: parent
        Behavior on opacity { NumberAnimation { duration: 1600; easing.type: Easing.InOutQuad } }

        Item {
            id: stage
            anchors.fill: parent

            // A landscape photo, edge to edge, slowly zooming. Pairs and lone
            // portraits keep still: a zoom would cut their margins.
            PhotoTile {
                id: wide
                anchors.fill: parent
                visible: page.single !== null && !page.lonePortrait
                photo: visible ? page.single : null
                radius: 0
                showCaption: false
                color: "black"
                NumberAnimation {
                    id: driftAnim
                    target: wide
                    property: "scale"
                    from: 1.0
                    to: 1.08
                    duration: frame.interval + 1600
                    easing.type: Easing.InOutSine
                }
            }

            // A portrait photo on its own: whole, over a blurred copy.
            Image {
                id: backdrop
                anchors.fill: parent
                visible: false
                source: page.lonePortrait ? (page.single.tileUrl || page.single.imageUrl || "") : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                autoTransform: true
                sourceSize.width: 480
            }
            FastBlur {
                anchors.fill: parent
                source: backdrop
                radius: 64
                cached: true
                visible: page.lonePortrait && backdrop.status === Image.Ready
            }
            Rectangle { anchors.fill: parent; visible: page.lonePortrait; color: Qt.rgba(0, 0, 0, 0.3) }
            PhotoTile {
                visible: page.lonePortrait
                photo: visible ? page.single : null
                anchors.centerIn: parent
                height: parent.height - frame.gap * 4
                width: Math.min(parent.width - frame.gap * 4, height * (page.single && page.single.aspect > 0 ? page.single.aspect : 0.75))
                radius: 22
                showCaption: false
            }

            // Two portrait photos side by side.
            Row {
                anchors.fill: parent
                anchors.margins: frame.gap
                spacing: frame.gap
                visible: page.pair
                Repeater {
                    model: page.pair ? page.photos : []
                    delegate: PhotoTile {
                        required property var modelData
                        photo: modelData
                        width: (frame.width - frame.gap * 3) / 2
                        height: frame.height - frame.gap * 2
                        radius: 22
                        showCaption: false
                    }
                }
            }
        }
    }

    Page { id: a; opacity: frame.showA ? 1 : 0 }
    Page { id: b; opacity: frame.showA ? 0 : 1 }
}
