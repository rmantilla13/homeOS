import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// The screen saver styles as tappable cards, four to a row. Used by the
// picker on the Media page and by the settings sheet.
GridLayout {
    id: options
    property real cardHeight: 230
    property real gap: 16
    // Short cards (Settings) show the icon and title only.
    readonly property bool small: cardHeight < 170
    columns: 4
    rowSpacing: gap
    columnSpacing: gap

    readonly property var styles: [
        { key: "photos",   icon: "photo",    title: qsTr("Photos"),      body: qsTr("One photo at a time, slowly drifting") },
        { key: "collage",  icon: "grid",     title: qsTr("Collage"),     body: qsTr("A mosaic, in a new layout each time") },
        { key: "frame",    icon: "frame",    title: qsTr("Smart frame"), body: qsTr("Portrait photos in pairs, side by side") },
        { key: "memories", icon: "sparkle",  title: qsTr("On this day"), body: qsTr("Photos from this day in past years") },
        { key: "video",    icon: "video",    title: qsTr("Video"),       body: qsTr("Family videos full screen, muted") },
        { key: "clock",    icon: "clock",    title: qsTr("Clock"),       body: qsTr("A big clock and what's next") },
        { key: "today",    icon: "calendar", title: qsTr("Today"),       body: qsTr("Today's plans and chores, and a photo") }
    ]

    Repeater {
        model: options.styles
        delegate: Rectangle {
            required property var modelData
            readonly property bool selected: Device.screensaver === modelData.key
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: options.cardHeight
            // Four to a row also when the last row has fewer.
            Layout.maximumWidth: (options.width - options.gap * (options.columns - 1)) / options.columns
            radius: 24
            color: selected ? Theme.accentSoft : Theme.surfaceAlt
            border.width: selected ? 3 : 0
            border.color: Theme.accent
            scale: optTap.pressed ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: Theme.quick } }
            Behavior on color { ColorAnimation { duration: Theme.quick } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: options.small ? 16 : options.cardHeight < 200 ? 18 : 22
                spacing: options.cardHeight < 200 ? 6 : 10
                Rectangle {
                    readonly property real side: options.small ? 48 : 64
                    width: side; height: side; radius: side / 2
                    color: selected ? Theme.accent : Theme.surface
                    Behavior on color { ColorAnimation { duration: Theme.quick } }
                    Icon { anchors.centerIn: parent; name: modelData.icon; size: options.small ? 24 : 30; color: selected ? Theme.accentInk : Theme.text }
                }
                Item { Layout.fillHeight: true }
                Label {
                    Layout.fillWidth: true
                    text: modelData.title
                    elide: Text.ElideRight
                    color: Theme.text
                    font.pixelSize: options.small ? Theme.fontSm : Theme.fontMd
                    font.weight: Font.DemiBold
                }
                Label {
                    visible: !options.small
                    Layout.fillWidth: true
                    text: modelData.body
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs + 1
                }
            }
            TapHandler { id: optTap; onTapped: Device.screensaver = modelData.key }
        }
    }
}
