import QtQuick
import QtQuick.Controls
import HomeOS
import HomeOS.Core

// Ambient mode when nobody is using the screen: cross-fading family photos with
// the time and what's next. Any touch wakes the screen (see DisplayController).
Rectangle {
    id: frame
    color: "black"

    property int index: 0
    property bool showA: true
    property date now: new Date()
    readonly property var nextEvent: Store.events.find(e => e.startMs > now.getTime() && !e.all_day)

    function photoAt(i) { return Store.photos.length ? Store.photos[i % Store.photos.length] : null }

    Timer {
        interval: 10000
        running: frame.visible && Store.photos.length > 1
        repeat: true
        onTriggered: {
            frame.index++
            if (frame.showA) b.photo = frame.photoAt(frame.index)
            else a.photo = frame.photoAt(frame.index)
            frame.showA = !frame.showA
        }
    }
    Timer { interval: 1000; running: frame.visible; repeat: true; onTriggered: frame.now = new Date() }

    onVisibleChanged: if (visible) { a.photo = photoAt(index); showA = true }

    PhotoTile {
        id: a
        anchors.fill: parent
        showCaption: false
        color: "black"
        opacity: frame.showA ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 1500 } }
    }
    PhotoTile {
        id: b
        anchors.fill: parent
        showCaption: false
        color: "black"
        opacity: frame.showA ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 1500 } }
    }

    // Shade in the photo's own deep color so the clock stays legible and the
    // overlay feels part of the picture.
    readonly property var shown: showA ? a.photo : b.photo
    property color shade: shown && shown.tintDeep ? shown.tintDeep : "#000000"
    Behavior on shade { ColorAnimation { duration: 1500 } }
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 420
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(frame.shade.r, frame.shade.g, frame.shade.b, 0.85) }
        }
    }

    Column {
        anchors { left: parent.left; bottom: parent.bottom; margins: 64 }
        spacing: 8
        Label {
            text: Qt.formatTime(frame.now, "h:mm")
            color: "white"
            font.pixelSize: 140
            font.weight: Font.Light
        }
        Label {
            text: Qt.formatDate(frame.now, "dddd, MMMM d")
            color: "white"
            font.pixelSize: Theme.fontLg
        }
        Label {
            visible: frame.nextEvent !== undefined
            text: frame.nextEvent ? qsTr("Next: %1 · %2").arg(frame.nextEvent.title).arg(frame.nextEvent.timeLabel.split(" – ")[0]) : ""
            color: "#DDFFFFFF"
            font.pixelSize: Theme.fontMd
        }
    }

    Label {
        anchors { right: parent.right; bottom: parent.bottom; margins: 64 }
        text: { const p = frame.showA ? a.photo : b.photo; return p && p.caption ? p.caption : "" }
        color: "#CCFFFFFF"
        font.pixelSize: Theme.fontSm
    }
}
