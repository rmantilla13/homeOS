pragma Singleton
import QtQuick
import HomeOS.Core

// Design tokens with a dynamic, time-of-day palette.
//
// Device.mood picks one of four moods - morning (warm peach/coral), day
// (clear blue), evening (violet/rose) and night (dark) - and every color
// eases to the new palette over a couple of seconds, so the screen drifts
// through the day instead of switching abruptly.
//
// Settings → Dark mode (Device.darkMode, remembered) replaces that palette
// with one warm near-black canvas. The accent stays the day blue.
Item {
    id: theme
    visible: false

    readonly property string mood: Device.mood
    readonly property bool darkMode: Device.darkMode
    // Night, or the settings toggle: tiles and member tags use the dark treatment.
    readonly property bool dark: darkMode || mood === "night"

    readonly property var palettes: ({
        "morning": {
            background: "#F6F0E9", surface: "#FFFFFF", surfaceAlt: "#F6F0E9", sunken: "#EEE5DA",
            text: "#221C19", textMuted: "#7D736C", divider: "#E9DFD3",
            accent: "#E2725B", accentSoft: "#FBE4DC",
            glow: ["#F6B94A", "#F07F5A", "#F2A7C3", "#FBE6B0"]
        },
        "day": {
            background: "#F1EFEB", surface: "#FFFFFF", surfaceAlt: "#F1EFEB", sunken: "#E9E6E0",
            text: "#1C1C1F", textMuted: "#77767B", divider: "#E4E0D9",
            accent: "#4F7CF7", accentSoft: "#E3EAFE",
            glow: ["#5B7CF5", "#F07F5A", "#F6B94A", "#FBE6B0"]
        },
        "evening": {
            background: "#EFEDF3", surface: "#FFFFFF", surfaceAlt: "#EFEDF3", sunken: "#E5E1EC",
            text: "#1D1B24", textMuted: "#76727F", divider: "#E1DCE8",
            accent: "#7A64E8", accentSoft: "#ECE8FD",
            glow: ["#7A64E8", "#E86A92", "#F07F5A", "#F6B94A"]
        },
        "night": {
            background: "#121317", surface: "#1C1E24", surfaceAlt: "#262931", sunken: "#2C2F38",
            text: "#ECEDEF", textMuted: "#8F95A1", divider: "#30333C",
            accent: "#8EA2FF", accentSoft: "#2A3554",
            glow: ["#3B4FB8", "#7A64E8", "#A04E78", "#6B4A2A"]
        }
    })
    // Warm near-black. Cards step up from the canvas; the accent is the day blue.
    readonly property var darkPalette: ({
        background: "#1C1814", surface: "#2A2420", surfaceAlt: "#342C26", sunken: "#3E362F",
        text: "#F6F1EB", textMuted: "#B3A69C", divider: "#6B6056",
        accent: "#4F7CF7", accentSoft: "#243056",
        glow: ["#3B5BD4", "#C45A3A", "#C48A2E", "#8A7350"]
    })
    readonly property var p: darkMode ? darkPalette : (palettes[mood] || palettes["day"])

    // Animated tokens. Everything in the UI binds to these.
    property color background: p.background
    property color surface:    p.surface
    property color surfaceAlt: p.surfaceAlt
    property color sunken:     p.sunken
    property color text:       p.text
    property color textMuted:  p.textMuted
    property color divider:    p.divider
    property color accent:     p.accent
    property color accentSoft: p.accentSoft
    property color glowBlue:   p.glow[0]
    property color glowCoral:  p.glow[1]
    property color glowAmber:  p.glow[2]
    property color glowCream:  p.glow[3]

    readonly property int moodFade: 2000
    Behavior on background { ColorAnimation { duration: theme.moodFade } }
    Behavior on surface    { ColorAnimation { duration: theme.moodFade } }
    Behavior on surfaceAlt { ColorAnimation { duration: theme.moodFade } }
    Behavior on sunken     { ColorAnimation { duration: theme.moodFade } }
    Behavior on text       { ColorAnimation { duration: theme.moodFade } }
    Behavior on textMuted  { ColorAnimation { duration: theme.moodFade } }
    Behavior on divider    { ColorAnimation { duration: theme.moodFade } }
    Behavior on accent     { ColorAnimation { duration: theme.moodFade } }
    Behavior on accentSoft { ColorAnimation { duration: theme.moodFade } }
    Behavior on glowBlue   { ColorAnimation { duration: theme.moodFade } }
    Behavior on glowCoral  { ColorAnimation { duration: theme.moodFade } }
    Behavior on glowAmber  { ColorAnimation { duration: theme.moodFade } }
    Behavior on glowCream  { ColorAnimation { duration: theme.moodFade } }

    readonly property color accentInk: "#FFFFFF"
    readonly property color success:   "#3DB37A"
    readonly property color warning:   "#F2A93B"

    // Motion.
    readonly property int quick: 160
    readonly property int smooth: 300

    readonly property string fontFamily: "Inter"  // falls back to the system sans if missing
    readonly property string emojiFont: "Noto Color Emoji"
    readonly property int fontXs: 15
    readonly property int fontSm: 18
    readonly property int fontMd: 23
    readonly property int fontLg: 30
    readonly property int fontXl: 44
    readonly property int fontHuge: compact ? 88 : 112

    readonly property int radius: 28
    readonly property int radiusSm: 18
    readonly property int spacing: compact ? 16 : 24
    readonly property int pageMargin: compact ? 24 : 40
    readonly property int touchTarget: 64
    readonly property int navWidth: compact ? 100 : 124

    // Set by Main.qml from the window size. Small panels (e.g. the 10.1" 1920x1200
    // screen at QT_SCALE_FACTOR=1.5 -> 1280x800) get tighter spacing and sizes.
    property bool compact: false
}
