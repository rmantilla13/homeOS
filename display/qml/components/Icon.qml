import QtQuick
import QtQuick.Shapes
import HomeOS

// Line icons drawn as vector paths (24×24 grid, round strokes) so they stay
// crisp at any scale and can take any color.
Item {
    id: icon
    property string name: ""
    property color color: Theme.text
    property real size: 24
    property real strokeWidth: 2

    implicitWidth: size
    implicitHeight: size
    layer.enabled: true
    layer.samples: 4

    readonly property var paths: ({
        "home":     "M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z",
        "calendar": "M6 5h12a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z M4 10h16 M8.5 3v4 M15.5 3v4",
        "chores":   "M10.5 7H20 M10.5 12H20 M10.5 17H20 M4 7l1.5 1.5L8 6 M4 12l1.5 1.5L8 11 M4 17l1.5 1.5L8 16",
        "star":     "M12 3.8l2.5 5.1 5.6.8-4 3.9.9 5.6L12 16.6l-5 2.6.9-5.6-4-3.9 5.6-.8z",
        "photo":    "M5 4.5h14A1.5 1.5 0 0 1 20.5 6v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5z M3.5 15.5 8 11l4 4 2.5-2.5 6 6 M14 9a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0",
        "meals":    "M7 3v18 M4.5 3v5a2.5 2.5 0 0 0 5 0V3 M17.5 21V3c-2 .8-3.5 3-3.5 6.5V13h3.5",
        "moon":     "M19.5 14.5A7.5 7.5 0 0 1 9.5 4.5a7.5 7.5 0 1 0 10 10z",
        "mic":      "M9 6a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z M5.5 11.5a6.5 6.5 0 0 0 13 0 M12 18v3",
        "send":     "M12 19V5 M6 11l6-6 6 6",
        "sparkle":  "M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1-5.1-1.9 5.1-1.9z M19 15.5v4 M17 17.5h4",
        "left":     "M14.5 6l-6 6 6 6",
        "right":    "M9.5 6l6 6-6 6",
        "plus":     "M12 5v14 M5 12h14",
        "close":    "M6.5 6.5l11 11 M17.5 6.5l-11 11",
        "check":    "M5 12.5l4.5 4.5L19 7.5",
        "clock":    "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17z M12 7.5V12l3 2",
        "play":     "M8 5.5v13l10.5-6.5z",
        "pause":    "M8.5 5.5v13 M15.5 5.5v13",
        "video":    "M4.5 6.5h10a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5h-10A1.5 1.5 0 0 1 3 16V8a1.5 1.5 0 0 1 1.5-1.5z M16 10.5l5-3v9l-5-3",
        "grid":     "M4.5 4.5h6v6h-6z M13.5 4.5h6v6h-6z M4.5 13.5h6v6h-6z M13.5 13.5h6v6h-6z",
        "gift":     "M4 8.5h16v4H4z M5.5 12.5V20h13v-7.5 M12 8.5V20 M12 8.5C10.5 4 6 4 6.5 6.5S12 8.5 12 8.5z M12 8.5C13.5 4 18 4 17.5 6.5S12 8.5 12 8.5z",
        "settings": "M18.96 10.61L21.17 10.47L21.17 13.53L18.96 13.39L17.9 15.94L19.57 17.41L17.41 19.57L15.94 17.9L13.39 18.96L13.53 21.17L10.47 21.17L10.61 18.96L8.06 17.9L6.59 19.57L4.43 17.41L6.1 15.94L5.04 13.39L2.83 13.53L2.83 10.47L5.04 10.61L6.1 8.06L4.43 6.59L6.59 4.43L8.06 6.1L10.61 5.04L10.47 2.83L13.53 2.83L13.39 5.04L15.94 6.1L17.41 4.43L19.57 6.59L17.9 8.06z M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z",
        "mic-off":  "M9 6a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z M5.5 11.5a6.5 6.5 0 0 0 13 0 M12 18v3 M4.5 4.5l15 15",
        "speaker":  "M4 9.5h3.5L12 5.5v13l-4.5-4H4z M15.5 9a4 4 0 0 1 0 6 M18.2 6.3a7.6 7.6 0 0 1 0 11.4",
        "speaker-off": "M4 9.5h3.5L12 5.5v13l-4.5-4H4z M16 9.5l5 5 M21 9.5l-5 5",
        "chat":     "M5 5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5h-8.5L6 20v-3.5H5A1.5 1.5 0 0 1 3.5 15V6.5A1.5 1.5 0 0 1 5 5z",
        "link":     "M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1 1 M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1-1",
        "info":     "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17z M12 11v5.5 M12 7.75v.1",
        "wifi":     "M12 18.4a1.15 1.15 0 1 0 0.01 0 M8.1 15.1a5.4 5.4 0 0 1 7.8 0 M4.8 11.9a9.8 9.8 0 0 1 14.4 0 M2.1 8.8a13.6 13.6 0 0 1 19.8 0",
        "power":    "M12 3.5v6.5 M7.4 6.6a7 7 0 1 0 9.2 0",
        "refresh":  "M20 12a8 8 0 1 1-2.2-5.5 M20 4.5V9h-4.5"
    })

    Item {
        width: 24
        height: 24
        scale: icon.size / 24
        transformOrigin: Item.TopLeft
        Shape {
            anchors.fill: parent
            ShapePath {
                strokeColor: icon.color
                strokeWidth: icon.strokeWidth
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: icon.paths[icon.name] || "" }
            }
        }
    }
}
