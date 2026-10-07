import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Home: who's done what today, the family assistant, and what's coming up.
Item {
    id: home
    signal openScreen(int index)
    signal openAssistant(string question)
    signal pushToTalk()

    // On screen and not covered (set by Main.qml); the gradient tiles only
    // animate while it is.
    property bool shown: true

    property date now: new Date()
    readonly property string todayIso: Store.today
    readonly property var dinner: Store.meals.find(m => m.date === todayIso && m.meal === "dinner")
    readonly property var upcoming: Store.events
        .filter(e => (e.all_day ? e.day >= todayIso : e.startMs >= now.getTime() - 30 * 60000))
        .sort((a, b) => a.day === b.day ? (a.all_day ? -1 : b.all_day ? 1 : a.startMs - b.startMs)
                                        : (a.day < b.day ? -1 : 1))
        .slice(0, 6)

    Timer { interval: 1000; running: true; repeat: true; onTriggered: home.now = new Date() }

    function greeting() {
        const h = now.getHours()
        return h < 12 ? qsTr("Good morning") : h < 18 ? qsTr("Good afternoon") : qsTr("Good evening")
    }
    function whenLabel(e) {
        const prefix = e.day === todayIso ? qsTr("Today")
                     : Qt.formatDate(new Date(e.startMs), "dddd")
        return prefix + " · " + (e.all_day ? qsTr("All day") : e.timeLabel.split(" – ")[0])
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        // Header: family, time, date.
        RowLayout {
            Layout.fillWidth: true
            spacing: 20
            ColumnLayout {
                spacing: 2
                Label {
                    text: Store.familyName || "Ohana"
                    color: Theme.text
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.DemiBold
                }
                Label {
                    text: Qt.formatDate(home.now, "dddd, MMMM d")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSm
                }
            }
            Item { Layout.fillWidth: true }
            Label {
                visible: Store.mode === "demo"
                text: qsTr("DEMO")
                color: Theme.accent
                font.pixelSize: Theme.fontXs
                font.weight: Font.Bold
                font.letterSpacing: 1
            }
            Label {
                text: Qt.formatTime(home.now, "h:mm AP").split(" ")[0] // 12-hour; the AM/PM sits beside it
                color: Theme.text
                font.pixelSize: 56
                font.weight: Font.Light
            }
            Label {
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: 10
                text: Qt.formatTime(home.now, "AP")
                color: Theme.textMuted
                font.pixelSize: Theme.fontSm
            }
        }

        // Chore progress per person, on the member's own gradient.
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Repeater {
                // By count, not the list: a data refresh then updates the tiles
                // in place instead of rebuilding them (and restarting their drift).
                model: Store.members.length
                delegate: GradientTile {
                    id: memberTile
                    required property int index
                    readonly property var member: Store.members[index] || ({})
                    Layout.fillWidth: true
                    Layout.preferredHeight: 76
                    radius: Theme.radiusSm
                    baseColor: member.color || Theme.accent
                    active: home.shown
                    seed: 1 + index * 2.37
                    ringBias: 0.78
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 16
                        spacing: 12
                        // Avatar in a thin glass ring.
                        Rectangle {
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            radius: 23
                            color: memberTile.glassStroke
                            MemberAvatar {
                                anchors.centerIn: parent
                                member: memberTile.member
                                size: 42
                                color: Qt.darker(memberTile.member.color || Theme.accent, Theme.dark ? 1.25 : 1.0)
                                Behavior on color { ColorAnimation { duration: Theme.moodFade } }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            RowLayout {
                                Label { text: memberTile.member.display_name || ""; color: memberTile.ink; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                Label { text: (memberTile.member.tasksDone || 0) + "/" + (memberTile.member.tasksTotal || 0); color: memberTile.inkMuted; font.pixelSize: Theme.fontXs; font.weight: Font.Medium }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 8; radius: 4
                                color: memberTile.glassFill
                                Rectangle {
                                    height: parent.height; radius: 4
                                    width: parent.width * (memberTile.member.tasksTotal ? memberTile.member.tasksDone / memberTile.member.tasksTotal : 0)
                                    color: memberTile.strong
                                    Behavior on width { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
                                }
                            }
                        }
                    }
                    TapHandler { onTapped: home.openScreen(2) }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacing

            // The family assistant, on the mood's glow colors.
            GradientTile {
                id: assistantCard
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 5
                radius: 36
                colors: [Theme.glowBlue, Theme.glowCoral, Theme.glowAmber, Theme.glowCream]
                active: home.shown
                seed: 0.4
                period: 56000
                ringBias: 0.64
                ringScale: 1.05

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.compact ? 24 : 36
                    spacing: 14

                    Item { Layout.fillHeight: true; Layout.maximumHeight: 24 }
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: (home.greeting() + "!").toUpperCase()
                        color: assistantCard.inkMuted
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.2
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("How can I help you today?")
                        wrapMode: Text.WordWrap
                        color: assistantCard.ink
                        font.pixelSize: Theme.compact ? 36 : Theme.fontXl
                        font.weight: Font.Medium
                    }
                    Row {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 6
                        spacing: 10
                        Repeater {
                            model: AI.suggestions.slice(0, Theme.compact ? 2 : 3)
                            delegate: Rectangle {
                                required property string modelData
                                width: chipLabel.implicitWidth + 36
                                height: 52
                                radius: height / 2
                                color: assistantCard.glassFill
                                border.color: assistantCard.glassStroke
                                Label {
                                    id: chipLabel
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: assistantCard.ink
                                    font.pixelSize: Theme.fontSm - 1
                                }
                                TapHandler { onTapped: home.openAssistant(modelData) }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }

                    // "Ask Ohana anything" bar.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 76
                        radius: height / 2
                        color: Theme.dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.72)
                        Behavior on color { ColorAnimation { duration: Theme.moodFade } }
                        border.color: assistantCard.glassStroke
                        Label {
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Ask Ohana anything")
                            color: assistantCard.inkMuted
                            font.pixelSize: Theme.fontMd - 2
                        }
                        IconButton {
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 60; height: 60
                            icon: Voice.available ? "mic" : "mic-off"
                            fill: Theme.accent
                            ink: Theme.accentInk
                            // Push-to-talk: the question lands in the chat.
                            onClicked: home.pushToTalk()
                        }
                        TapHandler { onTapped: home.openAssistant("") }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 4
                spacing: Theme.spacing

                // Upcoming activities.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.radius
                    color: Theme.surface

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 20
                        spacing: 14
                        RowLayout {
                            Label { text: qsTr("Upcoming activities"); color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            Label {
                                text: qsTr("See all")
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSm
                                TapHandler { onTapped: home.openScreen(1) }
                            }
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 10
                            model: home.upcoming
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: 96
                                radius: Theme.radiusSm
                                color: Theme.surfaceAlt
                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 14
                                    spacing: 6
                                    RowLayout {
                                        spacing: 8
                                        Tag {
                                            text: modelData.memberNames ? modelData.memberNames.split(", ")[0] : qsTr("Family")
                                            tint: modelData.tintColor
                                            ink: modelData.inkColor
                                        }
                                        Label {
                                            visible: modelData.memberNames && modelData.memberNames.indexOf(",") > 0
                                            text: "+" + (modelData.memberNames ? modelData.memberNames.split(", ").length - 1 : 0)
                                            color: Theme.textMuted
                                            font.pixelSize: Theme.fontXs
                                        }
                                        Item { Layout.fillWidth: true }
                                        Label { text: home.whenLabel(modelData); color: Theme.textMuted; font.pixelSize: Theme.fontXs }
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        text: modelData.title
                                        color: Theme.text
                                        font.pixelSize: Theme.fontMd - 2
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: home.upcoming.length === 0
                                text: qsTr("Nothing coming up")
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSm
                            }
                        }
                    }
                }

                // Dinner tonight, on a warm food-colored gradient in every mood.
                GradientTile {
                    id: dinnerTile
                    Layout.fillWidth: true
                    Layout.preferredHeight: 88
                    radius: Theme.radius
                    baseColor: "#F2A65A"
                    active: home.shown
                    seed: 7.3
                    ringBias: 0.80
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 20
                        anchors.rightMargin: 20
                        spacing: 16
                        Rectangle {
                            width: 52; height: 52; radius: 26
                            color: dinnerTile.glassFill
                            border.color: dinnerTile.glassStroke
                            Icon { anchors.centerIn: parent; name: "meals"; color: dinnerTile.strong; size: 26 }
                        }
                        Column {
                            Layout.fillWidth: true
                            Label { text: qsTr("Dinner tonight"); color: dinnerTile.inkMuted; font.pixelSize: Theme.fontXs; font.weight: Font.Medium }
                            Label {
                                width: parent.width
                                text: home.dinner ? home.dinner.title : qsTr("Not planned yet")
                                color: dinnerTile.ink
                                font.pixelSize: Theme.fontMd - 2
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }
                    }
                    TapHandler { onTapped: home.openScreen(5) }
                }
            }
        }
    }
}
