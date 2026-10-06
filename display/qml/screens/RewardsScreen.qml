import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Kids pick themselves, see their points, and spend them on rewards.
// Plus adds a reward to the family catalog.
Item {
    id: rewardsScreen
    readonly property var kids: Store.members.filter(m => m.role === "child")
    property string selectedId: ""
    readonly property var selected: kids.find(k => k.id === selectedId) || kids[0] || null
    property var pendingReward: null
    // On screen and not covered (set by Main.qml); the balance tile only
    // animates while it is.
    property bool shown: true
    readonly property var rewardIcons: ["🎁", "🍦", "🎮", "📺", "🍕", "🎬", "🛝", "🧁", "⏰", "📱"]
    property string draftIcon: "🎁"
    property int draftCost: 50

    function openAdd() {
        draftIcon = rewardIcons[0]
        draftCost = 50
        rewardTitle.text = ""
        addReward.open()
        rewardTitle.forceActiveFocus()
    }
    function submitReward() {
        Qt.inputMethod.commit()
        const title = rewardTitle.text.trim()
        if (!title.length || draftCost <= 0) return
        Store.addReward(title, draftIcon, draftCost)
        addReward.close()
    }

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
            IconButton {
                icon: "plus"
                fill: Theme.accent
                ink: Theme.accentInk
                onClicked: rewardsScreen.openAdd()
            }
        }

        // Balance banner, on the selected kid's gradient.
        GradientTile {
            id: balance
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.compact ? 120 : 150
            radius: Theme.radius
            baseColor: rewardsScreen.selected ? rewardsScreen.selected.color : Theme.accent
            visible: rewardsScreen.selected !== null
            active: rewardsScreen.shown
            seed: 3.1
            ringBias: 0.70
            RowLayout {
                anchors.fill: parent
                anchors.margins: Theme.compact ? 16 : 32
                anchors.leftMargin: 32
                anchors.rightMargin: 32
                Label {
                    text: rewardsScreen.selected ? rewardsScreen.selected.display_name + qsTr(" has") : ""
                    color: balance.ink
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.Medium
                    Layout.fillWidth: true
                }
                AnimatedNumber {
                    value: rewardsScreen.selected ? rewardsScreen.selected.points : 0
                    prefix: "★ "
                    color: balance.ink
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
                    Behavior on scale { NumberAnimation { duration: Theme.quick } }

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

    FormDialog {
        id: addReward
        titleText: qsTr("New reward")
        canSubmit: rewardTitle.text.trim().length > 0 && rewardsScreen.draftCost > 0
        onSubmitted: rewardsScreen.submitReward()

        FormField {
            id: rewardTitle
            placeholderText: qsTr("Reward")
            onAccepted: addReward.requestSubmit()
        }
        Flow {
            Layout.fillWidth: true
            spacing: 10
            Repeater {
                model: rewardsScreen.rewardIcons
                delegate: Rectangle {
                    required property string modelData
                    width: 56; height: 56; radius: 28
                    color: rewardsScreen.draftIcon === modelData ? Theme.accentSoft : Theme.surfaceAlt
                    border.width: rewardsScreen.draftIcon === modelData ? 2 : 0
                    border.color: Theme.accent
                    Label {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: Theme.emojiFont
                        font.pixelSize: 28
                    }
                    TapHandler { onTapped: rewardsScreen.draftIcon = modelData }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Label {
                text: qsTr("Costs %1 points").arg(rewardsScreen.draftCost)
                color: Theme.text
                font.pixelSize: Theme.fontSm
                Layout.fillWidth: true
            }
            IconButton {
                icon: "left"
                enabled: rewardsScreen.draftCost > 5
                onClicked: rewardsScreen.draftCost = Math.max(5, rewardsScreen.draftCost - 5)
            }
            IconButton {
                icon: "right"
                enabled: rewardsScreen.draftCost < 1000
                onClicked: rewardsScreen.draftCost = Math.min(1000, rewardsScreen.draftCost + 5)
            }
        }
    }
}
