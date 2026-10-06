pragma Singleton
import QtQuick
import HomeOS.Core

// Design tokens for a screen read from across the room: big type, large touch
// targets, soft surfaces. Switches to a dim palette in night mode.
QtObject {
    readonly property bool dark: Device.nightMode

    readonly property color background:  dark ? "#14161B" : "#F4F1EC"
    readonly property color surface:     dark ? "#1E2128" : "#FFFFFF"
    readonly property color surfaceAlt:  dark ? "#272B34" : "#EFEBE4"
    readonly property color text:        dark ? "#ECEDEF" : "#1D1E22"
    readonly property color textMuted:   dark ? "#9097A3" : "#6B6E76"
    readonly property color accent:      "#7C6CF2"
    readonly property color success:     "#3DBE7A"
    readonly property color warning:     "#F5A623"
    readonly property color divider:     dark ? "#2E323C" : "#E4DFD7"

    readonly property string fontFamily: "Inter"  // falls back to the system sans if missing
    readonly property string emojiFont: "Noto Color Emoji"
    readonly property int fontXs: 16
    readonly property int fontSm: 20
    readonly property int fontMd: 26
    readonly property int fontLg: 34
    readonly property int fontXl: 48
    readonly property int fontHuge: compact ? 96 : 120

    readonly property int radius: 24
    readonly property int spacing: compact ? 16 : 24
    readonly property int pageMargin: compact ? 24 : 40
    readonly property int touchTarget: 72
    readonly property int navWidth: compact ? 104 : 128

    // Set by Main.qml from the window size. Small panels (e.g. the 10.1" 1920×1200
    // screen at QT_SCALE_FACTOR=1.5 → 1280×800) get tighter spacing and sizes.
    property bool compact: false
}
