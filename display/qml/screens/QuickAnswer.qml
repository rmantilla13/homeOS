import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import HomeOS
import HomeOS.Core

// The wake-word card: floats bottom-centre over any screen, including the
// screen saver. It listens, shows what it heard, streams a short answer,
// reads it out, then gets out of the way 6 s after it finishes speaking.
// Tapping outside dismisses it and stops the speech.
Item {
    id: quick
    signal openChat()

    // hidden | listening | thinking | answering | done | missed
    property string phase: "hidden"
    readonly property bool shown: phase !== "hidden"
    property string question: ""
    property bool awaitingSpeech: false

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

    // Voice.woke: a new turn starts (also restarts an open card).
    function start() {
        dismissTimer.stop()
        speechTimer.stop()
        question = ""
        awaitingSpeech = false
        phase = "listening"
        stallTimer.restart()
        dropPendingAnswer()
    }
    // Voice.heard: ask the assistant for a quick answer.
    function hear(text) {
        question = text
        phase = "thinking"
        stallTimer.stop()
        AI.askQuick(text)
    }
    // Voice.heardNothing (or the service went away mid-turn).
    function miss() {
        phase = "missed"
        stallTimer.stop()
        dismissIn(2600)
    }
    function dismiss(stopSpeech) {
        if (!shown)
            return
        if (stopSpeech) {
            if (phase === "listening")
                Voice.cancel()
            Voice.stopSpeaking()
        }
        phase = "hidden"
        awaitingSpeech = false
        dismissTimer.stop()
        speechTimer.stop()
        stallTimer.stop()
        if (stopSpeech)
            dropPendingAnswer()
    }
    // A quick answer still on its way belongs to a question this card no
    // longer shows: stop it so it neither lands here nor gets read out.
    // (Called once the phase has moved on, so its last update is ignored.)
    function dropPendingAnswer() {
        if (AI.busy && AI.replyMode === "quick")
            AI.stop()
    }
    function quoted(text) {
        return "“" + text.charAt(0).toUpperCase() + text.slice(1) + "”"
    }
    function dismissIn(ms) {
        dismissTimer.interval = ms
        dismissTimer.restart()
    }

    Timer { id: dismissTimer; onTriggered: quick.dismiss(false) }
    // If `spoken` never comes (speech failed), don't hang around forever.
    Timer { id: speechTimer; onTriggered: { quick.awaitingSpeech = false; quick.dismissIn(6000) } }
    // The service ends a turn within ~12 s; give up quietly if it doesn't.
    Timer { id: stallTimer; interval: 20000; onTriggered: if (quick.phase === "listening") quick.miss() }

    Connections {
        target: AI
        enabled: quick.shown
        function onReplyChanged() {
            if (quick.phase === "thinking" && AI.busy && AI.replyMode === "quick"
                    && (AI.replyText.length > 0 || AI.replyActions.length > 0))
                quick.phase = "answering"
        }
        function onReplyFinished(text, actions, mode, speechId) {
            if (mode !== "quick" || (quick.phase !== "thinking" && quick.phase !== "answering"))
                return
            quick.phase = "done"
            if (speechId) {
                quick.awaitingSpeech = true
                speechTimer.interval = 10000 + text.length * 90
                speechTimer.restart()
            } else {
                // Nothing to listen to: leave it up long enough to read.
                quick.dismissIn(6000 + Math.min(text.length * 45, 9000))
            }
        }
    }
    Connections {
        target: Voice
        enabled: quick.shown
        function onSpoken(id) {
            if (!quick.awaitingSpeech)
                return
            quick.awaitingSpeech = false
            speechTimer.stop()
            quick.dismissIn(6000)
        }
        function onAvailableChanged() {
            if (!Voice.available && quick.phase === "listening")
                quick.miss()
        }
    }

    readonly property string orbMode: phase === "listening" ? (Voice.state === "listening" ? "listening" : "thinking")
                                    : phase === "thinking" || phase === "answering" ? "thinking"
                                    : Voice.state === "speaking" ? "speaking" : "idle"
    readonly property string stateLabel: phase === "listening" ? (Voice.state === "transcribing" ? qsTr("Thinking…") : qsTr("Listening…"))
                                       : phase === "thinking" ? qsTr("Thinking…")
                                       : phase === "done" && Voice.state === "speaking" ? qsTr("Speaking…")
                                       : ""

    // Shade toward the card so it reads over busy photos; taps here dismiss.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.05) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.38) }
        }
        MouseArea { anchors.fill: parent; onClicked: quick.dismiss(true) }
    }

    Item {
        id: cardArea
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.compact ? 32 : 48
        width: Math.min(parent.width - 2 * Theme.pageMargin, Theme.compact ? 760 : 880)
        height: Math.max(body.implicitHeight, orbHolder.height - 24) + 2 * pad
        readonly property int pad: Theme.compact ? 24 : 32
        Behavior on height { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

        transform: Translate {
            y: quick.shown ? 0 : 60
            Behavior on y { NumberAnimation { duration: Theme.smooth + 80; easing.type: Easing.OutCubic } }
        }
        scale: quick.shown ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: Theme.smooth + 80; easing.type: Easing.OutCubic } }

        RectangularGlow {
            anchors.fill: card
            glowRadius: 28
            spread: 0.1
            cornerRadius: card.radius + glowRadius
            color: Qt.rgba(0, 0, 0, Theme.dark ? 0.5 : 0.22)
        }

        Rectangle {
            id: card
            anchors.fill: parent
            radius: 36
            color: Theme.surface

            // Taps on the card itself don't dismiss it.
            MouseArea { anchors.fill: parent }

            Item {
                id: orbHolder
                x: cardArea.pad - 12
                y: cardArea.pad - 12
                width: Theme.compact ? 116 : 132
                height: width
                VoiceOrb {
                    anchors.centerIn: parent
                    size: parent.width
                    level: Voice.level
                    mode: quick.orbMode
                }
            }

            ColumnLayout {
                id: body
                anchors.left: orbHolder.right
                anchors.leftMargin: 18
                anchors.right: parent.right
                anchors.rightMargin: cardArea.pad
                // Centred on the orb while short; grows downward from there.
                y: cardArea.pad + Math.max(0, (orbHolder.height - 24 - implicitHeight) / 2)
                spacing: 10

                Label {
                    Layout.fillWidth: true
                    Layout.rightMargin: corner.width // clear of the buttons
                    visible: text.length > 0
                    text: quick.stateLabel.toUpperCase()
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                // What was heard: the live transcript, then the question.
                Label {
                    Layout.fillWidth: true
                    Layout.rightMargin: corner.width
                    visible: text.length > 0
                    text: quick.phase === "missed" ? qsTr("Sorry, I didn't catch that")
                        : quick.question ? quick.quoted(quick.question)
                        : Voice.transcript ? quick.quoted(Voice.transcript)
                        : Voice.state === "listening" ? qsTr("Ask about today, dinner, chores…")
                        : ""
                    color: quick.question || quick.phase === "missed" || Voice.transcript ? Theme.text : Theme.textMuted
                    font.pixelSize: quick.question ? Theme.fontMd : Theme.fontLg
                    font.weight: quick.phase === "missed" ? Font.Medium : Font.Normal
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                // The answer, as it streams.
                Label {
                    id: answer
                    Layout.fillWidth: true
                    visible: quick.phase === "answering" || quick.phase === "done"
                    text: AI.replyText
                    color: Theme.text
                    font.pixelSize: Theme.compact ? Theme.fontLg - 2 : Theme.fontLg
                    font.weight: Font.Medium
                    lineHeight: 1.12
                    wrapMode: Text.WordWrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                }

                Flow {
                    Layout.fillWidth: true
                    visible: answer.visible && AI.replyActions.length > 0
                    spacing: 8
                    Repeater {
                        model: answer.visible ? AI.replyActions : []
                        delegate: Rectangle {
                            required property var modelData
                            width: chipLabel.implicitWidth + 56
                            height: 40
                            radius: 20
                            color: Qt.rgba(0.24, 0.70, 0.48, 0.16)
                            Icon { x: 14; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 18; color: Theme.success }
                            Label {
                                id: chipLabel
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

            // Top right: back to the full chat, and close.
            Row {
                id: corner
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 16
                spacing: 10
                PillButton {
                    visible: quick.phase === "answering" || quick.phase === "done"
                    text: qsTr("Open chat")
                    fill: Theme.accentSoft
                    ink: Theme.accent
                    implicitHeight: 48
                    implicitWidth: contentItem.implicitWidth + 44
                    onClicked: quick.openChat()
                }
                IconButton {
                    width: 48
                    height: 48
                    icon: "close"
                    iconSize: 20
                    fill: Theme.surfaceAlt
                    ink: Theme.textMuted
                    onClicked: quick.dismiss(true)
                }
            }
        }
    }
}
