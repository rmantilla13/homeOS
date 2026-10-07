import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Month view: each day shows colored bars for its events. Tap a day to open it.
Item {
    id: month
    property date anchorDate: new Date()     // any day in the month shown
    signal daySelected(date day)

    readonly property date first: new Date(anchorDate.getFullYear(), anchorDate.getMonth(), 1)
    readonly property date gridStart: { const d = new Date(first); d.setDate(d.getDate() - (first.getDay() + 6) % 7); return d }
    readonly property string todayIso: Store.today

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        Row {
            Layout.fillWidth: true
            Repeater {
                model: [qsTr("Mon"), qsTr("Tue"), qsTr("Wed"), qsTr("Thu"), qsTr("Fri"), qsTr("Sat"), qsTr("Sun")]
                delegate: Label {
                    required property string modelData
                    width: month.width / 7
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSm
                }
            }
        }

        Grid {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 7
            Repeater {
                model: 42
                delegate: Item {
                    id: cell
                    required property int index
                    readonly property date day: { const d = new Date(month.gridStart); d.setDate(d.getDate() + index); return d }
                    readonly property string dayIso: Qt.formatDate(day, "yyyy-MM-dd")
                    readonly property bool inMonth: day.getMonth() === month.first.getMonth()
                    readonly property var dayEvents: Store.events.filter(e => e.day === dayIso)
                    width: month.width / 7
                    height: (parent.height) / 6

                    Rectangle { width: parent.width; height: 1; color: Theme.divider; visible: index >= 7 }

                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 8
                        spacing: 6
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 40; height: 40; radius: 20
                            color: cell.dayIso === month.todayIso ? Theme.text : "transparent"
                            Label {
                                anchors.centerIn: parent
                                text: cell.day.getDate()
                                color: cell.dayIso === month.todayIso ? Theme.background
                                       : cell.inMonth ? Theme.text : Theme.textMuted
                                opacity: cell.inMonth ? 1 : 0.6
                                font.pixelSize: Theme.fontSm
                            }
                        }
                        Repeater {
                            model: cell.dayEvents.slice(0, 2)
                            delegate: Rectangle {
                                required property var modelData
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: Math.min(64, cell.width - 20)
                                height: 10
                                radius: 5
                                color: modelData.displayColor
                            }
                        }
                        Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: cell.dayEvents.length > 2
                            text: "+" + (cell.dayEvents.length - 2)
                            color: Theme.textMuted
                            font.pixelSize: 12
                        }
                    }
                    TapHandler { onTapped: month.daySelected(cell.day) }
                }
            }
        }
    }
}
