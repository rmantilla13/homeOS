import QtQuick
import QtQuick.Shapes
import HomeOS

// A glowing orb in the mood colors: the face of the voice assistant. It
// breathes while idle, swells with the microphone level while listening,
// swirls while thinking and pulses while speaking.
Item {
    id: orb
    property real level: 0           // microphone level, 0..1
    property string mode: "idle"     // idle | listening | thinking | speaking
    property real size: 112

    implicitWidth: size
    implicitHeight: size

    // 15 level updates a second, eased so the glow moves fluidly.
    property real smoothLevel: Math.min(1, level * 1.6)
    Behavior on smoothLevel { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }

    property real breath: 0
    readonly property int breathMs: mode === "speaking" ? 380 : mode === "thinking" ? 650 : 1700
    onBreathMsChanged: breathing.restart()
    SequentialAnimation on breath {
        id: breathing
        loops: Animation.Infinite
        running: orb.visible
        NumberAnimation { to: 1; duration: orb.breathMs; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: orb.breathMs; easing.type: Easing.InOutSine }
    }

    // How far the glow reaches beyond the core, 0..1.
    readonly property real swell: mode === "listening" ? 0.12 + smoothLevel * 0.88
                                : mode === "speaking" ? 0.3 + breath * 0.4
                                : mode === "thinking" ? 0.2 + breath * 0.25
                                : breath * 0.2

    // A slow drift that speeds up into a swirl while thinking.
    property real spin: 0
    property real spinSpeed: mode === "thinking" ? 200 : 36   // degrees per second
    Behavior on spinSpeed { NumberAnimation { duration: 600; easing.type: Easing.InOutQuad } }
    FrameAnimation {
        running: orb.visible
        // 720 so the core (turning 1.5x) wraps seamlessly too.
        onTriggered: orb.spin = (orb.spin + orb.spinSpeed * frameTime) % 720
    }

    // Three colored glows circling just off-centre, so the halo shifts hue.
    Item {
        anchors.fill: parent
        rotation: orb.spin
        Repeater {
            model: [
                { reach: 1.0,  dx: -0.06, dy: 0 },
                { reach: 0.85, dx: 0.06,  dy: 0.04 },
                { reach: 0.7,  dx: 0,     dy: -0.07 }
            ]
            delegate: Shape {
                id: halo
                required property var modelData
                required property int index
                readonly property color tint: [Theme.glowBlue, Theme.glowCoral, Theme.glowAmber][index]
                width: orb.size
                height: orb.size
                x: modelData.dx * orb.size
                y: modelData.dy * orb.size
                scale: 0.75 + orb.swell * 0.85 * modelData.reach
                ShapePath {
                    strokeColor: "transparent"
                    strokeWidth: 0
                    fillGradient: RadialGradient {
                        centerX: halo.width / 2; centerY: halo.height / 2; centerRadius: halo.width / 2
                        focalX: halo.width / 2; focalY: halo.height / 2
                        GradientStop { position: 0.0; color: Qt.rgba(halo.tint.r, halo.tint.g, halo.tint.b, 0.7) }
                        GradientStop { position: 0.4; color: Qt.rgba(halo.tint.r, halo.tint.g, halo.tint.b, 0.36) }
                        GradientStop { position: 1.0; color: Qt.rgba(halo.tint.r, halo.tint.g, halo.tint.b, 0) }
                    }
                    PathAngleArc {
                        centerX: halo.width / 2; centerY: halo.height / 2
                        radiusX: halo.width / 2; radiusY: halo.height / 2
                        startAngle: 0; sweepAngle: 360
                    }
                }
            }
        }
    }

    // The core: a gradient sphere that slowly turns.
    Rectangle {
        id: core
        anchors.centerIn: parent
        width: orb.size * 0.54
        height: width
        radius: width / 2
        antialiasing: true
        rotation: -orb.spin * 1.5
        scale: 1 + orb.swell * 0.12
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.glowBlue }
            GradientStop { position: 0.55; color: Theme.glowCoral }
            GradientStop { position: 1.0; color: Theme.glowAmber }
        }
    }
    // Soft highlight so the core reads as a sphere.
    Shape {
        anchors.fill: core
        scale: core.scale
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillGradient: RadialGradient {
                centerX: core.width * 0.38; centerY: core.height * 0.32; centerRadius: core.width * 0.55
                focalX: centerX; focalY: centerY
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.55) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
            }
            PathAngleArc {
                centerX: core.width / 2; centerY: core.height / 2
                radiusX: core.width / 2; radiusY: core.height / 2
                startAngle: 0; sweepAngle: 360
            }
        }
    }
}
