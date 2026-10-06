import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Family calendar with Day / Week / Month views, plus Add event.
Item {
    id: cal
    property int view: 1                  // 0 day, 1 week, 2 month
    property date focusDate: today()
    property var selectedMembers: ({})

    function today() { const n = new Date(); return new Date(n.getFullYear(), n.getMonth(), n.getDate()) }
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

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function isoLocal(d) {
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":00"
    }
    function roundUpHour(base) {
        const d = new Date(base.getTime())
        d.setMinutes(0, 0, 0)
        if (base.getMinutes() > 0 || base.getSeconds() > 0)
            d.setHours(d.getHours() + 1)
        return d
    }
    function openAdd() {
        const day = cal.view === 2 ? cal.focusDate : (cal.visibleDays[0] || cal.today())
        const base = new Date(day.getFullYear(), day.getMonth(), day.getDate())
        const now = new Date()
        const sameDay = base.getFullYear() === now.getFullYear()
            && base.getMonth() === now.getMonth() && base.getDate() === now.getDate()
        const start = sameDay ? roundUpHour(now) : new Date(base.getFullYear(), base.getMonth(), base.getDate(), 9, 0, 0)
        eventTitle.text = ""
        eventPlace.text = ""
        eventAllDay = false
        eventStart = start
        eventEnd = new Date(start.getTime() + 60 * 60 * 1000)
        selectedMembers = ({})
        addEvent.open()
        eventTitle.forceActiveFocus()
    }
    function toggleMember(id) {
        const next = Object.assign({}, selectedMembers)
        if (next[id]) delete next[id]
        else next[id] = true
        selectedMembers = next
    }
    function submitEvent() {
        const title = eventTitle.text.trim()
        if (!title.length) return
        let start = new Date(eventStart.getTime())
        let end = new Date(eventEnd.getTime())
        if (eventAllDay) {
            start = new Date(start.getFullYear(), start.getMonth(), start.getDate(), 0, 0, 0)
            end = new Date(start.getFullYear(), start.getMonth(), start.getDate(), 23, 59, 0)
        } else if (end < start) {
            end = new Date(start.getTime() + 60 * 60 * 1000)
        }
        const ids = Object.keys(selectedMembers)
        Store.addEvent(title, eventPlace.text.trim(), isoLocal(start), isoLocal(end), eventAllDay, ids)
        addEvent.close()
    }

    property bool eventAllDay: false
    property date eventStart: new Date()
    property date eventEnd: new Date()

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
            IconButton {
                icon: "plus"
                fill: Theme.accent
                ink: Theme.accentInk
                onClicked: cal.openAdd()
            }
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

    FormDialog {
        id: addEvent
        titleText: qsTr("New event")
        canSubmit: eventTitle.text.trim().length > 0
        onSubmitted: cal.submitEvent()

        FormField {
            id: eventTitle
            placeholderText: qsTr("Title")
            onAccepted: cal.submitEvent()
        }
        FormField {
            id: eventPlace
            placeholderText: qsTr("Place (optional)")
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            Label { text: qsTr("All day"); color: Theme.text; font.pixelSize: Theme.fontSm; Layout.fillWidth: true }
            Toggle {
                checked: cal.eventAllDay
                onToggled: on => cal.eventAllDay = on
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            visible: !cal.eventAllDay
            Label {
                text: qsTr("Starts %1").arg(Qt.formatDateTime(cal.eventStart, "ddd h:mm AP"))
                color: Theme.text
                font.pixelSize: Theme.fontSm
                Layout.fillWidth: true
            }
            IconButton {
                icon: "left"
                onClicked: {
                    cal.eventStart = new Date(cal.eventStart.getTime() - 30 * 60 * 1000)
                    cal.eventEnd = new Date(cal.eventEnd.getTime() - 30 * 60 * 1000)
                }
            }
            IconButton {
                icon: "right"
                onClicked: {
                    cal.eventStart = new Date(cal.eventStart.getTime() + 30 * 60 * 1000)
                    cal.eventEnd = new Date(cal.eventEnd.getTime() + 30 * 60 * 1000)
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: cal.eventAllDay
                      ? qsTr("Day %1").arg(Qt.formatDate(cal.eventStart, "ddd MMM d"))
                      : qsTr("Ends %1").arg(Qt.formatDateTime(cal.eventEnd, "h:mm AP"))
                color: Theme.text
                font.pixelSize: Theme.fontSm
                Layout.fillWidth: true
            }
            IconButton {
                icon: "left"
                onClicked: {
                    if (cal.eventAllDay)
                        cal.eventStart = cal.addDays(cal.eventStart, -1)
                    else if (cal.eventEnd.getTime() - cal.eventStart.getTime() > 30 * 60 * 1000)
                        cal.eventEnd = new Date(cal.eventEnd.getTime() - 30 * 60 * 1000)
                }
            }
            IconButton {
                icon: "right"
                onClicked: {
                    if (cal.eventAllDay)
                        cal.eventStart = cal.addDays(cal.eventStart, 1)
                    else
                        cal.eventEnd = new Date(cal.eventEnd.getTime() + 30 * 60 * 1000)
                }
            }
        }
        Label { text: qsTr("Who"); color: Theme.textMuted; font.pixelSize: Theme.fontXs }
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
                        selected: !!cal.selectedMembers[modelData.id]
                        TapHandler { onTapped: cal.toggleMember(modelData.id) }
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
    }
}
