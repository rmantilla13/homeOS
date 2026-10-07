import QtQuick
import QtMultimedia
import HomeOS
import HomeOS.Core

// Family videos full screen, muted, one after another on a loop.
//
// The player's source is set here in code, never bound to Store: the list
// is rebuilt often and URLs are signed again every few hours, and a new
// source string stops the clip and loads it again from the start.
Item {
    id: saver
    readonly property var videos: Store.media.filter(m => m.kind === "video" && m.url)
    property int index: 0
    property var shown: null            // ScreenSaver.qml reads .shown (caption, shade)
    property string playingKey: ""      // the row in the player
    property string playingUrl: ""      // and the URL it was loaded with
    property bool failed: false         // that row could not play
    property bool frameShown: false     // the clip in the player has drawn a frame
    property bool moved: false          // its position changed since the watchdog looked
    property int errors: 0              // failures in a row; reset once a frame plays
    property int backoffMs: 2000        // tests shorten these
    property int retryMs: 30000
    property int stallMs: 10000

    function keyOf(m) { return m.id || m.url }

    // Puts videos[i] on screen. The clip already in the player keeps playing
    // with the URL it has, unless it failed.
    function show(i) {
        backoff.stop()
        if (!videos.length) {
            shown = null
            playingKey = ""
            playingUrl = ""
            failed = false
            frameShown = false
            player.stop()
            player.source = ""
            return
        }
        index = ((i % videos.length) + videos.length) % videos.length
        shown = videos[index]
        if (keyOf(shown) === playingKey && !failed)
            return
        playingKey = keyOf(shown)
        playingUrl = shown.url
        failed = false
        frameShown = false
        // The same URL again is ignored, even after an error: clear it first
        // so a retry really loads.
        player.source = ""
        player.source = shown.url
        player.play()
    }

    onVideosChanged: {
        const at = videos.findIndex(m => keyOf(m) === playingKey)
        if (at >= 0 && !failed) {
            index = at
            shown = videos[at]
        } else {
            show(at >= 0 ? at : index)  // gone, or failed: a fresh URL may help
        }
    }
    Component.onCompleted: show(0)

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
        objectName: "saverPlayer"
        videoOutput: output
        audioOutput: AudioOutput { muted: true }
        // One clip loops in the player instead of loading again at its end,
        // but only while it has the row's current URL. Once the row is signed
        // again this pass is the last and its end loads the new URL: the old
        // one expires, and FFmpeg (Qt 6.8) then freezes at a loop's end
        // without an error.
        loops: saver.videos.length === 1 && saver.shown && saver.shown.url === saver.playingUrl
               ? MediaPlayer.Infinite : 1
        // Not on PlayingState: Qt 6.4's GStreamer reports that before the
        // file has even loaded. Latched, because each loop sets the position
        // back to 0 for a moment.
        onPositionChanged: {
            saver.moved = true
            if (player.position > 0) {
                saver.errors = 0
                saver.frameShown = true
            }
        }
        onMediaStatusChanged: {
            if (player.mediaStatus === MediaPlayer.EndOfMedia) {
                saver.playingKey = ""   // the next start takes the list's current URL
                saver.show(saver.index + 1)
            }
        }
        onErrorOccurred: (error, message) => {
            if (saver.failed)
                return                  // one failure per load
            console.warn("screensaver video failed:", message)
            saver.failed = true
            // Every clip failing in a row (offline, say) waits for `retry`.
            if (++saver.errors < saver.videos.length)
                backoff.restart()
        }
    }
    // A short pause before the next clip, so a dead network doesn't spin.
    Timer {
        id: backoff
        objectName: "saverBackoff"
        interval: saver.backoffMs
        onTriggered: saver.show(saver.index + 1)
    }
    // Try again now and then while the clip on screen can't play.
    Timer {
        id: retry
        interval: saver.retryMs
        repeat: true
        running: saver.failed && saver.videos.length > 0
        onTriggered: {
            saver.errors = 0
            saver.show(saver.index)
        }
    }
    // FFmpeg (Qt 6.8) can stop on a failed read (a Wi-Fi drop, say) with no
    // error and no end: the picture just freezes. A clip whose position
    // stops moving counts as failed, and after the short pause the next one
    // loads (the same one again when it's the only one).
    Timer {
        id: watchdog
        objectName: "saverWatchdog"
        interval: saver.stallMs
        repeat: true
        running: player.playbackState === MediaPlayer.PlayingState && saver.frameShown && !saver.failed
        onRunningChanged: saver.moved = false
        onTriggered: {
            if (saver.moved) {
                saver.moved = false
                return
            }
            console.warn("screensaver video stopped moving")
            saver.failed = true
            saver.frameShown = false    // the poster, not a frozen frame
            backoff.restart()
        }
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        // The poster stays up until the first frame.
        opacity: player.playbackState === MediaPlayer.PlayingState && saver.frameShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
    }
}
