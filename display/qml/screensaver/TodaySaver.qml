import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// The day at a glance: the time, today's events, a family photo that
// changes now and then, and how many chores each person has left. Meant to
// stay up in a kitchen all day; it follows the time-of-day colors.
Rectangle {
    id: today
    color: Theme.background
    property int interval: 15000
    property date now: new Date()
    readonly property var events: Picks.todaysEvents(Store.events, now).slice(0, 6)
    readonly property var chores: Store.members.filter(m => m.tasksTotal > 0)
    readonly property real margin: Theme.compact ? 32 : 48
    property int index: 0
    property bool showA: true
    readonly property var shown: showA ? a.photo : b.photo

    function photoAt(i) { return Store.photos.length ? Store.photos[i % Store.photos.length] : null }
    Component.onCompleted: a.photo = photoAt(0)

    Timer { interval: 1000; running: true; repeat: true; onTriggered: today.now = new Date() }
    Timer {
        interval: today.interval
        running: Store.photos.length > 1
        repeat: true
        onTriggered: {
            today.index++
            const next = today.showA ? b : a
            next.photo = today.photoAt(today.index)
            today.showA = !today.showA
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: today.margin
        spacing: today.margin

        // The time and today's events.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 11
            spacing: 4

            Label {
                text: Qt.formatTime(today.now, "h:mm AP").split(" ")[0] // 12-hour, like Home
                color: Theme.text
                font.pixelSize: Theme.fontHuge
                font.weight: Font.Light
            }
            Label {
                text: Qt.formatDate(today.now, "dddd, MMMM d")
                color: Theme.textMuted
                font.pixelSize: Theme.fontLg
            }
            Label {
                Layout.topMargin: Theme.compact ? 24 : 36
                text: qsTr("TODAY")
                color: Theme.textMuted
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 1.5
            }
            Label {
                visible: today.events.length === 0
                Layout.topMargin: 8
                text: qsTr("Nothing on the calendar")
                color: Theme.textMuted
                font.pixelSize: Theme.fontMd
            }
            Repeater {
                model: today.events
                delegate: RowLayout {
                    required property var modelData
                    readonly property bool past: !modelData.all_day && modelData.startMs < today.now.getTime()
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    spacing: 14
                    opacity: past ? 0.45 : 1
                    Rectangle {
                        Layout.preferredWidth: 6
                        Layout.fillHeight: true
                        radius: 3
                        color: modelData.displayColor || Theme.accent
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label {
                            Layout.fillWidth: true
                            text: modelData.title || ""
                            elide: Text.ElideRight
                            color: Theme.text
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Label {
                            Layout.fillWidth: true
                            text: modelData.timeLabel + (modelData.memberNames ? " · " + modelData.memberNames : "")
                            elide: Text.ElideRight
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }
            }
            Item { Layout.fillHeight: true }
        }

        // A photo above the chores left.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 9
            spacing: today.margin / 2

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                PhotoTile { id: a; anchors.fill: parent; radius: Theme.radius; showCaption: false; opacity: today.showA ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.InOutQuad } } }
                PhotoTile { id: b; anchors.fill: parent; radius: Theme.radius; showCaption: false; opacity: today.showA ? 0 : 1
                            Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.InOutQuad } } }
            }

            // As tall as its people need; the photo takes the rest.
            Rectangle {
                readonly property real pad: Theme.compact ? 20 : 28
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(choresColumn.implicitHeight + pad * 2, today.height / 2)
                radius: Theme.radius
                color: Theme.surface
                clip: true

                Column {
                    id: choresColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: parent.pad }
                    spacing: 12
                    Label {
                        text: qsTr("CHORES LEFT")
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.5
                    }
                    Label {
                        visible: today.chores.length === 0
                        text: qsTr("No chores today")
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontMd
                    }
                    Flow {
                        width: parent.width
                        spacing: 14
                        Repeater {
                            model: today.chores
                            delegate: Row {
                                required property var modelData
                                readonly property int remaining: Math.max(0, modelData.tasksTotal - modelData.tasksDone)
                                spacing: 10
                                MemberAvatar { member: modelData; size: 44; anchors.verticalCenter: parent.verticalCenter }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    Label {
                                        text: modelData.display_name || ""
                                        color: Theme.text
                                        font.pixelSize: Theme.fontSm
                                        font.weight: Font.DemiBold
                                    }
                                    Label {
                                        text: remaining === 0 ? qsTr("All done") : remaining === 1 ? qsTr("1 left") : qsTr("%1 left").arg(remaining)
                                        color: remaining === 0 ? Theme.success : Theme.textMuted
                                        font.pixelSize: Theme.fontXs + 1
                                        font.weight: remaining === 0 ? Font.DemiBold : Font.Normal
                                    }
                                }
                                Item { width: 12; height: 1 }
                            }
                        }
                    }
                }
            }
        }
    }
}
