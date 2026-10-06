import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Kids pick themselves, see their points, and spend them on rewards.
Item {
    id: rewardsScreen
    readonly property var kids: Store.members.filter(m => m.role === "child")
    property string selectedId: ""
    readonly property var selected: kids.find(k => k.id === selectedId) || kids[0] || null
    property var pendingReward: null

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: 24
            Label {
                text: qsTr("Rewards")
                color: Theme.text
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Repeater {
                model: rewardsScreen.kids
                delegate: Column {
                    required property var modelData
                    spacing: 6
                    MemberAvatar {
                        anchors.horizontalCenter: parent.horizontalCenter
                        member: modelData
                        size: Theme.compact ? 64 : 88
                        selected: rewardsScreen.selected && rewardsScreen.selected.id === modelData.id
                        TapHandler { onTapped: rewardsScreen.selectedId = modelData.id }
                    }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.display_name; color: Theme.text; font.pixelSize: Theme.fontSm }
                }
            }
        }

        // Balance banner.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.compact ? 100 : 150
            radius: Theme.radius
            color: rewardsScreen.selected ? rewardsScreen.selected.color : Theme.accent
            visible: rewardsScreen.selected !== null
            RowLayout {
                anchors.fill: parent
                anchors.margins: Theme.compact ? 16 : 32
                anchors.leftMargin: 32
                anchors.rightMargin: 32
                Label {
                    text: rewardsScreen.selected ? rewardsScreen.selected.display_name + qsTr(" has") : ""
                    color: "white"
                    font.pixelSize: Theme.fontLg
                    Layout.fillWidth: true
                }
                Label {
                    text: "★ " + (rewardsScreen.selected ? rewardsScreen.selected.points : 0)
                    color: "white"
                    font.pixelSize: Theme.compact ? 60 : 80
                    font.weight: Font.Bold
                }
            }
        }

        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: width / 3
            cellHeight: Theme.compact ? 220 : 260
            model: Store.rewards
            delegate: Item {
                id: rewardCell
                required property var modelData
                readonly property int balance: rewardsScreen.selected ? rewardsScreen.selected.points : 0
                readonly property bool affordable: balance >= modelData.cost
                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 12
                    radius: Theme.radius
                    color: Theme.surface
                    opacity: rewardCell.affordable ? 1 : 0.7
                    scale: rewardTap.pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: 90 } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 24
                        spacing: 8
                        Label { text: rewardCell.modelData.icon || "🎁"; font.family: Theme.emojiFont; font.pixelSize: 56 }
                        Label { text: rewardCell.modelData.title; color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                        Item { Layout.fillHeight: true }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "★ " + rewardCell.modelData.cost; color: Theme.text; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            Label {
                                text: rewardCell.affordable ? qsTr("Tap to redeem") : (rewardCell.modelData.cost - rewardCell.balance) + qsTr(" to go")
                                color: rewardCell.affordable ? Theme.success : Theme.textMuted
                                font.pixelSize: Theme.fontXs
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 10; radius: 5
                            color: Theme.surfaceAlt
                            Rectangle {
                                height: parent.height; radius: 5
                                width: parent.width * Math.min(1, rewardCell.balance / rewardCell.modelData.cost)
                                color: rewardCell.affordable ? Theme.success : Theme.warning
                            }
                        }
                    }
                    TapHandler {
                        id: rewardTap
                        enabled: rewardCell.affordable
                        onTapped: { rewardsScreen.pendingReward = rewardCell.modelData; confirm.open() }
                    }
                }
            }
        }
    }

    Dialog {
        id: confirm
        anchors.centerIn: parent
        modal: true
        width: 720
        padding: 40
        background: Rectangle { radius: Theme.radius; color: Theme.surface }
        contentItem: ColumnLayout {
            spacing: 24
            Label {
                text: rewardsScreen.pendingReward ? (rewardsScreen.pendingReward.icon || "🎁") : ""
                font.family: Theme.emojiFont
                font.pixelSize: 80
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: rewardsScreen.pendingReward && rewardsScreen.selected
                      ? qsTr("Spend %1 points on “%2”?").arg(rewardsScreen.pendingReward.cost).arg(rewardsScreen.pendingReward.title)
                      : ""
                color: Theme.text
                font.pixelSize: Theme.fontLg
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 24
                PillButton { text: qsTr("Not now"); fill: Theme.surfaceAlt; ink: Theme.text; onClicked: confirm.close() }
                PillButton {
                    text: qsTr("Yes, redeem!")
                    fill: Theme.success
                    onClicked: {
                        Store.redeemReward(rewardsScreen.pendingReward.id, rewardsScreen.selected.id)
                        confirm.close()
                    }
                }
            }
        }
    }
}
