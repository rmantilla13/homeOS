import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Week at a glance: seven columns, events color-coded by family member.
Item {
    id: cal
    property int weekOffset: 0
    readonly property date today: new Date()
    readonly property date weekStart: addDays(today, -((today.getDay() + 6) % 7) + weekOffset * 7)

    function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x }
    function iso(d) { return Qt.formatDate(d, "yyyy-MM-dd") }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            Label {
                text: Qt.formatDate(cal.weekStart, "MMMM d") + " – " + Qt.formatDate(cal.addDays(cal.weekStart, 6), "MMMM d")
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            PillButton { text: "‹"; fill: Theme.surface; ink: Theme.text; implicitWidth: Theme.touchTarget; onClicked: cal.weekOffset-- }
            PillButton { text: qsTr("This week"); fill: Theme.surface; ink: Theme.text; enabled: cal.weekOffset !== 0; onClicked: cal.weekOffset = 0 }
            PillButton { text: "›"; fill: Theme.surface; ink: Theme.text; implicitWidth: Theme.touchTarget; onClicked: cal.weekOffset++ }
        }

        // Member legend.
        Row {
            spacing: 24
            Repeater {
                model: Store.members
                delegate: Row {
                    required property var modelData
                    spacing: 8
                    Rectangle { width: 20; height: 20; radius: 10; color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: modelData.display_name; color: Theme.textMuted; font.pixelSize: Theme.fontSm }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            Repeater {
                model: 7
                delegate: Rectangle {
                    id: dayCol
                    required property int index
                    readonly property date day: cal.addDays(cal.weekStart, index)
                    readonly property bool isToday: cal.iso(day) === cal.iso(cal.today)
                    readonly property var dayEvents: Store.events.filter(e => e.day === cal.iso(day))

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    radius: Theme.radius
                    color: Theme.surface
                    border.width: isToday ? 3 : 0
                    border.color: Theme.accent

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10

                        Column {
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Qt.formatDate(dayCol.day, "ddd").toUpperCase()
                                color: dayCol.isToday ? Theme.accent : Theme.textMuted
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.DemiBold
                            }
                            Rectangle {
                                width: 56; height: 56; radius: 28
                                color: dayCol.isToday ? Theme.accent : "transparent"
                                Label {
                                    anchors.centerIn: parent
                                    text: dayCol.day.getDate()
                                    color: dayCol.isToday ? "white" : Theme.text
                                    font.pixelSize: Theme.fontLg
                                    font.weight: Font.DemiBold
                                }
                            }
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 8
                            model: dayCol.dayEvents
                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: eventCol.implicitHeight + 20
                                radius: 14
                                color: modelData.tintColor
                                Rectangle { width: 6; radius: 3; color: modelData.displayColor; anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 8 } }
                                Column {
                                    id: eventCol
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 22; rightMargin: 8 }
                                    spacing: 2
                                    Label { text: modelData.title; color: Theme.text; font.pixelSize: Theme.fontXs + 2; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; width: parent.width }
                                    Label { text: modelData.all_day ? qsTr("All day") : modelData.timeLabel.split(" – ")[0]; color: Theme.textMuted; font.pixelSize: Theme.fontXs; width: parent.width }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
