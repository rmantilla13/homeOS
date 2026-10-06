import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// At-a-glance dashboard: clock, today's agenda, chore progress, dinner, a photo.
Item {
    id: home
    signal openScreen(int index)

    property date now: new Date()
    readonly property string todayIso: Qt.formatDate(now, "yyyy-MM-dd")
    readonly property var todaysEvents: Store.events.filter(e => e.day === todayIso)
    readonly property var dinner: Store.meals.find(m => m.date === todayIso && m.meal === "dinner")
    readonly property var kids: Store.members.filter(m => m.tasksTotal > 0)

    Timer { interval: 1000; running: true; repeat: true; onTriggered: home.now = new Date() }

    function greeting() {
        const h = now.getHours()
        return h < 12 ? qsTr("Good morning") : h < 18 ? qsTr("Good afternoon") : qsTr("Good evening")
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        // Header: clock and date.
        RowLayout {
            Layout.fillWidth: true
            spacing: 32
            Label {
                text: Qt.formatTime(home.now, "h:mm")
                color: Theme.text
                font.pixelSize: Theme.fontHuge
                font.weight: Font.Light
            }
            ColumnLayout {
                spacing: 4
                Label {
                    text: Qt.formatDate(home.now, "dddd, MMMM d")
                    color: Theme.text
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.DemiBold
                }
                Label {
                    text: home.greeting() + (Store.familyName ? ", " + Store.familyName : "")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontMd
                }
            }
            Item { Layout.fillWidth: true }
            Label {
                visible: Store.mode === "demo"
                text: qsTr("DEMO")
                color: Theme.accent
                font.pixelSize: Theme.fontSm
                font.weight: Font.Bold
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacing

            // Today's agenda.
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 3
                title: qsTr("Today")
                actionText: qsTr("Calendar")
                onActionClicked: home.openScreen(1)

                ListView {
                    anchors.fill: parent
                    clip: true
                    spacing: 12
                    model: home.todaysEvents
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: Theme.compact ? 84 : 96
                        radius: 18
                        color: Theme.surfaceAlt
                        Rectangle {
                            width: 10; radius: 5
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 14 }
                            color: modelData.displayColor
                        }
                        Column {
                            anchors { left: parent.left; leftMargin: 40; verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
                            spacing: 4
                            Label { text: modelData.title; color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold; elide: Text.ElideRight; width: parent.width }
                            Label {
                                text: modelData.timeLabel + (modelData.memberNames ? "  ·  " + modelData.memberNames : "")
                                color: Theme.textMuted; font.pixelSize: Theme.fontSm; elide: Text.ElideRight; width: parent.width
                            }
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: home.todaysEvents.length === 0
                        text: qsTr("Nothing on the calendar today 🎉")
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontMd
                    }
                }
            }

            // Chore progress per person.
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 3
                title: qsTr("Chores")
                actionText: qsTr("All chores")
                onActionClicked: home.openScreen(2)

                Column {
                    anchors.fill: parent
                    spacing: 20
                    Repeater {
                        model: home.kids
                        delegate: RowLayout {
                            required property var modelData
                            width: parent.width
                            spacing: 20
                            MemberAvatar { member: modelData; size: Theme.compact ? 56 : 72 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                RowLayout {
                                    Label { text: modelData.display_name; color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                    Label { text: modelData.tasksDone + " / " + modelData.tasksTotal; color: Theme.textMuted; font.pixelSize: Theme.fontSm }
                                }
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 16; radius: 8
                                    color: Theme.surfaceAlt
                                    Rectangle {
                                        height: parent.height; radius: 8
                                        width: parent.width * (modelData.tasksTotal ? modelData.tasksDone / modelData.tasksTotal : 0)
                                        color: modelData.color
                                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                    }
                                }
                            }
                            Label {
                                visible: modelData.role === "child"
                                text: "★ " + modelData.points
                                color: Theme.text
                                font.pixelSize: Theme.fontMd
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.preferredWidth: 2
                spacing: Theme.spacing

                Card {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.compact ? 160 : 200
                    title: qsTr("Dinner tonight")
                    onActionClicked: home.openScreen(5)
                    actionText: qsTr("Plan")
                    Label {
                        anchors.fill: parent
                        text: home.dinner ? home.dinner.title : qsTr("Not planned yet")
                        color: home.dinner ? Theme.text : Theme.textMuted
                        font.pixelSize: Theme.fontLg
                        wrapMode: Text.WordWrap
                    }
                }

                // Rotating photo.
                PhotoTile {
                    id: homePhoto
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.radius
                    property int photoIndex: 0
                    photo: Store.photos.length ? Store.photos[photoIndex % Store.photos.length] : null

                    Timer { interval: 8000; running: true; repeat: true; onTriggered: homePhoto.photoIndex++ }
                    Label {
                        anchors.centerIn: parent
                        visible: !homePhoto.photo
                        text: qsTr("Add photos from the iPhone app")
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontSm
                    }
                    TapHandler { onTapped: home.openScreen(4) }
                }
            }
        }
    }
}
