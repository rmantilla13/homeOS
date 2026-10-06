import QtQuick
import QtMultimedia
import HomeOS
import HomeOS.Core

// Family videos full screen, muted, one after another on a loop.
Item {
    id: saver
    readonly property var videos: Store.media.filter(m => m.kind === "video" && m.url)
    property int index: 0
    readonly property var shown: videos.length ? videos[index % videos.length] : null

    // Poster underneath while the video loads.
    PhotoTile {
        anchors.fill: parent
        radius: 0
        showCaption: false
        color: "black"
        photo: saver.shown
    }

    MediaPlayer {
        id: player
        source: saver.shown ? saver.shown.url : ""
        videoOutput: output
        audioOutput: AudioOutput { muted: true }
        onSourceChanged: () => { if (player.source != "") player.play() }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                if (saver.videos.length > 1) saver.index++
                else { position = 0; play() }
            }
        }
    }
    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: player.playbackState === MediaPlayer.PlayingState ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
    }
}
