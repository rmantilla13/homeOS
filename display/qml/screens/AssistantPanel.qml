import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Full-screen conversation with the family assistant.
Rectangle {
    id: panel
    property bool open: false
    property real keyboardHeight: 0
    signal closeRequested()

    color: Theme.background
    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220 } }

    function send(text) {
        if (!text || !text.trim()) return
        AI.ask(text)
        input.text = ""
    }
    function focusInput() { input.forceActiveFocus() }

    // Swallow taps so nothing underneath reacts.
    MouseArea { anchors.fill: parent }

    Glow {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: parent.height * 0.6
        intensity: messages.count === 0 ? 0.9 : 0.35
        Behavior on intensity { NumberAnimation { duration: 400 } }
        onIntensityChanged: requestPaint()
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
            onCountChanged: Qt.callLater(positionViewAtEnd)
            onHeightChanged: Qt.callLater(positionViewAtEnd)

            delegate: Item {
                id: row
                required property var modelData
                readonly property bool mine: modelData.role === "user"
                width: ListView.view.width
                height: bubble.height + (actionsCol.visible ? actionsCol.height + 8 : 0)

                Rectangle {
                    id: bubble
                    anchors.right: row.mine ? parent.right : undefined
                    anchors.left: row.mine ? undefined : parent.left
                    width: Math.min(text.implicitWidth + 44, row.width * 0.75)
                    height: text.implicitHeight + 32
                    radius: 26
                    color: row.mine ? Theme.accent : Theme.surface
                    Label {
                        id: text
                        anchors.fill: parent
                        anchors.margins: 16
                        anchors.leftMargin: 22
                        anchors.rightMargin: 22
                        text: row.modelData.text
                        wrapMode: Text.WordWrap
                        color: row.mine ? Theme.onAccent : Theme.text
                        font.pixelSize: Theme.fontMd - 2
                        lineHeight: 1.15
                    }
                }
                Column {
                    id: actionsCol
                    visible: (row.modelData.actions || []).length > 0
                    anchors.top: bubble.bottom
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    spacing: 6
                    Repeater {
                        model: row.modelData.actions || []
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
            }

            footer: Item {
                width: messages.width
                height: AI.busy ? 72 : 0
                Rectangle {
                    visible: AI.busy
                    y: 14
                    width: 96; height: 54; radius: 27
                    color: Theme.surface
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Repeater {
                            model: 3
                            delegate: Rectangle {
                                required property int index
                                width: 10; height: 10; radius: 5
                                color: Theme.textMuted
                                SequentialAnimation on opacity {
                                    running: AI.busy
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
            border.color: input.activeFocus ? Theme.accent : Theme.divider
            border.width: input.activeFocus ? 2 : 1

            TextField {
                id: input
                anchors.left: parent.left
                anchors.right: buttons.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 24
                anchors.rightMargin: 8
                placeholderText: qsTr("Ask homeOS anything")
                font.pixelSize: Theme.fontMd - 2
                color: Theme.text
                placeholderTextColor: Theme.textMuted
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
                IconButton {
                    width: 60; height: 60
                    icon: "mic"
                    fill: Theme.surfaceAlt
                    ink: Theme.text
                    // TODO(M3): speech-to-text (local whisper.cpp on the Pi or cloud).
                    onClicked: Store.notify(qsTr("Voice is coming soon. Type for now."))
                }
                IconButton {
                    width: 60; height: 60
                    icon: "send"
                    fill: Theme.accent
                    ink: Theme.onAccent
                    enabled: input.text.trim().length > 0 && !AI.busy
                    onClicked: panel.send(input.text)
                }
            }
        }
    }
}
