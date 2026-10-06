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
        function onIdleChanged() { if (Device.idle) { window.dismissKeyboard(); assistant.open = false; viewer.close(); window.currentScreen = 0 } }
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
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Page {
                anchors.fill: parent; index: 0; current: window.currentScreen
                HomeScreen {
                    anchors.fill: parent
                    onOpenScreen: index => window.currentScreen = index
                    onOpenAssistant: question => {
                        assistant.open = true
                        if (question) AI.ask(question)
                        else assistant.focusInput()
                    }
                }
            }
            Page { anchors.fill: parent; index: 1; current: window.currentScreen; CalendarScreen { anchors.fill: parent } }
            Page { anchors.fill: parent; index: 2; current: window.currentScreen; TasksScreen { anchors.fill: parent } }
            Page { anchors.fill: parent; index: 3; current: window.currentScreen; RewardsScreen { anchors.fill: parent } }
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
        onCloseRequested: { window.dismissKeyboard(); open = false }
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
        Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.InOutQuad } }
    }

    // Toasts from the store (reward redeemed, errors, ...).
    Rectangle {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 48
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
            NumberAnimation { target: toast; property: "opacity"; to: 1; duration: 200 }
            PauseAnimation { duration: 2500 }
            NumberAnimation { target: toast; property: "opacity"; to: 0; duration: 400 }
        }
        Connections {
            target: Store
            function onNotify(message) { toastLabel.text = message; toastAnim.restart() }
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
