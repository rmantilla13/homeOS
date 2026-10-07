import QtQuick
import QtQuick.Controls
import HomeOS
import HomeOS.Core
import "Picks.js" as Picks

// The screen saver styles as tappable cards, four to a row, a line about the
// one chosen and, for the collage, its layouts. Used by the picker on the
// Media page and by the settings sheet.
//
// Cards are sized from the width here, not by a layout: a GridLayout left
// the last row's card a sliver on the panel. Taps use WithinBounds, like
// IconButton: the default policy only watches the press, so it also reached
// the page under the dialog (the Media page opened a photo).
Item {
    id: options
    property real cardHeight: 132
    property real gap: 16
    readonly property int columns: 4
    readonly property real cardWidth: (width - gap * (columns - 1)) / columns
    // Short cards show the icon and title; the chosen style's line follows.
    readonly property bool small: cardHeight < 170
    implicitHeight: content.height

    readonly property var styles: [
        { key: "photos",   icon: "photo",    title: qsTr("Photos"),      body: qsTr("One photo at a time, slowly drifting") },
        { key: "collage",  icon: "grid",     title: qsTr("Collage"),     body: qsTr("A mosaic of family photos, each cropped to fill its tile") },
        { key: "frame",    icon: "frame",    title: qsTr("Smart frame"), body: qsTr("One photo at a time; portrait photos in pairs, side by side") },
        { key: "memories", icon: "sparkle",  title: qsTr("On this day"), body: qsTr("Photos taken on this day in past years") },
        { key: "video",    icon: "video",    title: qsTr("Video"),       body: qsTr("Family videos full screen, muted") },
        { key: "clock",    icon: "clock",    title: qsTr("Clock"),       body: qsTr("A big clock and what's next, no photos") },
        { key: "today",    icon: "calendar", title: qsTr("Today"),       body: qsTr("Today's plans, chores left and a photo") }
    ]
    readonly property var layouts: [
        { key: "auto",    title: qsTr("Auto") },
        { key: "classic", title: qsTr("Classic") },
        { key: "grid",    title: qsTr("Grid") },
        { key: "mosaic",  title: qsTr("Mosaic") },
        { key: "trio",    title: qsTr("Trio") },
        { key: "columns", title: qsTr("Columns") }
    ]
    readonly property var chosen: styles.find(s => s.key === Device.screensaver) || styles[0]

    Column {
        id: content
        width: parent.width
        spacing: options.gap

        Grid {
            columns: options.columns
            spacing: options.gap
            Repeater {
                model: options.styles
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property bool selected: Device.screensaver === modelData.key
                    objectName: "saverCard-" + modelData.key
                    width: options.cardWidth
                    height: options.cardHeight
                    radius: 24
                    color: selected ? Theme.accentSoft : Theme.surfaceAlt
                    border.width: selected ? 3 : 0
                    border.color: Theme.accent
                    scale: cardTap.pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.quick } }
                    Behavior on color { ColorAnimation { duration: Theme.quick } }

                    Rectangle {
                        id: badge
                        readonly property real side: options.small ? 48 : 64
                        x: options.small ? 16 : 22
                        y: x
                        width: side; height: side; radius: side / 2
                        color: card.selected ? Theme.accent : Theme.surface
                        Behavior on color { ColorAnimation { duration: Theme.quick } }
                        Icon { anchors.centerIn: parent; name: card.modelData.icon; size: options.small ? 24 : 30; color: card.selected ? Theme.accentInk : Theme.text }
                    }
                    Column {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: badge.x }
                        spacing: 4
                        Label {
                            width: parent.width
                            text: card.modelData.title
                            elide: Text.ElideRight
                            color: Theme.text
                            font.pixelSize: options.small ? Theme.fontSm : Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Label {
                            visible: !options.small
                            width: parent.width
                            text: card.modelData.body
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontXs + 1
                        }
                    }
                    TapHandler {
                        id: cardTap
                        gesturePolicy: TapHandler.WithinBounds
                        onTapped: Device.screensaver = card.modelData.key
                    }
                }
            }
        }

        // What the chosen style shows (the short cards have no room for it).
        Label {
            visible: options.small
            width: parent.width
            text: options.chosen.body
            elide: Text.ElideRight
            color: Theme.textMuted
            font.pixelSize: Theme.fontSm
        }

        // The collage's layouts: Auto takes the next one each time the
        // screen saver starts; the others stay put.
        Column {
            objectName: "collageLayouts"
            visible: Device.screensaver === "collage"
            width: parent.width
            spacing: 10
            Label {
                text: qsTr("LAYOUT")
                color: Theme.textMuted
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 1.5
            }
            Row {
                spacing: options.gap / 2
                Repeater {
                    model: options.layouts
                    delegate: Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool selected: Device.collageLayout === modelData.key
                        objectName: "layoutChip-" + modelData.key
                        readonly property var plan: modelData.key === "auto" ? null : Picks.layout(modelData.key, 99)
                        width: (options.width - options.gap / 2 * (options.layouts.length - 1)) / options.layouts.length
                        height: options.small ? 84 : 96
                        radius: 18
                        color: selected ? Theme.accentSoft : Theme.surfaceAlt
                        border.width: selected ? 3 : 0
                        border.color: Theme.accent
                        scale: chipTap.pressed ? 0.97 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.quick } }
                        Behavior on color { ColorAnimation { duration: Theme.quick } }

                        // A small picture of the layout.
                        Item {
                            id: thumb
                            readonly property real g: 2
                            width: 56
                            height: 34
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: options.small ? 12 : 16
                            Icon {
                                visible: chip.plan === null
                                anchors.centerIn: parent
                                name: "refresh"
                                size: 26
                                color: chip.selected ? Theme.accent : Theme.textMuted
                            }
                            Repeater {
                                model: chip.plan ? chip.plan.tiles : []
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property real cw: (thumb.width - thumb.g * (chip.plan.cols - 1)) / chip.plan.cols
                                    readonly property real ch: (thumb.height - thumb.g * (chip.plan.rows - 1)) / chip.plan.rows
                                    x: modelData.c * (cw + thumb.g)
                                    y: modelData.r * (ch + thumb.g)
                                    width: modelData.w * cw + (modelData.w - 1) * thumb.g
                                    height: modelData.h * ch + (modelData.h - 1) * thumb.g
                                    radius: 3
                                    color: chip.selected ? Theme.accent : Theme.textMuted
                                    opacity: chip.selected ? 0.9 : 0.55
                                }
                            }
                        }
                        Label {
                            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: options.small ? 10 : 12 }
                            width: parent.width - 12
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: chip.modelData.title
                            color: Theme.text
                            font.pixelSize: Theme.fontXs + 1
                            font.weight: chip.selected ? Font.DemiBold : Font.Normal
                        }
                        TapHandler {
                            id: chipTap
                            gesturePolicy: TapHandler.WithinBounds
                            onTapped: Device.collageLayout = chip.modelData.key
                        }
                    }
                }
            }
        }
    }
}
