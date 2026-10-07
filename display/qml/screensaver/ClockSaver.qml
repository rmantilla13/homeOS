import QtQuick
import QtQuick.Controls
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// A big clock, the date and what's next on a soft gradient in the
// time-of-day colors (deep and dim at night). No photos. The text moves a
// few pixels every minute, so nothing stays on the same pixels all night.
Item {
    id: clock
    // No photo: the screen saver's shade stays black.
    readonly property var shown: null
    property date now: new Date()
    readonly property var next: Picks.upcoming(Store.events, now, 3)
    property real shiftX: 0
    property real shiftY: 0
    Behavior on shiftX { NumberAnimation { duration: 3000; easing.type: Easing.InOutSine } }
    Behavior on shiftY { NumberAnimation { duration: 3000; easing.type: Easing.InOutSine } }

    Timer { interval: 1000; running: true; repeat: true; onTriggered: clock.now = new Date() }
    Timer {
        interval: 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            clock.shiftX = (Math.random() - 0.5) * 48
            clock.shiftY = (Math.random() - 0.5) * 32
        }
    }

    function when(event) {
        const start = new Date(event.startMs)
        const time = Qt.formatTime(start, "h:mm ap")
        const days = Picks.dayNumber(start) - Picks.dayNumber(now)
        if (days === 0)
            return time
        if (days === 1)
            return qsTr("Tomorrow %1").arg(time)
        return Qt.formatDate(start, "dddd") + " " + time
    }

    GradientTile {
        id: backdrop
        anchors.fill: parent
        radius: 0
        colors: [Theme.glowBlue, Theme.glowCoral, Theme.glowAmber, Theme.glowCream]
    }

    Column {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: clock.shiftX
        anchors.verticalCenterOffset: clock.shiftY
        spacing: 8

        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(clock.now, "h:mm AP").split(" ")[0] // 12-hour, like Home
            color: backdrop.ink
            font.pixelSize: Math.min(clock.width * 0.2, clock.height * 0.34)
            font.weight: Font.Light
        }
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(clock.now, "dddd, MMMM d")
            color: backdrop.ink
            font.pixelSize: Theme.fontLg
        }
        Item { width: 1; height: 28; visible: clock.next.length > 0 }
        Repeater {
            model: clock.next
            delegate: Row {
                required property var modelData
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 14
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 12; height: 12; radius: 6
                    color: modelData.displayColor || backdrop.strong
                }
                Label {
                    text: clock.when(modelData)
                    color: backdrop.inkMuted
                    font.pixelSize: Theme.fontMd
                }
                Label {
                    text: modelData.title || ""
                    color: backdrop.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                }
            }
        }
    }
}
