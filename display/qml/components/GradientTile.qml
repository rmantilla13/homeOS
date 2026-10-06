import QtQuick
import HomeOS
import HomeOS.Core

// "Poster glow" background for the highlight tiles: Home's member progress
// tiles, the assistant card and Dinner, and the Rewards balance. Dense lists
// stay on plain cards.
//
// A luminous pastel mesh gradient with one or two frosted-glass rings that
// drift slowly across it, drawn in a single ShaderEffect pass (gradient,
// glass, film grain and the antialiased rounded corners all happen in
// shaders/gradienttile.frag: no layers, blurs or masks). Children go on top.
//
//   GradientTile {
//       baseColor: member.color          // or colors: [Theme.glowBlue, ...]
//       active: screen.shown             // false while its page is hidden
//       seed: index                      // tiles drift out of step
//       Label { color: parent.ink; ... } // ink/inkMuted are picked to read on it
//   }
//
// The palette comes from one base color: its hue, two analogous hues (about
// +27 and -31 degrees) and a soft near-white highlight, mapped to pastel
// lightness by day and to deep, desaturated tones at night. `colors` (3-4)
// uses those hues instead, mapped the same way so the tiles stay a family.
//
// Motion: one loop is `period` ms (scaled 0.85-1.15x by seed so tiles never
// line up); every movement in the shader is a whole multiple of the loop, so
// it wraps seamlessly. The clock only ticks while the tile can be seen (its
// page is showing, the screen saver is down, the window is up) and Settings →
// Animated tiles is on; it resumes where it stopped.
Item {
    id: tile

    // ---- Color
    property color baseColor: Theme.accent
    property var colors: []            // optional: 3-4 source colors instead of baseColor
    property bool dark: Theme.dark     // night look: deep, dim, slower
    property int moodFade: Theme.moodFade

    // ---- Shape and glass
    property real radius: Theme.radius
    property int rings: 2              // 0, 1 or 2 frosted-glass rings
    property real ringScale: 1.0       // ring size multiplier
    property real ringBias: 0.72       // 0..1, where the rings live horizontally
    property real grain: 0.014         // film grain against banding (0 = off)

    // ---- Motion
    property bool animated: Device.animatedTiles   // off: frozen where it is
    property bool active: true         // false while the tile's page isn't showing
    property real seed: 0              // per-tile variation (layout mirror + phase)
    property int period: 48000         // ms per loop, before the seed's 0.85-1.15x
    property int maxFps: 30            // motion updates per second (0 = every frame);
                                       // slow drift needs no more, and it halves GPU work

    // ---- Read-only helpers for content on top
    readonly property color ink: _mixc(_inkL, _inkD, _dk)            // titles, numbers
    readonly property color inkMuted: _mixc(_mutedL, _mutedD, _dk)   // secondary text
    readonly property color strong: _mixc(_strongL, _strongD, _dk)   // fills, icons
    readonly property color glassFill: Qt.rgba(1, 1, 1, 0.50 - 0.42 * _dk)
    readonly property color glassStroke: Qt.rgba(1, 1, 1, 0.85 - 0.65 * _dk)
    readonly property bool playing: animated && active && !Device.idle && visible
                                    && width > 0 && height > 0 && !fallback && _windowShown
    // Software renderer, or a shader that failed to load: a plain two-stop gradient.
    readonly property bool fallback: GraphicsInfo.api === GraphicsInfo.Software
                                     || fx.status === ShaderEffect.Error

    default property alias content: holder.data

    // ------------------------------------------------------------------
    // Internals

    readonly property bool _windowShown: Window.window !== null
                                         && Window.visibility !== Window.Hidden
                                         && Window.visibility !== Window.Minimized

    property real _dk: dark ? 1 : 0
    Behavior on _dk { NumberAnimation { duration: tile.moodFade; easing.type: Easing.InOutQuad } }

    // A new base color (another kid on Rewards) eases in instead of snapping.
    property color _base: baseColor
    Behavior on _base { ColorAnimation { duration: Theme.quick; easing.type: Easing.InOutQuad } }

    function _clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
    function _wrap(h) { return h - Math.floor(h) }
    function _hsl(c) {
        const k = Qt.lighter(c, 1.0)   // accepts color values and strings
        let h = k.hslHue, s = k.hslSaturation
        if (h < 0) { h = 0; s = 0 }
        return { h: h, s: s, l: k.hslLightness }
    }
    function _mixc(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }
    // Pastel saturation: lively but never neon; greys stay grey.
    function _sat(s) { return s < 0.08 ? s : _clamp(s, 0.38, 0.78) }

    // Source hues: [main, analogous +, analogous -, highlight]. `nh` is the
    // hue used at night: a narrower spread reads calmer (and keeps warm
    // tiles from drifting into olive when they get dark).
    readonly property var _src: {
        if (colors && colors.length >= 3) {
            const c = colors.map(x => _hsl(x))
            if (c.length < 4) c.push({ h: _wrap(c[0].h + 0.03), s: c[0].s * 0.7, l: 0.95 })
            return c
        }
        const b = _hsl(_base)
        return [ { h: b.h,                s: b.s },
                 { h: _wrap(b.h + 0.075), s: b.s * 0.95, nh: _wrap(b.h + 0.03) },
                 { h: _wrap(b.h - 0.085), s: b.s * 0.90, nh: _wrap(b.h - 0.035) },
                 { h: _wrap(b.h + 0.03),  s: b.s * 0.70, nh: b.h } ]
    }
    function _nh(i) { return _src[i].nh !== undefined ? _src[i].nh : _src[i].h }
    // Day: luminous pastels. Night: deep, desaturated, a touch of the hue.
    readonly property var _light: [
        Qt.hsla(_src[0].h, _sat(_src[0].s),        0.79, 1),
        Qt.hsla(_src[1].h, _sat(_src[1].s),        0.83, 1),
        Qt.hsla(_src[2].h, _sat(_src[2].s),        0.76, 1),
        Qt.hsla(_src[3].h, _sat(_src[3].s) * 0.8,  0.94, 1)
    ]
    readonly property var _darkp: [
        Qt.hsla(_nh(0), _sat(_src[0].s) * 0.55, 0.19, 1),
        Qt.hsla(_nh(1), _sat(_src[1].s) * 0.50, 0.22, 1),
        Qt.hsla(_nh(2), _sat(_src[2].s) * 0.50, 0.15, 1),
        Qt.hsla(_nh(3), _sat(_src[3].s) * 0.45, 0.27, 1)
    ]
    readonly property var _pal: [
        _mixc(_light[0], _darkp[0], _dk), _mixc(_light[1], _darkp[1], _dk),
        _mixc(_light[2], _darkp[2], _dk), _mixc(_light[3], _darkp[3], _dk)
    ]
    readonly property real _h: _src[0].h
    readonly property real _s: _src[0].s
    readonly property color _inkL:    Qt.hsla(_h, Math.min(_s, 0.45), 0.15, 1)
    readonly property color _inkD:    Qt.hsla(_h, Math.min(_s, 0.25), 0.96, 1)
    readonly property color _mutedL:  Qt.hsla(_h, Math.min(_s, 0.38), 0.26, 1)
    readonly property color _mutedD:  Qt.hsla(_h, Math.min(_s, 0.25), 0.87, 1)
    readonly property color _strongL: Qt.hsla(_h, _clamp(_s, 0.40, 0.62), 0.42, 1)
    readonly property color _strongD: Qt.hsla(_h, _clamp(_s, 0.40, 0.62), 0.72, 1)

    // Loop clock. Accumulates real elapsed time, so pausing and resuming never
    // jumps; night runs a little slower. Updates are quantised to wall-clock
    // slots of 1/maxFps s, the same slots for every tile, so all tiles change
    // on the same frames and the frames in between have nothing to redraw
    // (the render loop skips them).
    readonly property real _period: period * (0.85 + 0.30 * _wrap(seed * 0.618034 + 0.3))
    property real _phase: 0
    property real _last: 0
    property real _slot: -1
    FrameAnimation {
        running: tile.playing
        onRunningChanged: if (running) tile._last = Date.now()
        onTriggered: {
            const now = Date.now()
            if (tile.maxFps > 0) {
                const slot = Math.floor(now * tile.maxFps / 1000)
                if (slot === tile._slot) return
                tile._slot = slot
            }
            const dt = Math.min((now - tile._last) / 1000, 0.1)
            tile._last = now
            const speed = (2 * Math.PI) / (tile._period / 1000) * (1 - 0.35 * tile._dk)
            tile._phase = (tile._phase + dt * speed) % (2 * Math.PI)
        }
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: !tile.fallback
        // Uniforms (names match shaders/gradienttile.frag).
        readonly property size size: Qt.size(width, height)
        readonly property real radius: Math.min(tile.radius, width / 2, height / 2)
        readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        readonly property real phase: tile._phase + tile.seed * 1.7
        readonly property real seed: tile.seed
        readonly property real motion: 1.0
        readonly property real rings: tile.rings
        readonly property real ringScale: tile.ringScale
        readonly property real ringBias: tile.ringBias
        readonly property real glass: 1.0 - 0.65 * tile._dk
        readonly property real grain: tile.grain
        readonly property color c0: tile._pal[0]
        readonly property color c1: tile._pal[1]
        readonly property color c2: tile._pal[2]
        readonly property color c3: tile._pal[3]
        readonly property color rimColor: Qt.rgba(1, 1, 1, 0.80 - 0.35 * tile._dk)
        fragmentShader: "qrc:/HomeOS/shaders/gradienttile.frag.qsb"
    }

    Rectangle {
        anchors.fill: parent
        visible: tile.fallback
        radius: fx.radius
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: tile._pal[0] }
            GradientStop { position: 1; color: tile._pal[1] }
        }
    }

    Item {
        id: holder
        anchors.fill: parent
    }
}
