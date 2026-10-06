import QtQuick
import QtQuick.Controls
import HomeOS

// A number label that counts smoothly to its new value (points, totals).
Label {
    id: num
    property real value: 0
    property string prefix: ""
    property string suffix: ""
    property real shown: value
    Behavior on shown { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
    text: prefix + Math.round(shown) + suffix
}
