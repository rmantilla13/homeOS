import QtQuick
import QtMultimedia
import HomeOS.Core

// The boot screen, drawn by the app from its first frame. The panel goes
// from black to the logo, holds it at least Boot.holdSeconds (5 s), then
// fades into the app once there is something to show. Nothing else draws on
// the panel during boot, so there is no handoff and no console in between.
// The admin console's boot video (Boot.video) plays in place of the logo,
// through to its end at least once (admin allows up to 12 s); if it does not
// start, the logo shows.
Item {
    id: boot

    // Set by Main.qml: demo data, a pairing code, or the family's first sync.
    property bool appReady: false
    property url video: Boot.video
    property int holdSeconds: Boot.holdSeconds
    // Stop waiting here: for the first sync (Wi-Fi still down, say), or for
    // a long video to end. The app then shows itself, with its offline badge.
    property int maxSeconds: Math.max(holdSeconds, 15)
    readonly property int fadeIn: 600

    // Black until the app's first frame, then the logo (or the video once it
    // plays), held long enough, then leaving.
    property bool started: false
    property bool held: false
    property bool timedOut: false
    property bool videoShowing: false
    property bool videoPlayedThrough: false
    property bool videoFailed: false
    readonly property bool useVideo: video.toString() !== "" && !videoFailed
    readonly property bool contentShown: started && (!useVideo || videoShowing)
    readonly property bool canLeave: held && (appReady || timedOut)
                                     && (!useVideo || videoPlayedThrough || timedOut)
    // Once it goes it stays gone, whatever the store does next (a pairing
    // code that refreshes, say).
    property bool leaving: false
    onCanLeaveChanged: if (canLeave) leaving = true
    readonly property bool finished: holdSeconds <= 0 || (leaving && opacity === 0)

    visible: !finished
    opacity: leaving ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }

    // Start once frames are being drawn, so the fade-in is not spent while
    // the rest of the app is still loading. afterAnimating is on the GUI
    // thread, but inside the render loop: start after it returns (a video
    // started from in there stalls). A platform that never draws starts on
    // the timer instead.
    function start() {
        if (!started) {
            startedAt = Date.now()
            started = true
        }
    }
    Connections {
        target: boot.Window.window
        enabled: !boot.started
        function onAfterAnimating() { Qt.callLater(boot.start) }
    }
    Timer { interval: 1000; running: boot.visible && !boot.started; onTriggered: boot.start() }

    // Times are on the wall clock. A QML Timer runs on the animation clock,
    // which runs fast on a screen without vsync, and the hold is a promise.
    property double startedAt: 0
    property double shownAt: 0
    onContentShownChanged: if (contentShown && !shownAt) shownAt = Date.now()
    function check() {
        const now = Date.now()
        if (useVideo && !videoShowing && now - startedAt >= 3000)
            videoFailed = true
        if (shownAt && now - shownAt >= fadeIn + holdSeconds * 1000)
            held = true
        if (now - startedAt >= maxSeconds * 1000)
            timedOut = true
    }
    Timer { interval: 100; repeat: true; running: boot.started && !boot.leaving; onTriggered: boot.check() }

    // The console before the app was black: start from there.
    Rectangle { anchors.fill: parent; color: "black" }

    // Built and freed with the boot screen.
    Loader {
        anchors.fill: parent
        active: boot.visible
        sourceComponent: Item {
            // The logo: 1920x1200 artwork (resources/boot/make-boot-screen.py),
            // scaled to cover the screen.
            Item {
                id: stage
                width: 1920
                height: 1200
                anchors.centerIn: parent
                scale: Math.max(parent.width / width, parent.height / height)
                visible: !boot.useVideo
                opacity: boot.contentShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: boot.fadeIn; easing.type: Easing.OutQuad } }

                // Light drifting along the arch, back where it started every 6 s.
                property real phase: 0
                NumberAnimation on phase { from: 0; to: 1; duration: 6000; loops: Animation.Infinite; running: stage.visible }

                Image { anchors.fill: parent; source: "qrc:/HomeOS/resources/boot/background.png" }
                Image {
                    // The arch's circle: centre (960, 1460), radius 740.
                    readonly property real angle: -Math.PI / 2 + 0.78 * Math.sin(2 * Math.PI * stage.phase)
                    x: 960 + 740 * Math.cos(angle) - width / 2
                    y: 1460 + 740 * Math.sin(angle) - height / 2
                    source: "qrc:/HomeOS/resources/boot/highlight.png"
                }
                Image { anchors.fill: parent; source: "qrc:/HomeOS/resources/boot/mark.png" }
            }

            // The admin's video, silent (no audio output), looping while the
            // app gets ready.
            MediaPlayer {
                id: player
                readonly property bool shouldPlay: boot.started && boot.useVideo
                source: boot.useVideo ? boot.video : ""
                videoOutput: output
                onShouldPlayChanged: if (shouldPlay) play()
                onPositionChanged: {
                    if (position > 0 && playbackState === MediaPlayer.PlayingState)
                        boot.videoShowing = true
                }
                onMediaStatusChanged: {
                    if (mediaStatus === MediaPlayer.EndOfMedia) {
                        boot.videoPlayedThrough = true
                        position = 0
                        play()
                    } else if (mediaStatus === MediaPlayer.InvalidMedia) {
                        boot.videoFailed = true
                    }
                }
                onErrorOccurred: boot.videoFailed = true
            }
            VideoOutput {
                id: output
                anchors.fill: parent
                visible: boot.useVideo
                fillMode: VideoOutput.PreserveAspectCrop
                opacity: boot.videoShowing ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: boot.fadeIn; easing.type: Easing.OutQuad } }
            }
        }
    }

    // Keep taps from reaching the app underneath.
    MouseArea { anchors.fill: parent }
}
