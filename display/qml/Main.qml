import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

ApplicationWindow {
    id: window
    // Fill the panel; in a window, start at the 10.1" panel's logical size.
    width: startWindowed ? 1280 : Screen.width
    height: startWindowed ? 800 : Screen.height
    visible: true
    visibility: startWindowed ? Window.Windowed : Window.FullScreen
    title: "homeOS"
    color: Theme.background
    font.family: Theme.fontFamily

    property int currentScreen: 0
    readonly property real keyboardHeight: keyboard.item ? keyboard.item.visibleHeight : 0
    // "chat" while push-to-talk is feeding the assistant panel; wake-word
    // turns go to the quick answer card instead.
    property string voiceTarget: ""

    function showToast(message) {
        toastLabel.text = message
        toastAnim.restart()
    }

    // Push-to-talk from the assistant panel or the Home card. A second tap stops it.
    function pushToTalk() {
        if (!Voice.available) {
            showToast(qsTr("Voice needs the homeOS voice service (see docs/VOICE.md)"))
            return false
        }
        if (voiceTarget === "chat") {
            Voice.cancel()
            voiceTarget = ""
            return true
        }
        // No microphone or speech-to-text: the service would refuse `listen`
        // and the mic would look stuck on until the watchdog.
        if (!Voice.canTranscribe) {
            showToast(qsTr("Voice needs a microphone (see docs/VOICE.md)"))
            return false
        }
        dismissKeyboard()
        Voice.stopSpeaking()
        voiceTarget = "chat"
        pttWatchdog.restart()
        Voice.listen()
        return true
    }
    // The service ends a turn within ~12 s; never leave the mic stuck "on".
    Timer { id: pttWatchdog; interval: 25000; onTriggered: window.voiceTarget = "" }

    // Leaving a screen or going idle closes the on-screen keyboard.
    function dismissKeyboard() {
        window.contentItem.forceActiveFocus()
        Qt.inputMethod.hide()
    }
    onCurrentScreenChanged: dismissKeyboard()

    Binding { target: Theme; property: "compact"; value: window.width < 1600 }

    // Drop back to the home screen after the photo frame has been up.
    Connections {
        target: Device
        function onIdleChanged() {
            if (Device.idle) {
                window.dismissKeyboard()
                assistant.open = false
                viewer.close()
                settings.close()
                window.currentScreen = 0
            }
        }
    }

    // Re-pairing (or a lost session) starts over behind the pairing screen.
    Connections {
        target: Store
        function onModeChanged() {
            if (Store.mode === "pairing") {
                assistant.open = false
                quick.dismiss(true)
                settings.close()
            }
        }
    }

    // Voice: wake word -> quick answer card; push-to-talk -> the chat.
    Connections {
        target: Voice
        function onWoke(source) {
            if (window.voiceTarget === "chat" || Store.mode === "pairing")
                return
            Device.wake()
            window.dismissKeyboard()
            settings.close()
            quick.start()
        }
        function onHeard(text) {
            if (window.voiceTarget === "chat") {
                window.voiceTarget = ""
                pttWatchdog.stop()
                // Speaking wins over a reply still streaming, as with the
                // wake word; otherwise ask() would drop what was said.
                if (AI.busy)
                    AI.stop()
                AI.ask(text)
            } else if (quick.phase === "listening") {
                quick.hear(text)
            }
        }
        function onHeardNothing() {
            if (window.voiceTarget === "chat") {
                window.voiceTarget = ""
                pttWatchdog.stop()
                window.showToast(qsTr("Sorry, I didn't catch that"))
            } else if (quick.phase === "listening") {
                quick.miss()
            }
        }
        function onAvailableChanged() {
            if (!Voice.available)
                window.voiceTarget = ""
        }
        function onErrorOccurred(message) { window.showToast(message) }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        visible: Store.mode !== "pairing"

        NavRail {
            Layout.fillHeight: true
            Layout.preferredWidth: Theme.navWidth
            currentIndex: window.currentScreen
            onSelected: index => { assistant.open = false; window.dismissKeyboard(); window.currentScreen = index }
            onSettingsRequested: { window.dismissKeyboard(); settings.open() }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Page {
                anchors.fill: parent; index: 0; current: window.currentScreen
                HomeScreen {
                    anchors.fill: parent
                    shown: window.currentScreen === 0 && !assistant.open
                    onOpenScreen: index => window.currentScreen = index
                    onOpenAssistant: question => {
                        assistant.open = true
                        if (question) AI.ask(question)
                        else assistant.focusInput()
                    }
                    onPushToTalk: {
                        assistant.open = true
                        if (!window.pushToTalk())
                            assistant.focusInput() // no voice service: type instead
                    }
                }
            }
            Page { anchors.fill: parent; index: 1; current: window.currentScreen; CalendarScreen { anchors.fill: parent } }
            Page { anchors.fill: parent; index: 2; current: window.currentScreen; TasksScreen { anchors.fill: parent } }
            Page {
                anchors.fill: parent; index: 3; current: window.currentScreen
                RewardsScreen { anchors.fill: parent; shown: window.currentScreen === 3 && !assistant.open }
            }
            Page {
                anchors.fill: parent; index: 4; current: window.currentScreen
                MediaScreen { anchors.fill: parent; onOpenViewer: (items, i) => viewer.show(items, i) }
            }
            Page { anchors.fill: parent; index: 5; current: window.currentScreen; PlannerScreen { anchors.fill: parent } }
        }
    }

    AssistantPanel {
        id: assistant
        anchors.fill: parent
        anchors.leftMargin: Theme.navWidth
        keyboardHeight: window.keyboardHeight
        listening: window.voiceTarget === "chat"
        onCloseRequested: {
            window.dismissKeyboard()
            if (window.voiceTarget === "chat") window.pushToTalk() // stop listening
            open = false
        }
        onPushToTalk: window.pushToTalk()
    }

    MediaViewer {
        id: viewer
        anchors.fill: parent
    }

    PairingScreen {
        anchors.fill: parent
        visible: Store.mode === "pairing"
    }

    ScreenSaver {
        anchors.fill: parent
        visible: opacity > 0
        opacity: Device.idle && Store.mode !== "pairing" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.InOutQuad } }
    }

    // Wake-word answers float above everything, the screen saver included.
    QuickAnswer {
        id: quick
        anchors.fill: parent
        onOpenChat: {
            quick.dismiss(false)
            assistant.open = true
        }
    }

    SettingsSheet { id: settings }

    // Toasts from the store (reward redeemed, errors, ...).
    Rectangle {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        // Above the quick answer card's spot when that's showing.
        y: quick.shown ? 48 : parent.height - height - 48
        radius: height / 2
        color: Theme.text
        width: toastLabel.implicitWidth + 64
        height: 72
        opacity: 0
        Label {
            id: toastLabel
            anchors.centerIn: parent
            color: Theme.background
            font.pixelSize: Theme.fontMd
        }
        SequentialAnimation {
            id: toastAnim
            NumberAnimation { target: toast; property: "opacity"; to: 1; duration: Theme.quick }
            PauseAnimation { duration: 2500 }
            NumberAnimation { target: toast; property: "opacity"; to: 0; duration: Theme.quick }
        }
        Connections {
            target: Store
            function onNotify(message) { window.showToast(message) }
        }
    }

    // On-screen keyboard (QT_IM_MODULE=qtvirtualkeyboard on the device).
    Loader {
        id: keyboard
        anchors.fill: parent
        z: 1000
        active: Qt.application.arguments.indexOf("--no-keyboard") < 0
        source: "components/KeyboardPanel.qml"
    }

    // Offline indicator.
    Rectangle {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 16
        visible: Store.mode === "live" && !Store.online
        color: Theme.warning
        radius: 12
        width: offlineLabel.implicitWidth + 32
        height: 44
        Label {
            id: offlineLabel
            anchors.centerIn: parent
            text: qsTr("Offline — reconnecting…")
            color: "#1D1E22"
            font.pixelSize: Theme.fontXs
        }
    }
}
