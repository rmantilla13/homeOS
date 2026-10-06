import QtQuick
import QtQuick.Controls
import QtMultimedia
import HomeOS

// Video with simple touch controls: tap to play/pause, tap the bar to seek.
Item {
    id: video
    property alias source: player.source

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

    TapHandler { onTapped: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }

    // Big play button while paused.
    Rectangle {
        anchors.centerIn: parent
        width: 96; height: 96; radius: 48
        color: Qt.rgba(0, 0, 0, 0.4)
        opacity: player.playbackState === MediaPlayer.PlayingState ? 0 : 1
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.quick } }
        Icon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 3; name: "play"; color: "white"; size: 44 }
    }

    // Progress bar.
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 40
        Rectangle {
            id: track
            anchors.left: parent.left
            anchors.right: time.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            height: 6; radius: 3
            color: Qt.rgba(1, 1, 1, 0.25)
            Rectangle {
                height: parent.height; radius: 3
                width: player.duration > 0 ? parent.width * player.position / player.duration : 0
                color: "white"
            }
            TapHandler {
                onTapped: point => {
                    if (player.duration > 0)
                        player.position = player.duration * Math.max(0, Math.min(1, point.position.x / track.width))
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
        }
    }
}
