import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Hour-by-hour schedule for one or more days: pastel event blocks with the
// member's initial, all-day events on top, and a line for the current time.
Item {
    id: grid
    property var days: []          // Date objects at local midnight
    property int startHour: 6
    property int endHour: 22
    property real hourHeight: Theme.compact ? 64 : 76
    readonly property real labelWidth: 64
    readonly property real columnWidth: (width - labelWidth) / Math.max(1, days.length)
    property date now: new Date()

    Timer { interval: 60000; running: true; repeat: true; onTriggered: grid.now = new Date() }

    function iso(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function eventsFor(day, allDay) {
        return Store.events.filter(e => e.day === iso(day) && !!e.all_day === allDay)
    }
    // Side-by-side lanes for overlapping events.
    function layout(events) {
        const lanesEnd = []
        const out = events.map(e => {
            const start = e.startMs, end = Math.max(Date.parse(e.ends_at) || e.startMs, start + 30 * 60000)
            let lane = lanesEnd.findIndex(t => t <= start)
            if (lane < 0) { lane = lanesEnd.length; lanesEnd.push(end) } else lanesEnd[lane] = end
            return { e: e, start: start, end: end, lane: lane }
        })
        return out.map(o => Object.assign(o, { lanes: lanesEnd.length }))
    }
    function memberFor(e) {
        const ids = e.member_ids || []
        return Store.members.find(m => m.id === ids[0])
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // Day headers (multi-day) and all-day events.
        Row {
            Layout.fillWidth: true
            Layout.leftMargin: grid.labelWidth
            visible: grid.days.length > 1
            Repeater {
                model: grid.days
                delegate: Item {
                    required property var modelData
                    readonly property bool today: grid.iso(modelData) === grid.iso(grid.now)
                    width: grid.columnWidth
                    height: 56
                    Rectangle {
                        anchors.centerIn: parent
                        width: dayLabel.implicitWidth + 28
                        height: 46
                        radius: 23
                        color: today ? Theme.accent : "transparent"
                        Label {
                            id: dayLabel
                            anchors.centerIn: parent
                            text: Qt.formatDate(modelData, "ddd d")
                            color: today ? Theme.onAccent : Theme.text
                            font.pixelSize: Theme.fontMd - 2
                            font.weight: Font.Medium
                        }
                    }
                }
            }
        }
        Row {
            Layout.fillWidth: true
            Layout.leftMargin: grid.labelWidth
            Repeater {
                model: grid.days
                delegate: Column {
                    required property var modelData
                    width: grid.columnWidth
                    spacing: 4
                    Repeater {
                        model: grid.eventsFor(modelData, true)
                        delegate: Rectangle {
                            required property var modelData
                            x: 3
                            width: grid.columnWidth - 6
                            height: 34
                            radius: 10
                            color: modelData.tintColor
                            Label {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.title
                                elide: Text.ElideRight
                                color: modelData.inkColor
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }
            }
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: (grid.endHour - grid.startHour) * grid.hourHeight + 24
            boundsBehavior: Flickable.StopAtBounds
            Component.onCompleted: {
                const h = Math.max(grid.startHour, Math.min(grid.now.getHours() - 1, grid.endHour - 6))
                contentY = (h - grid.startHour) * grid.hourHeight
            }

            Item {
                width: flick.width
                height: flick.contentHeight

                // Hour lines and labels.
                Repeater {
                    model: grid.endHour - grid.startHour + 1
                    delegate: Item {
                        required property int index
                        y: 12 + index * grid.hourHeight
                        width: parent.width
                        Label {
                            width: grid.labelWidth - 12
                            y: -height / 2
                            horizontalAlignment: Text.AlignRight
                            text: Qt.formatTime(new Date(2000, 0, 1, grid.startHour + index), "h AP").toLowerCase()
                            color: Theme.textMuted
                            font.pixelSize: 13
                        }
                        Rectangle { x: grid.labelWidth; width: parent.width - grid.labelWidth; height: 1; color: Theme.divider }
                    }
                }
                // Column dividers.
                Repeater {
                    model: grid.days.length
                    delegate: Rectangle {
                        required property int index
                        x: grid.labelWidth + index * grid.columnWidth
                        y: 12
                        width: 1
                        height: parent.height - 24
                        color: Theme.divider
                    }
                }

                // Events.
                Repeater {
                    model: grid.days
                    delegate: Item {
                        id: dayCol
                        required property var modelData
                        required property int index
                        readonly property real dayStart: new Date(modelData.getFullYear(), modelData.getMonth(), modelData.getDate(), grid.startHour).getTime()
                        x: grid.labelWidth + index * grid.columnWidth
                        y: 12
                        width: grid.columnWidth
                        height: parent.height - 24

                        Repeater {
                            model: grid.layout(grid.eventsFor(dayCol.modelData, false))
                            delegate: Rectangle {
                                required property var modelData
                                readonly property var member: grid.memberFor(modelData.e)
                                readonly property real laneWidth: (dayCol.width - 8) / modelData.lanes
                                x: 4 + modelData.lane * laneWidth
                                y: Math.max(0, (modelData.start - dayCol.dayStart) / 3600000 * grid.hourHeight) + 2
                                width: laneWidth - 4
                                height: Math.max(36, (modelData.end - modelData.start) / 3600000 * grid.hourHeight - 4)
                                radius: 14
                                color: modelData.e.tintColor
                                clip: true

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    anchors.rightMargin: badge.visible ? 38 : 10
                                    spacing: 2
                                    Label {
                                        width: parent.width
                                        text: modelData.e.title
                                        color: modelData.e.inkColor
                                        font.pixelSize: Theme.fontXs + 1
                                        font.weight: Font.DemiBold
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                    Label {
                                        width: parent.width
                                        text: modelData.e.timeLabel
                                        color: modelData.e.inkColor
                                        opacity: 0.8
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }
                                }
                                MemberAvatar {
                                    id: badge
                                    visible: !!member && parent.height >= 48 && parent.width >= 90
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 8
                                    member: parent.member || ({})
                                    size: 26
                                }
                            }
                        }

                        // Now line.
                        Rectangle {
                            visible: grid.iso(dayCol.modelData) === grid.iso(grid.now)
                                     && grid.now.getHours() >= grid.startHour && grid.now.getHours() < grid.endHour
                            y: (grid.now.getTime() - dayCol.dayStart) / 3600000 * grid.hourHeight
                            width: parent.width
                            height: 2
                            color: Theme.glowCoral
                            Rectangle { x: -5; y: -4; width: 10; height: 10; radius: 5; color: Theme.glowCoral }
                        }
                    }
                }
            }
        }
    }
}
