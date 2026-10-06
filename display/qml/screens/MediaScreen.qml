import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Family photos and videos: a featured photo, then everything grouped by
// month. Tap any item to open the full-screen viewer.
Item {
    id: media
    signal openViewer(var items, int index)

    property int filter: 0   // 0 all, 1 photos, 2 videos
    readonly property var items: Store.media.filter(m => filter === 0 || (filter === 1 ? m.kind === "photo" : m.kind === "video"))
    readonly property var featured: filter !== 2 ? Store.media.find(m => m.kind === "photo") : null
    readonly property int photoCount: Store.media.filter(m => m.kind === "photo").length
    readonly property int videoCount: Store.media.length - photoCount
    readonly property int columns: Theme.compact ? 4 : 5
    // [{ title, entries: [{ item, index }] }], newest month first.
    readonly property var groups: {
        const out = []
        items.forEach((m, i) => {
            let g = out.length ? out[out.length - 1] : null
            if (!g || g.title !== m.monthLabel) { g = { title: m.monthLabel, entries: [] }; out.push(g) }
            g.entries.push({ item: m, index: i })
        })
        return out
    }

    ScreenSaverPicker { id: saverPicker }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing - 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Column {
                Layout.fillWidth: true
                Label { text: qsTr("Media"); color: Theme.text; font.pixelSize: Theme.compact ? 34 : Theme.fontXl; font.weight: Font.Medium }
                Label {
                    text: qsTr("%1 photos · %2 videos").arg(media.photoCount).arg(media.videoCount)
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSm
                }
            }
            SegmentedControl {
                options: [qsTr("All"), qsTr("Photos"), qsTr("Videos")]
                currentIndex: media.filter
                onSelected: index => media.filter = index
            }
            PillButton {
                text: qsTr("Screen saver")
                onClicked: saverPicker.open()
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 22
            model: media.groups
            boundsBehavior: Flickable.DragOverBounds

            header: Item {
                width: list.width
                height: media.featured ? hero.height + 22 : 0
                visible: media.featured !== null

                // Featured: the newest photo, tinted with its own colors.
                Rectangle {
                    id: hero
                    width: parent.width
                    height: Theme.compact ? 280 : 360
                    radius: Theme.radius
                    color: media.featured ? media.featured.tintDeep : Theme.surface
                    Behavior on color { ColorAnimation { duration: Theme.quick } }

                    PhotoTile {
                        anchors.fill: parent
                        radius: Theme.radius
                        photo: media.featured
                        showCaption: false
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius
                        gradient: Gradient {
                            GradientStop { position: 0.35; color: "transparent" }
                            GradientStop { position: 1.0; color: media.featured ? Qt.rgba(Qt.darker(media.featured.tint, 2.4).r, Qt.darker(media.featured.tint, 2.4).g, Qt.darker(media.featured.tint, 2.4).b, 0.85) : "transparent" }
                        }
                    }
                    Column {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: 28
                        spacing: 8
                        Tag {
                            text: qsTr("Latest")
                            tint: Qt.rgba(1, 1, 1, 0.85)
                            ink: media.featured ? Qt.darker(media.featured.tint, 1.8) : Theme.text
                        }
                        Label {
                            text: media.featured ? media.featured.caption : ""
                            color: "white"
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.DemiBold
                        }
                        Label {
                            text: media.featured ? media.featured.dateLabel + (media.featured.uploaderName ? " · " + qsTr("added by %1").arg(media.featured.uploaderName) : "") : ""
                            color: Qt.rgba(1, 1, 1, 0.85)
                            font.pixelSize: Theme.fontSm
                        }
                    }
                    TapHandler { onTapped: { const all = Store.media; media.openViewer(all, Math.max(0, all.findIndex(m => m.url === media.featured.url))) } }
                }
            }

            delegate: Column {
                id: group
                required property var modelData
                width: list.width
                spacing: 12

                Label {
                    text: group.modelData.title
                    color: Theme.text
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                }
                Grid {
                    columns: media.columns
                    spacing: 12
                    readonly property real cell: (group.width - spacing * (columns - 1)) / columns
                    Repeater {
                        model: group.modelData.entries
                        delegate: Item {
                            id: cellItem
                            required property var modelData
                            width: parent.cell
                            height: parent.cell * 0.78
                            scale: cellTap.pressed ? 0.96 : 1
                            Behavior on scale { NumberAnimation { duration: Theme.quick } }

                            PhotoTile {
                                anchors.fill: parent
                                radius: Theme.radiusSm
                                photo: cellItem.modelData.item
                                showCaption: false
                            }
                            // Video badge: play button and duration.
                            Rectangle {
                                visible: cellItem.modelData.item.kind === "video"
                                anchors.centerIn: parent
                                width: 56; height: 56; radius: 28
                                color: Qt.rgba(0, 0, 0, 0.35)
                                Icon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; name: "play"; color: "white"; size: 26 }
                            }
                            Rectangle {
                                visible: cellItem.modelData.item.kind === "video" && cellItem.modelData.item.durationLabel !== ""
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 10
                                width: durLabel.implicitWidth + 16; height: 26; radius: 13
                                color: Qt.rgba(0, 0, 0, 0.45)
                                Label { id: durLabel; anchors.centerIn: parent; text: cellItem.modelData.item.durationLabel; color: "white"; font.pixelSize: 13; font.weight: Font.DemiBold }
                            }
                            TapHandler { id: cellTap; onTapped: media.openViewer(media.items, cellItem.modelData.index) }
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: media.items.length === 0
                text: qsTr("Nothing here yet. Add photos and videos from the Ohana iPhone app.")
                color: Theme.textMuted
                font.pixelSize: Theme.fontMd
            }
        }
    }
}
