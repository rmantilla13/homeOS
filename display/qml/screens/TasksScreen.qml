import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Today's chores, one column per person. Kids tap a chore to mark it done.
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
                            Label {
                                text: column.member.role === "child"
                                      ? "★ " + column.member.points + qsTr(" points")
                                      : column.member.tasksDone + " / " + column.member.tasksTotal + qsTr(" done")
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
                            readonly property bool done: modelData.status === "done"
                            readonly property bool pending: modelData.status === "pending"

                            width: ListView.view.width
                            height: 112
                            radius: 20
                            color: done ? Qt.rgba(0.24, 0.75, 0.48, 0.18) : pending ? Qt.rgba(0.96, 0.65, 0.14, 0.18) : Theme.surfaceAlt
                            scale: tap.pressed ? 0.97 : 1
                            Behavior on scale { NumberAnimation { duration: 90 } }
                            Behavior on color { ColorAnimation { duration: 250 } }

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
                                        text: taskCard.pending ? qsTr("Waiting for a parent to OK")
                                              : taskCard.modelData.points > 0 ? "+" + taskCard.modelData.points + " ★" : ""
                                        color: taskCard.pending ? Theme.warning : Theme.textMuted
                                        font.pixelSize: Theme.fontXs
                                    }
                                }
                                Rectangle {
                                    width: 56; height: 56; radius: 28
                                    color: taskCard.done ? Theme.success : taskCard.pending ? Theme.warning : "transparent"
                                    border.width: taskCard.done || taskCard.pending ? 0 : 4
                                    border.color: Theme.divider
                                    Label {
                                        anchors.centerIn: parent
                                        text: taskCard.done ? "✓" : taskCard.pending ? "…" : ""
                                        color: "white"
                                        font.pixelSize: 30
                                        font.weight: Font.Bold
                                    }
                                }
                            }
                            TapHandler {
                                id: tap
                                enabled: !taskCard.done && !taskCard.pending
                                onTapped: Store.completeTask(taskCard.modelData.id, column.member.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
