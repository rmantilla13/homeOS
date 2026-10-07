import QtQuick
import QtQuick.Controls
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// Ambient mode when nobody is using the screen. The style (Device.screensaver)
// is photos, collage, frame (smart frame), memories (on this day), video,
// clock or today. The photo styles share the clock, date and what's next,
// over a shade in the colors of whatever is showing; clock and today draw
// their own. Any touch wakes the screen (see DisplayController).
Rectangle {
    id: saver
    color: "black"

    readonly property bool hasVideos: Store.media.some(m => m.kind === "video" && m.url)
    readonly property string style: Device.screensaver === "video" && !hasVideos ? "photos" : Device.screensaver
    readonly property var shown: content.item ? content.item.shown : null
    // Clock and Today show the time themselves.
    readonly property bool ownClock: style === "clock" || style === "today"
    // The collage takes the next layout each time the screen saver starts.
    property int collageTurn: 0
    readonly property var sources: ({
        collage: "CollageSaver.qml", video: "VideoSaver.qml", frame: "SmartFrameSaver.qml",
        memories: "MemoriesSaver.qml", clock: "ClockSaver.qml", today: "TodaySaver.qml"
    })

    property date now: new Date()
    readonly property var nextEvent: Store.events.find(e => e.startMs > now.getTime() && !e.all_day)
    Timer { interval: 1000; running: saver.visible; repeat: true; onTriggered: saver.now = new Date() }

    // Background behind the collage takes the deep color of the main photo.
    property color shade: shown && shown.tintDeep ? shown.tintDeep : "#000000"
    Behavior on shade { ColorAnimation { duration: 1500 } }
    Rectangle { anchors.fill: parent; color: saver.style === "collage" || saver.style === "frame" ? saver.shade : "black" }

    Loader {
        id: content
        objectName: "saverContent"
        anchors.fill: parent
        // Only run while visible, and rebuild when the style changes.
        active: saver.visible
        source: saver.sources[saver.style] || "SlideshowSaver.qml"
        onLoaded: {
            if (saver.style !== "collage")
                return
            item.layoutName = Picks.TURNS[saver.collageTurn % Picks.TURNS.length]
            saver.collageTurn++
        }
        opacity: status === Loader.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
    }

    // Shade so the clock stays legible and feels part of the picture.
    Rectangle {
        visible: !saver.ownClock
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 420
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(saver.shade.r, saver.shade.g, saver.shade.b, 0.85) }
        }
    }

    Column {
        visible: !saver.ownClock
        anchors { left: parent.left; bottom: parent.bottom; margins: 64 }
        spacing: 8
        Label {
            text: Qt.formatTime(saver.now, "h:mm AP").split(" ")[0] // 12-hour, like Home
            color: "white"
            font.pixelSize: 140
            font.weight: Font.Light
        }
        Label {
            text: Qt.formatDate(saver.now, "dddd, MMMM d")
            color: "white"
            font.pixelSize: Theme.fontLg
        }
        Label {
            visible: saver.nextEvent !== undefined
            text: saver.nextEvent ? qsTr("Next: %1 · %2").arg(saver.nextEvent.title).arg(saver.nextEvent.timeLabel.split(" – ")[0]) : ""
            color: "#DDFFFFFF"
            font.pixelSize: Theme.fontMd
        }
    }

    Label {
        visible: !saver.ownClock
        anchors { right: parent.right; bottom: parent.bottom; margins: 64 }
        text: saver.shown && saver.shown.caption ? saver.shown.caption : ""
        color: "#CCFFFFFF"
        font.pixelSize: Theme.fontSm
    }
}
