import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import HomeOS

// Full-screen photo and video viewer. Media fills the whole screen; where the
// shape doesn't match, a blurred copy of the same image fills the edges. The
// controls float on top behind soft scrims and fade away after a few seconds.
// Tap anywhere to bring them back.
Rectangle {
    id: viewer
    property var items: []
    property bool open: false
    property bool chrome: true
    readonly property var current: open && strip.currentIndex >= 0 ? items[strip.currentIndex] : null

    function show(list, index) {
        items = list
        open = true
        showChrome()
        // Wait for the list to pick up the new model before jumping to the item.
        Qt.callLater(() => {
            strip.currentIndex = Math.max(0, index)
            strip.positionViewAtIndex(Math.max(0, index), ListView.Beginning)
        })
    }
    function close() { open = false }
    function showChrome() { chrome = true; hideTimer.restart() }
    function toggleChrome() { if (chrome) { chrome = false; hideTimer.stop() } else showChrome() }

    Timer { id: hideTimer; interval: 3500; onTriggered: viewer.chrome = false }

    visible: opacity > 0.001
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    scale: open ? 1 : 0.97
    Behavior on scale { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

    // Shows through only while an image loads or for videos without a poster.
    color: current ? current.tintDeep : "#0E0F12"
    Behavior on color { ColorAnimation { duration: Theme.quick } }

    MouseArea { anchors.fill: parent }   // keep taps from reaching the screen underneath

    ListView {
        id: strip
        anchors.fill: parent
        orientation: ListView.Horizontal
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: width
        highlightMoveDuration: Theme.smooth
        boundsBehavior: Flickable.StopAtBounds
        model: viewer.items
        onMovementStarted: viewer.showChrome()

        delegate: Item {
            id: slide
            required property var modelData
            required property int index
            readonly property bool isVideo: modelData.kind === "video"
            readonly property bool showing: ListView.isCurrentItem && viewer.open
            readonly property string imageSource: isVideo ? (modelData.posterUrl || "") : modelData.url
            width: strip.width
            height: strip.height
            clip: true

            // Blurred, darkened fill for the edges the photo doesn't cover.
            Image {
                id: backdrop
                anchors.fill: parent
                source: slide.imageSource
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 480
                visible: false
            }
            FastBlur {
                anchors.fill: parent
                source: backdrop
                radius: 64
                cached: true
                visible: backdrop.status === Image.Ready
            }
            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.35) }

            // The media itself, edge to edge.
            Image {
                anchors.fill: parent
                visible: !slide.isVideo || !player.item
                source: slide.imageSource
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: 2560
            }
            Loader {
                id: player
                anchors.fill: parent
                active: slide.isVideo && slide.showing
                sourceComponent: VideoView {
                    source: slide.modelData.url
                    controlsVisible: viewer.chrome
                    onTapped: viewer.toggleChrome()
                    onInteracted: viewer.showChrome()
                }
            }

            TapHandler { enabled: !slide.isVideo; onTapped: viewer.toggleChrome() }
        }
    }

    // Everything below floats over the media and fades with the chrome.
    Item {
        id: overlay
        anchors.fill: parent
        opacity: viewer.chrome ? 1 : 0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

        // Scrims keep text readable on any photo.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 180
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 200
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.6) }
            }
        }

        // Top bar: close, caption, position.
        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            spacing: 16
            IconButton { icon: "close"; fill: Qt.rgba(1, 1, 1, 0.18); ink: "white"; onClicked: viewer.close() }
            Column {
                Layout.fillWidth: true
                Label {
                    text: viewer.current ? viewer.current.caption || "" : ""
                    color: "white"
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                    style: Text.Raised; styleColor: "#40000000"
                }
                Label {
                    text: viewer.current ? viewer.current.dateLabel + (viewer.current.uploaderName ? " · " + qsTr("added by %1").arg(viewer.current.uploaderName) : "") : ""
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font.pixelSize: Theme.fontXs
                }
            }
            Label {
                text: (strip.currentIndex + 1) + " / " + viewer.items.length
                color: Qt.rgba(1, 1, 1, 0.8)
                font.pixelSize: Theme.fontSm
            }
        }

        // Previous / next.
        IconButton {
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            icon: "left"; fill: Qt.rgba(1, 1, 1, 0.18); ink: "white"
            visible: strip.currentIndex > 0
            onClicked: { strip.decrementCurrentIndex(); viewer.showChrome() }
        }
        IconButton {
            anchors.right: parent.right
            anchors.rightMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            icon: "right"; fill: Qt.rgba(1, 1, 1, 0.18); ink: "white"
            visible: strip.currentIndex < viewer.items.length - 1
            onClicked: { strip.incrementCurrentIndex(); viewer.showChrome() }
        }

        // Position dots.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 26
            spacing: 8
            visible: viewer.items.length <= 30
            Repeater {
                model: viewer.items.length
                delegate: Rectangle {
                    required property int index
                    width: index === strip.currentIndex ? 22 : 8
                    height: 8
                    radius: 4
                    color: index === strip.currentIndex ? "white" : Qt.rgba(1, 1, 1, 0.45)
                    Behavior on width { NumberAnimation { duration: Theme.quick } }
                }
            }
        }
    }
}
