import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Full-screen conversation with the family assistant. Replies stream in word
// by word; the mic is push-to-talk through the voice service.
Rectangle {
    id: panel
    property bool open: false
    property real keyboardHeight: 0
    // Push-to-talk is feeding this conversation (set by Main).
    property bool listening: false
    signal closeRequested()
    signal pushToTalk()

    color: Theme.background
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    transform: Translate {
        y: panel.open ? 0 : 40
        Behavior on y { NumberAnimation { duration: Theme.smooth + 60; easing.type: Easing.OutCubic } }
    }

    function send(text) {
        // While a reply streams the message would be dropped: keep it typed.
        if (!text || !text.trim() || AI.busy) return
        AI.ask(text)
        input.text = ""
    }
    function focusInput() { input.forceActiveFocus() }

    // Swallow taps so nothing underneath reacts.
    MouseArea { anchors.fill: parent }

    // Glow behind the empty state; fades out once the conversation starts.
    Glow {
        anchors.fill: parent
        anchors.topMargin: parent.height * 0.3
        opacity: messages.count === 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.pageMargin
        anchors.rightMargin: Theme.pageMargin
        anchors.topMargin: Theme.pageMargin
        anchors.bottomMargin: Theme.pageMargin + panel.keyboardHeight
        spacing: 16

        // Header.
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Rectangle {
                width: 52; height: 52; radius: 26
                color: Theme.accentSoft
                Icon { anchors.centerIn: parent; name: "sparkle"; color: Theme.accent; size: 26 }
            }
            Column {
                Layout.fillWidth: true
                Label { text: qsTr("homeOS Assistant"); color: Theme.text; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold }
                Label {
                    text: Store.mode === "live" ? qsTr("Knows your family's calendar, chores, meals and lists")
                                                : qsTr("Demo mode · answers from sample data")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs
                }
            }
            PillButton {
                visible: messages.count > 0
                text: qsTr("New chat")
                fill: Theme.surface
                ink: Theme.text
                onClicked: AI.reset()
            }
            IconButton { icon: "close"; onClicked: panel.closeRequested() }
        }

        // Conversation.
        ListView {
            id: messages
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 14
            model: AI.messages
            boundsBehavior: Flickable.StopAtBounds

            // Stay pinned to the newest text while a reply grows, unless
            // someone scrolls up to read.
            property bool follow: true
            onMovementEnded: follow = atYEnd
            onCountChanged: { follow = true; Qt.callLater(positionViewAtEnd) }
            onContentHeightChanged: if (follow) Qt.callLater(positionViewAtEnd)
            onHeightChanged: if (follow) Qt.callLater(positionViewAtEnd)

            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.smooth }
                    NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: Theme.smooth; easing.type: Easing.OutBack }
                }
            }

            delegate: Item {
                id: row
                required property string role
                required property string text
                required property var actions
                required property bool streaming
                required property bool failed
                readonly property bool mine: role === "user"
                readonly property bool typing: streaming && text.length === 0
                width: ListView.view.width
                height: bubble.height + (actionsCol.visible ? actionsCol.height + 8 : 0)
                        + (failedNote.visible ? failedNote.height + 6 : 0)

                Rectangle {
                    id: bubble
                    anchors.right: row.mine ? parent.right : undefined
                    anchors.left: row.mine ? undefined : parent.left
                    width: row.typing ? 96 : Math.min(bubbleText.implicitWidth + 44, row.width * 0.75)
                    height: row.typing ? 54 : bubbleText.implicitHeight + 32
                    radius: row.typing ? 27 : 26
                    color: row.mine ? Theme.accent : Theme.surface

                    Label {
                        id: bubbleText
                        visible: !row.typing
                        // Width only: the bubble's height follows the text, not the reverse.
                        x: 22
                        y: 16
                        width: bubble.width - 44
                        text: row.text
                        wrapMode: Text.WordWrap
                        color: row.mine ? Theme.accentInk : Theme.text
                        font.pixelSize: Theme.fontMd - 2
                        lineHeight: 1.15
                    }

                    // Typing dots until the first words arrive.
                    Row {
                        visible: row.typing
                        anchors.centerIn: parent
                        spacing: 8
                        Repeater {
                            model: 3
                            delegate: Rectangle {
                                required property int index
                                width: 10; height: 10; radius: 5
                                color: Theme.textMuted
                                SequentialAnimation on opacity {
                                    running: row.typing
                                    loops: Animation.Infinite
                                    PauseAnimation { duration: index * 160 }
                                    NumberAnimation { from: 0.3; to: 1; duration: 320 }
                                    NumberAnimation { from: 1; to: 0.3; duration: 320 }
                                    PauseAnimation { duration: (2 - index) * 160 }
                                }
                            }
                        }
                    }
                }
                Column {
                    id: actionsCol
                    visible: (row.actions || []).length > 0
                    anchors.top: bubble.bottom
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    spacing: 6
                    Repeater {
                        model: row.actions || []
                        delegate: Rectangle {
                            required property var modelData
                            width: actionLabel.implicitWidth + 56
                            height: 40
                            radius: 20
                            color: Qt.rgba(0.24, 0.70, 0.48, 0.16)
                            Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 18; color: Theme.success }
                            Label {
                                id: actionLabel
                                x: 40
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.summary
                                color: Theme.text
                                font.pixelSize: Theme.fontXs
                            }
                        }
                    }
                }
                Label {
                    id: failedNote
                    visible: row.failed
                    anchors.top: actionsCol.visible ? actionsCol.bottom : bubble.bottom
                    anchors.topMargin: 6
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    text: qsTr("The answer was cut short. Try asking again.")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs
                }
            }

            // Empty state: greeting and suggestions.
            Column {
                anchors.centerIn: parent
                width: parent.width * 0.8
                spacing: 22
                visible: messages.count === 0
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("How can I help you today?")
                    color: Theme.text
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Medium
                    wrapMode: Text.WordWrap
                }
                Flow {
                    width: parent.width
                    spacing: 10
                    Repeater {
                        model: AI.suggestions
                        delegate: Rectangle {
                            required property string modelData
                            width: sLabel.implicitWidth + 36
                            height: 52
                            radius: 26
                            color: Theme.surface
                            border.color: Theme.divider
                            Label { id: sLabel; anchors.centerIn: parent; text: modelData; color: Theme.text; font.pixelSize: Theme.fontSm - 1 }
                            TapHandler { onTapped: panel.send(modelData) }
                        }
                    }
                }
            }
        }

        // Input bar.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            radius: height / 2
            color: Theme.surface
            border.color: input.activeFocus || panel.listening ? Theme.accent : Theme.divider
            border.width: input.activeFocus || panel.listening ? 2 : 1

            TextField {
                id: input
                anchors.left: parent.left
                anchors.right: buttons.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 24
                anchors.rightMargin: 8
                placeholderText: !panel.listening ? qsTr("Ask homeOS anything")
                               : Voice.state === "listening" ? qsTr("Listening… tap the mic to stop")
                               : qsTr("Thinking…")
                font.pixelSize: Theme.fontMd - 2
                color: Theme.text
                placeholderTextColor: panel.listening ? Theme.accent : Theme.textMuted
                background: null
                inputMethodHints: Qt.ImhNoPredictiveText
                onAccepted: panel.send(text)
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Item {
                    width: 60; height: 60
                    // Ring that swells with the voice while listening.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width; height: width; radius: width / 2
                        color: Theme.accent
                        opacity: panel.listening ? 0.25 : 0
                        scale: 1 + (panel.listening ? Math.min(1, Voice.level * 1.6) * 0.45 : 0)
                        Behavior on scale { NumberAnimation { duration: 110 } }
                        Behavior on opacity { NumberAnimation { duration: Theme.quick } }
                    }
                    IconButton {
                        anchors.fill: parent
                        icon: Voice.available ? "mic" : "mic-off"
                        fill: panel.listening ? Theme.accent : Theme.surfaceAlt
                        ink: panel.listening ? Theme.accentInk : Voice.available ? Theme.text : Theme.textMuted
                        Behavior on fill { ColorAnimation { duration: Theme.quick } }
                        onClicked: panel.pushToTalk()
                    }
                }
                IconButton {
                    width: 60; height: 60
                    icon: "send"
                    fill: Theme.accent
                    ink: Theme.accentInk
                    enabled: input.text.trim().length > 0 && !AI.busy
                    onClicked: panel.send(input.text)
                }
            }
        }
    }
}
