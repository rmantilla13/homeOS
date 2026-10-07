import QtQuick
import HomeOS

// Scrolling body of a dialog or sheet that keeps the field being typed in on
// screen: when focus moves to a field inside it, and while it shrinks to make
// room for the on-screen keyboard. An edge fades out where there's more to
// scroll to that way.
Flickable {
    id: flick
    clip: true
    contentWidth: width
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds

    // What the edges fade into: the dialog's or sheet's own colour.
    property color fadeColor: Theme.surface
    readonly property int fadeHeight: 24
    // Half a pixel of slack: layout rounding isn't more to scroll to.
    readonly property bool moreAbove: contentY > 0.5
    readonly property bool moreBelow: contentY + height < contentHeight - 0.5

    readonly property Item focusItem: Window.activeFocusItem
    // Once the layout has caught up with whatever moved focus.
    onFocusItemChanged: Qt.callLater(reveal, true)
    // Follows the keyboard's slide frame by frame.
    onHeightChanged: reveal(false)

    function reveal(animate) {
        let y = contentY
        let inside = false
        for (let p = focusItem; p && !inside; p = p.parent)
            inside = p === contentItem
        if (inside) {
            // Clear of the edge fades.
            const pad = fadeHeight
            const top = focusItem.mapToItem(contentItem, 0, 0).y - pad
            const bottom = top + focusItem.height + 2 * pad
            if (top < y)
                y = top
            else if (bottom > y + height)
                y = bottom - height
        }
        y = Math.max(0, Math.min(y, contentHeight - height))
        if (animate && inside) {
            if (y !== contentY) {
                scroll.to = y
                scroll.restart()
            }
        } else {
            scroll.stop()
            contentY = y
        }
    }

    NumberAnimation {
        id: scroll
        target: flick
        property: "contentY"
        duration: Theme.smooth
        easing.type: Easing.OutCubic
    }

    // Over the content rather than in it, so they stay at the edges.
    Rectangle {
        parent: flick
        z: 1
        width: flick.width
        height: flick.fadeHeight
        opacity: flick.moreAbove ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.quick } }
        gradient: Gradient {
            GradientStop { position: 0; color: flick.fadeColor }
            GradientStop { position: 1; color: Qt.rgba(flick.fadeColor.r, flick.fadeColor.g, flick.fadeColor.b, 0) }
        }
    }
    Rectangle {
        parent: flick
        z: 1
        y: flick.height - height
        width: flick.width
        height: flick.fadeHeight
        opacity: flick.moreBelow ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.quick } }
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(flick.fadeColor.r, flick.fadeColor.g, flick.fadeColor.b, 0) }
            GradientStop { position: 1; color: flick.fadeColor }
        }
    }
}
