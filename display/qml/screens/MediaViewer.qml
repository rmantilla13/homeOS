import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import HomeOS

// Full-screen photo and video viewer. Swipe between items; the background
// takes on the colors of whatever is showing.
Rectangle {
    id: viewer
    property var items: []
    property bool open: false
    readonly property var current: open && strip.currentIndex >= 0 ? items[strip.currentIndex] : null

    function show(list, index) {
        items = list
        open = true
        // Wait for the list to pick up the new model before jumping to the item.
        Qt.callLater(() => {
            strip.currentIndex = Math.max(0, index)
            strip.positionViewAtIndex(Math.max(0, index), ListView.Beginning)
        })
    }
    function close() { open = false }

    visible: opacity > 0.001
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
    scale: open ? 1 : 0.97
    Behavior on scale { NumberAnimation { duration: Theme.smooth + 60; easing.type: Easing.OutCubic } }

    // Dynamic background: a gradient in the current item's own colors.
    property color tintTop: current ? Qt.darker(current.tint, 1.5) : "#1A1C22"
    property color tintBottom: current ? current.tintDeep : "#0E0F12"
    Behavior on tintTop { ColorAnimation { duration: 700 } }
    Behavior on tintBottom { ColorAnimation { duration: 700 } }
    color: tintBottom
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: viewer.tintTop }
            GradientStop { position: 1; color: viewer.tintBottom }
        }
    }

    MouseArea { anchors.fill: parent }   // keep taps from reaching the screen underneath

    ListView {
        id: strip
        anchors.fill: parent
        anchors.topMargin: 96
        anchors.bottomMargin: 72
        orientation: ListView.Horizontal
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: width
        highlightMoveDuration: Theme.smooth
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        model: viewer.items

        delegate: Item {
            id: slide
            required property var modelData
            required property int index
            readonly property bool isVideo: modelData.kind === "video"
            readonly property bool showing: ListView.isCurrentItem && viewer.open
            width: strip.width
            height: strip.height

            Image {
                anchors.fill: parent
                anchors.margins: 24
                visible: !slide.isVideo || !player.item
                source: slide.isVideo ? (slide.modelData.posterUrl || "") : slide.modelData.url
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: 1920
            }
            Loader {
                id: player
                anchors.fill: parent
                anchors.margins: 24
                active: slide.isVideo && slide.showing
                sourceComponent: VideoView { source: slide.modelData.url }
            }
        }
    }

    // Top bar: close, caption, position.
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 20
        spacing: 16
        IconButton { icon: "close"; fill: Qt.rgba(1, 1, 1, 0.16); ink: "white"; onClicked: viewer.close() }
        Column {
            Layout.fillWidth: true
            Label { text: viewer.current ? viewer.current.caption || "" : ""; color: "white"; font.pixelSize: Theme.fontMd; font.weight: Font.DemiBold }
            Label {
                text: viewer.current ? viewer.current.dateLabel + (viewer.current.uploaderName ? " · " + qsTr("added by %1").arg(viewer.current.uploaderName) : "") : ""
                color: Qt.rgba(1, 1, 1, 0.75)
                font.pixelSize: Theme.fontXs
            }
        }
        Label {
            text: (strip.currentIndex + 1) + " / " + viewer.items.length
            color: Qt.rgba(1, 1, 1, 0.75)
            font.pixelSize: Theme.fontSm
        }
    }

    // Previous / next.
    IconButton {
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        icon: "left"; fill: Qt.rgba(1, 1, 1, 0.16); ink: "white"
        visible: strip.currentIndex > 0
        onClicked: strip.decrementCurrentIndex()
    }
    IconButton {
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        icon: "right"; fill: Qt.rgba(1, 1, 1, 0.16); ink: "white"
        visible: strip.currentIndex < viewer.items.length - 1
        onClicked: strip.incrementCurrentIndex()
    }

    // Position dots.
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 30
        spacing: 8
        visible: viewer.items.length <= 30
        Repeater {
            model: viewer.items.length
            delegate: Rectangle {
                required property int index
                width: index === strip.currentIndex ? 22 : 8
                height: 8
                radius: 4
                color: index === strip.currentIndex ? "white" : Qt.rgba(1, 1, 1, 0.4)
                Behavior on width { NumberAnimation { duration: Theme.smooth } }
            }
        }
    }
}
