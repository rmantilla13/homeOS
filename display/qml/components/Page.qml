import QtQuick
import HomeOS

// Hosts one screen and animates it in and out: the outgoing page fades while
// the incoming one fades in and settles up from a small offset. Pages stay
// alive (state is kept); hidden ones stop rendering once fully faded.
Item {
    id: page
    property int index: 0
    property int current: 0
    readonly property bool active: index === current
    default property alias content: holder.data

    opacity: active ? 1 : 0
    visible: opacity > 0.001
    enabled: active
    Behavior on opacity { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

    Item {
        id: holder
        anchors.fill: parent
        transform: [
            Translate {
                y: page.active ? 0 : 24
                Behavior on y { NumberAnimation { duration: Theme.smooth + 80; easing.type: Easing.OutCubic } }
            },
            Scale {
                origin.x: holder.width / 2
                origin.y: holder.height / 2
                xScale: page.active ? 1 : 0.985
                yScale: xScale
                Behavior on xScale { NumberAnimation { duration: Theme.smooth + 80; easing.type: Easing.OutCubic } }
            }
        ]
    }
}
