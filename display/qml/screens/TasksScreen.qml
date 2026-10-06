import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Today's chores, one column per person. Kids tap a chore to mark it done.
// A try a parent turned down stays that way until a parent undoes it on the
// phone; tapping it says so.
Item {
    id: tasksScreen
    readonly property var people: Store.members.filter(m => m.tasksTotal > 0)
        .sort((a, b) => (a.role === "child" ? 0 : 1) - (b.role === "child" ? 0 : 1))

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        Label {
            text: qsTr("Today's chores")
            color: Theme.text
            font.pixelSize: Theme.fontXl
            font.weight: Font.DemiBold
        }

        // Columns keep a readable minimum width and scroll sideways when they don't fit.
        ListView {
            id: columns
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            spacing: Theme.spacing
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            readonly property real columnWidth: Math.max(340, (width - spacing * (count - 1)) / Math.max(1, count))
            model: tasksScreen.people
            delegate: Rectangle {
                id: column
                required property var modelData
                readonly property var member: modelData
                readonly property var memberTasks: Store.tasks.filter(t => t.assignee_id === member.id)

                width: columns.columnWidth
                height: columns.height
                radius: Theme.radius
                color: Theme.surface

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 16

                    RowLayout {
                        spacing: 16
                        MemberAvatar { member: column.member; size: Theme.compact ? 60 : 72 }
                        Column {
                            Layout.fillWidth: true
                            Label { text: column.member.display_name; color: Theme.text; font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                            AnimatedNumber {
                                visible: column.member.role === "child"
                                value: column.member.points
                                prefix: "★ "
                                suffix: qsTr(" points")
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSm
                            }
                            Label {
                                visible: column.member.role !== "child"
                                text: column.member.tasksDone + " / " + column.member.tasksTotal + qsTr(" done")
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSm
                            }
                        }
                    }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 12
                        model: column.memberTasks
                        delegate: Rectangle {
                            id: taskCard
                            required property var modelData
                            readonly property string status: modelData.status
                            readonly property bool done: modelData.status === "done"
                            readonly property bool pending: modelData.status === "pending"
                            readonly property bool rejected: modelData.status === "rejected"

                            width: ListView.view.width
                            height: 112
                            radius: 20
                            color: done ? Qt.rgba(0.24, 0.75, 0.48, 0.18) : pending ? Qt.rgba(0.96, 0.65, 0.14, 0.18)
                                 : rejected ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.14) : Theme.surfaceAlt
                            scale: tap.pressed ? 0.97 : 1
                            Behavior on scale { NumberAnimation { duration: Theme.quick } }
                            Behavior on color { ColorAnimation { duration: Theme.quick } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 20
                                anchors.rightMargin: 20
                                spacing: 16
                                Label { text: taskCard.modelData.icon || "✔️"; font.family: Theme.emojiFont; font.pixelSize: 40 }
                                Column {
                                    Layout.fillWidth: true
                                    Label {
                                        width: parent.width
                                        text: taskCard.modelData.title
                                        color: Theme.text
                                        font.pixelSize: Theme.fontSm + 2
                                        font.weight: Font.DemiBold
                                        font.strikeout: taskCard.done
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                    Label {
                                        // Narrow columns: wrap rather than run under the ring.
                                        width: parent.width
                                        visible: text.length > 0
                                        text: taskCard.pending ? qsTr("Waiting for OK")
                                              : taskCard.rejected ? qsTr("Not OK'd · ask a parent")
                                              : taskCard.modelData.points > 0 ? "+" + taskCard.modelData.points + " ★" : ""
                                        color: taskCard.pending ? Theme.warning : taskCard.rejected ? Theme.danger : Theme.textMuted
                                        font.pixelSize: Theme.fontXs
                                        font.weight: taskCard.rejected ? Font.DemiBold : Font.Normal
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                }
                                Rectangle {
                                    id: check
                                    width: 56; height: 56; radius: 28
                                    color: taskCard.done ? Theme.success : taskCard.pending ? Theme.warning : "transparent"
                                    border.width: taskCard.done || taskCard.pending ? 0 : 4
                                    border.color: taskCard.rejected ? Theme.danger : Theme.divider
                                    Behavior on color { ColorAnimation { duration: Theme.quick } }
                                    Icon {
                                        anchors.centerIn: parent
                                        visible: taskCard.done
                                        name: "check"
                                        size: 30
                                        strokeWidth: 3
                                        color: "white"
                                    }
                                    Icon {
                                        anchors.centerIn: parent
                                        visible: taskCard.pending
                                        name: "clock"
                                        size: 28
                                        strokeWidth: 2.4
                                        color: "white"
                                    }
                                    Icon {
                                        anchors.centerIn: parent
                                        visible: taskCard.rejected
                                        name: "close"
                                        size: 24
                                        strokeWidth: 3
                                        color: Theme.danger
                                    }
                                    // Little celebration when a chore is ticked off.
                                    SequentialAnimation {
                                        id: pop
                                        NumberAnimation { target: check; property: "scale"; to: 1.3; duration: Theme.quick; easing.type: Easing.OutQuad }
                                        NumberAnimation { target: check; property: "scale"; to: 1.0; duration: Theme.smooth; easing.type: Easing.OutBack }
                                    }
                                    Connections {
                                        target: taskCard
                                        function onStatusChanged() { if (taskCard.done || taskCard.pending) pop.restart() }
                                    }
                                }
                            }
                            TapHandler {
                                id: tap
                                enabled: !taskCard.done && !taskCard.pending
                                // Turned down: the store explains instead of ticking it.
                                onTapped: Store.completeTask(taskCard.modelData.id, column.member.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
