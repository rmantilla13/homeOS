import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Family calendar with Day / Week / Month views.
Item {
    id: cal
    property int view: 1                  // 0 day, 1 week, 2 month
    property date focusDate: today()
    // The day that was today when last checked. Past midnight the view moves
    // on with it, unless someone had moved it to another day.
    property string knownToday: ""
    Component.onCompleted: knownToday = Store.today
    Connections {
        target: Store
        function onTodayChanged() {
            if (Qt.formatDate(cal.focusDate, "yyyy-MM-dd") === cal.knownToday)
                cal.focusDate = cal.today()
            cal.knownToday = Store.today
        }
    }

    function today() { const p = Store.today.split("-"); return new Date(+p[0], p[1] - 1, +p[2]) }
    function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x }
    function weekStart(d) { return addDays(d, -((d.getDay() + 6) % 7)) }
    function step(dir) {
        if (view === 0) focusDate = addDays(focusDate, dir)
        else if (view === 1) focusDate = addDays(focusDate, 7 * dir)
        else focusDate = new Date(focusDate.getFullYear(), focusDate.getMonth() + dir, 1)
    }
    readonly property var visibleDays: {
        if (view === 0) return [focusDate]
        const s = weekStart(focusDate)
        return [0, 1, 2, 3, 4, 5, 6].map(i => addDays(s, i))
    }
    readonly property string title: view === 0 ? Qt.formatDate(focusDate, "dddd, MMMM d")
                                  : view === 1 ? Qt.formatDate(visibleDays[0], "MMM d") + " – " + Qt.formatDate(visibleDays[6], "MMM d")
                                  : Qt.formatDate(focusDate, "MMMM yyyy")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing - 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: cal.title
                color: Theme.text
                font.pixelSize: Theme.compact ? 34 : Theme.fontXl
                font.weight: Font.Medium
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            SegmentedControl {
                options: [qsTr("Day"), qsTr("Week"), qsTr("Month")]
                currentIndex: cal.view
                onSelected: index => cal.view = index
            }
            IconButton { icon: "left"; onClicked: cal.step(-1) }
            PillButton {
                text: qsTr("Today")
                fill: Theme.surface
                ink: Theme.text
                onClicked: cal.focusDate = cal.today()
            }
            IconButton { icon: "right"; onClicked: cal.step(1) }
        }

        // Member legend.
        Row {
            spacing: 10
            Repeater {
                model: Store.members
                delegate: Tag {
                    required property var modelData
                    text: modelData.display_name
                    tint: modelData.tintColor
                    ink: modelData.inkColor
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radius
            color: Theme.surface

            TimeGrid {
                anchors.fill: parent
                anchors.margins: 16
                visible: cal.view !== 2
                days: cal.visibleDays
            }
            MonthGrid {
                anchors.fill: parent
                anchors.margins: 16
                visible: cal.view === 2
                anchorDate: cal.focusDate
                onDaySelected: day => { cal.focusDate = day; cal.view = 0 }
            }
        }
    }
}
