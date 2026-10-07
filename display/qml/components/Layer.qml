import QtQuick
import QtQuick.Controls

// A slice of the window that must stay above the dialogs and sheets. Controls
// popups are drawn in the window's overlay, over all ordinary items whatever
// their z, so the on-screen keyboard, the toast, the screen saver and the
// wake-word card each sit in a Layer, stacked by z (see Main.qml).
//
// A Layer above a modal dialog still gets its presses: the overlay lets only
// the popups stacked above the pressed one filter a press, so the dialog under
// it neither swallows the tap nor closes. (On Qt 6.4 an Item moved into the
// overlay gets no such pass.) A Layer never dims, never takes focus from the
// field being typed into and never closes by itself. Only its own area takes
// input, so size it to its content.
Popup {
    modal: false
    dim: false
    focus: false
    closePolicy: Popup.NoAutoClose
    padding: 0
    margins: -1
    background: null
    enter: null
    exit: null
}
