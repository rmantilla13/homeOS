import QtQuick
import QtQuick.Controls
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// "On this day": photos taken on this date in earlier years ("2 years ago
// today"), then within three days of it ("1 year ago this week"), full
// screen and one at a time. With none, the newest photos with their dates.
// It draws on the photos the display has loaded (the newest 200).
Item {
    id: memories
    property int interval: 10000
    property date now: new Date()
    readonly property var found: Picks.memories(Store.photos, now)
    readonly property bool fallback: found.length === 0
    readonly property var items: fallback ? Store.photos.map(p => ({ photo: p, years: 0, sameDay: false })) : found
    property int index: 0
    property bool showA: true
    readonly property var shown: {
        const item = showA ? a.item : b.item
        return item ? item.photo : null
    }

    function itemAt(i) { return items.length ? items[i % items.length] : null }
    function heading(item) {
        if (!item)
            return ""
        if (fallback)
            return item.photo.dateLabel || ""
        const years = item.years
        if (item.sameDay)
            return years === 1 ? qsTr("1 year ago today") : qsTr("%1 years ago today").arg(years)
        return years === 1 ? qsTr("1 year ago this week") : qsTr("%1 years ago this week").arg(years)
    }
    function subheading(item) {
        if (!item)
            return ""
        return fallback ? qsTr("Recent photos") : Qt.formatDate(new Date(item.photo.takenMs), "MMMM d, yyyy")
    }

    Component.onCompleted: { a.item = itemAt(0); a.drift.restart() }
    onItemsChanged: {
        const slide = showA ? a : b
        if (!slide.item && items.length) {
            slide.item = itemAt(index)
            slide.drift.restart()
        }
    }

    // A new day brings other anniversaries.
    Timer { interval: 10 * 60 * 1000; running: true; repeat: true; onTriggered: memories.now = new Date() }

    Timer {
        interval: memories.interval
        running: memories.items.length > 1
        repeat: true
        onTriggered: {
            memories.index++
            const next = memories.showA ? b : a
            next.item = memories.itemAt(memories.index)
            next.drift.restart()
            memories.showA = !memories.showA
        }
    }

    component Slide: Item {
        id: slide
        property var item: null
        property alias drift: driftAnim
        anchors.fill: parent
        Behavior on opacity { NumberAnimation { duration: 1600; easing.type: Easing.InOutQuad } }

        PhotoTile {
            id: picture
            anchors.fill: parent
            photo: slide.item ? slide.item.photo : null
            showCaption: false
            color: "black"
            radius: 0
            NumberAnimation {
                id: driftAnim
                target: picture
                property: "scale"
                from: 1.0
                to: 1.1
                duration: memories.interval + 1600
                easing.type: Easing.InOutSine
            }
        }

        // When it was, over a shade at the top.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 280
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Column {
            anchors { left: parent.left; top: parent.top; margins: 64 }
            spacing: 6
            Label {
                text: memories.heading(slide.item)
                color: "white"
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
            }
            Label {
                text: memories.subheading(slide.item)
                color: "#DDFFFFFF"
                font.pixelSize: Theme.fontMd
            }
        }
    }

    Slide { id: a; opacity: memories.showA ? 1 : 0 }
    Slide { id: b; opacity: memories.showA ? 0 : 1 }
}
