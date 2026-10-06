import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Today's chores, one column per person. Kids tap a chore to mark it done.
// Plus adds a chore (points always need a parent's OK from the wall).
Item {
    id: tasksScreen
    readonly property var people: Store.members.filter(m => m.tasksTotal > 0)
        .sort((a, b) => (a.role === "child" ? 0 : 1) - (b.role === "child" ? 0 : 1))
    readonly property var choreIcons: ["🛏️", "🎹", "🍽️", "🐶", "🧸", "🪴", "🗑️", "🧹", "📚", "🦷"]
    property string draftIcon: "🛏️"
    property string draftAssignee: ""
    property int draftPoints: 10

    function openAdd() {
        draftIcon = choreIcons[0]
        draftPoints = 10
        draftAssignee = (Store.members.find(m => m.role === "child") || Store.members[0] || {}).id || ""
        taskTitle.text = ""
        addTask.open()
        taskTitle.forceActiveFocus()
    }
    function submitTask() {
        Qt.inputMethod.commit()
        const title = taskTitle.text.trim()
        if (!title.length || !draftAssignee.length) return
        // Wall / device isn't a parent: points always require approval (tasks_guard).
        Store.addTask(title, draftIcon, draftAssignee, draftPoints, draftPoints > 0, "FREQ=DAILY")
        addTask.close()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            Label {
                text: qsTr("Today's chores")
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            IconButton {
                icon: "plus"
                fill: Theme.accent
                ink: Theme.accentInk
                onClicked: tasksScreen.openAdd()
            }
        }

        Label {
            visible: tasksScreen.people.length === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: qsTr("No chores for today yet.\nTap + to add one.")
            color: Theme.textMuted
            font.pixelSize: Theme.fontMd
        }

        // Columns keep a readable minimum width and scroll sideways when they don't fit.
        ListView {
            id: columns
            visible: tasksScreen.people.length > 0
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

                            width: ListView.view.width
                            height: 112
                            radius: 20
                            color: done ? Qt.rgba(0.24, 0.75, 0.48, 0.18) : pending ? Qt.rgba(0.96, 0.65, 0.14, 0.18) : Theme.surfaceAlt
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
                                        text: taskCard.pending ? qsTr("Waiting for a parent to OK")
                                              : taskCard.modelData.points > 0 ? "+" + taskCard.modelData.points + " ★" : ""
                                        color: taskCard.pending ? Theme.warning : Theme.textMuted
                                        font.pixelSize: Theme.fontXs
                                    }
                                }
                                Rectangle {
                                    id: check
                                    width: 56; height: 56; radius: 28
                                    color: taskCard.done ? Theme.success : taskCard.pending ? Theme.warning : "transparent"
                                    border.width: taskCard.done || taskCard.pending ? 0 : 4
                                    border.color: Theme.divider
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
                                onTapped: Store.completeTask(taskCard.modelData.id, column.member.id)
                            }
                        }
                    }
                }
            }
        }
    }

    FormDialog {
        id: addTask
        titleText: qsTr("New chore")
        canSubmit: taskTitle.text.trim().length > 0 && tasksScreen.draftAssignee.length > 0
        onSubmitted: tasksScreen.submitTask()

        FormField {
            id: taskTitle
            placeholderText: qsTr("Chore")
            onAccepted: addTask.requestSubmit()
        }
        Flow {
            Layout.fillWidth: true
            spacing: 10
            Repeater {
                model: tasksScreen.choreIcons
                delegate: Rectangle {
                    required property string modelData
                    width: 56; height: 56; radius: 28
                    color: tasksScreen.draftIcon === modelData ? Theme.accentSoft : Theme.surfaceAlt
                    border.width: tasksScreen.draftIcon === modelData ? 2 : 0
                    border.color: Theme.accent
                    Label {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: Theme.emojiFont
                        font.pixelSize: 28
                    }
                    TapHandler { onTapped: tasksScreen.draftIcon = modelData }
                }
            }
        }
        Label { text: qsTr("For"); color: Theme.textMuted; font.pixelSize: Theme.fontXs }
        Flow {
            Layout.fillWidth: true
            spacing: 12
            Repeater {
                model: Store.members
                delegate: Column {
                    required property var modelData
                    spacing: 6
                    MemberAvatar {
                        anchors.horizontalCenter: parent.horizontalCenter
                        member: modelData
                        size: 64
                        selected: tasksScreen.draftAssignee === modelData.id
                        TapHandler { onTapped: tasksScreen.draftAssignee = modelData.id }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.display_name
                        color: Theme.text
                        font.pixelSize: Theme.fontXs
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: qsTr("%1 points · parent OK").arg(tasksScreen.draftPoints)
                color: Theme.text
                font.pixelSize: Theme.fontSm
                Layout.fillWidth: true
            }
            IconButton {
                icon: "left"
                enabled: tasksScreen.draftPoints > 0
                onClicked: tasksScreen.draftPoints = Math.max(0, tasksScreen.draftPoints - 5)
            }
            IconButton {
                icon: "right"
                enabled: tasksScreen.draftPoints < 200
                onClicked: tasksScreen.draftPoints = Math.min(200, tasksScreen.draftPoints + 5)
            }
        }
    }
}
