import QtQuick
import QtQuick.Controls
import QtMultimedia
import HomeOS

// Edge-to-edge video with overlay controls (play/pause and a seek bar) that
// follow the viewer's chrome. Tapping the picture toggles the chrome.
Item {
    id: video
    property alias source: player.source
    property bool controlsVisible: true
    signal tapped()
    signal interacted()

    MediaPlayer {
        id: player
        videoOutput: output
        audioOutput: AudioOutput { volume: 0.8 }
        Component.onCompleted: play()
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia) { position = 0; pause() }
    }
    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
    }

    TapHandler { onTapped: video.tapped() }

    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState

    // Centre play/pause: always shown while paused, otherwise with the chrome.
    Rectangle {
        anchors.centerIn: parent
        width: 104; height: 104; radius: 52
        color: Qt.rgba(0, 0, 0, 0.38)
        opacity: !video.playing || video.controlsVisible ? 1 : 0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
        Icon {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: video.playing ? 0 : 3
            name: video.playing ? "pause" : "play"
            color: "white"
            size: 46
            strokeWidth: 2.4
        }
        TapHandler {
            gesturePolicy: TapHandler.WithinBounds
            onTapped: {
                video.playing ? player.pause() : player.play()
                video.interacted()
            }
        }
    }

    // Seek bar, floating just above the position dots.
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 32
        anchors.rightMargin: 32
        anchors.bottomMargin: 56
        height: 44
        opacity: video.controlsVisible ? 1 : 0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }

        Rectangle {
            id: track
            anchors.left: parent.left
            anchors.right: time.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            height: 6; radius: 3
            color: Qt.rgba(1, 1, 1, 0.3)
            Rectangle {
                height: parent.height; radius: 3
                width: player.duration > 0 ? parent.width * player.position / player.duration : 0
                color: "white"
            }
            TapHandler {
                // Generous touch area around the thin bar.
                margin: 18
                gesturePolicy: TapHandler.WithinBounds
                onTapped: point => {
                    if (player.duration > 0)
                        player.position = player.duration * Math.max(0, Math.min(1, point.position.x / track.width))
                    video.interacted()
                }
            }
        }
        Label {
            id: time
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            function fmt(ms) { const s = Math.floor(ms / 1000); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0") }
            text: fmt(player.position) + " / " + fmt(player.duration)
            color: "white"
            font.pixelSize: Theme.fontXs
            font.weight: Font.DemiBold
            style: Text.Raised
            styleColor: "#80000000"
        }
    }
}
