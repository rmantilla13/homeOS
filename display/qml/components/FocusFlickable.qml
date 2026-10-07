import QtQuick
import HomeOS

// Scrolling body of a dialog or sheet that keeps the field being typed in on
// screen: when focus moves to a field inside it, and while it shrinks to make
// room for the on-screen keyboard.
Flickable {
    id: flick
    clip: true
    contentWidth: width
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds

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
            const pad = 16
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
}
