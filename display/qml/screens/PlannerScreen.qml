import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Weekly meal plan next to the shared shopping list.
Item {
    id: planner
    readonly property date today: new Date()
    readonly property var list: Store.lists.length ? Store.lists[0] : null
    readonly property var items: list ? list.items || [] : []

    function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        Card {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            title: qsTr("Dinners this week")

            Column {
                anchors.fill: parent
                spacing: 10
                Repeater {
                    model: 7
                    delegate: Rectangle {
                        required property int index
                        readonly property date day: planner.addDays(planner.today, index)
                        readonly property var meal: Store.meals.find(m => m.date === Qt.formatDate(day, "yyyy-MM-dd") && m.meal === "dinner")
                        width: parent.width
                        height: Theme.compact ? 70 : 92
                        radius: 18
                        color: index === 0 ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12) : Theme.surfaceAlt
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 24
                            anchors.rightMargin: 24
                            spacing: 24
                            Label {
                                text: index === 0 ? qsTr("Today") : Qt.formatDate(day, "dddd")
                                color: index === 0 ? Theme.accent : Theme.textMuted
                                font.pixelSize: Theme.fontSm
                                font.weight: Font.DemiBold
                                Layout.preferredWidth: 160
                            }
                            Label {
                                text: meal ? meal.title : qsTr("—")
                                color: meal ? Theme.text : Theme.textMuted
                                font.pixelSize: Theme.fontMd
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }

        Card {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            title: planner.list ? planner.list.name : qsTr("Shopping list")

            ColumnLayout {
                anchors.fill: parent
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16
                    visible: planner.list !== null
                    TextField {
                        id: newItem
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.touchTarget
                        placeholderText: qsTr("Add an item…")
                        font.pixelSize: Theme.fontMd
                        color: Theme.text
                        background: Rectangle { radius: 18; color: Theme.surfaceAlt }
                        leftPadding: 24
                        onAccepted: add()
                        function add() { Store.addListItem(planner.list.id, text); text = "" }
                    }
                    PillButton { text: qsTr("Add"); enabled: newItem.text.trim().length > 0; onClicked: newItem.add() }
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 8
                    // Unchecked first.
                    model: planner.items.filter(i => !i.done).concat(planner.items.filter(i => i.done))
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        width: ListView.view.width
                        height: 80
                        radius: 16
                        color: Theme.surfaceAlt
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            spacing: 20
                            Rectangle {
                                width: 44; height: 44; radius: 12
                                color: row.modelData.done ? Theme.success : "transparent"
                                border.width: row.modelData.done ? 0 : 3
                                border.color: Theme.divider
                                Label { anchors.centerIn: parent; text: row.modelData.done ? "✓" : ""; color: "white"; font.pixelSize: 26; font.weight: Font.Bold }
                            }
                            Label {
                                text: row.modelData.text + (row.modelData.quantity ? "  ·  " + row.modelData.quantity : "")
                                color: row.modelData.done ? Theme.textMuted : Theme.text
                                font.pixelSize: Theme.fontMd
                                font.strikeout: row.modelData.done
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        TapHandler { onTapped: Store.setListItemDone(planner.list.id, row.modelData.id, !row.modelData.done) }
                    }
                }
            }
        }
    }
}
