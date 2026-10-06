pragma Singleton
import QtQuick
import HomeOS.Core

// Design tokens. Warm off-white canvas, white rounded cards, a calm blue
// accent and a blue → coral → amber glow, with soft pastel member colors.
// Switches to a dim palette in night mode.
QtObject {
    readonly property bool dark: Device.nightMode

    readonly property color background:  dark ? "#121317" : "#F1EFEB"
    readonly property color surface:     dark ? "#1C1E24" : "#FFFFFF"
    readonly property color surfaceAlt:  dark ? "#262931" : "#F1EFEB"
    readonly property color sunken:      dark ? "#2C2F38" : "#E9E6E0"
    readonly property color text:        dark ? "#ECEDEF" : "#1C1C1F"
    readonly property color textMuted:   dark ? "#8F95A1" : "#77767B"
    readonly property color accent:      "#4F7CF7"
    readonly property color accentSoft:  dark ? "#2A3554" : "#E3EAFE"
    readonly property color onAccent:    "#FFFFFF"
    readonly property color success:     "#3DB37A"
    readonly property color warning:     "#F2A93B"
    readonly property color divider:     dark ? "#30333C" : "#E4E0D9"

    // Glow used behind the assistant and the photo frame.
    readonly property color glowBlue:   "#5B7CF5"
    readonly property color glowCoral:  "#F07F5A"
    readonly property color glowAmber:  "#F6B94A"
    readonly property color glowCream:  "#FBE6B0"

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

    // Set by Main.qml from the window size. Small panels (e.g. the 10.1" 1920×1200
    // screen at QT_SCALE_FACTOR=1.5 → 1280×800) get tighter spacing and sizes.
    property bool compact: false
}
