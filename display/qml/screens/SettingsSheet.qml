import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Display settings, from the gear in the nav rail: screen saver style, voice
// (wake word, spoken replies), about this display, and re-pairing.
Popup {
    id: sheet
    modal: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(parent ? parent.width - 64 : 1100, 1100)
    height: Math.min(parent ? parent.height - 48 : 760, content.implicitHeight + topPadding + bottomPadding)
    padding: Theme.compact ? 28 : 36
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    property bool confirmingRepair: false
    onClosed: confirmingRepair = false

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.smooth }
            NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: Theme.smooth; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.quick } }

    background: Rectangle { radius: 32; color: Theme.surface }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }

    readonly property string modeLabel: Store.mode === "demo" ? qsTr("Demo · sample data")
                                      : Store.mode === "pairing" ? qsTr("Waiting to be paired")
                                      : Store.online ? qsTr("Live · online") : qsTr("Live · offline")

    // Small caps heading above each group.
    component SectionLabel: Label {
        color: Theme.textMuted
        font.pixelSize: Theme.fontXs
        font.weight: Font.DemiBold
        font.letterSpacing: 1.2
    }

    // A labelled row inside a group: round icon, title and detail, then a control.
    component SettingRow: RowLayout {
        id: row
        property string icon: ""
        property string title: ""
        property string detail: ""
        default property alias control: slot.data
        spacing: 16
        Layout.fillWidth: true
        Layout.preferredHeight: 84
        Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 26
            color: Theme.surface
            Icon { anchors.centerIn: parent; name: row.icon; size: 24; color: Theme.text }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Label { text: row.title; color: Theme.text; font.pixelSize: Theme.fontSm + 1; font.weight: Font.DemiBold }
            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: row.detail
                color: Theme.textMuted
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
            }
        }
        Item {
            id: slot
            Layout.preferredWidth: childrenRect.width
            Layout.preferredHeight: childrenRect.height
        }
    }

    // One fact in the About group.
    component Fact: RowLayout {
        id: fact
        property string name: ""
        property string value: ""
        property color dot: "transparent"
        Layout.fillWidth: true
        Layout.preferredHeight: 46
        spacing: 10
        Label { text: fact.name; color: Theme.textMuted; font.pixelSize: Theme.fontSm - 1; Layout.preferredWidth: 130 }
        Rectangle {
            visible: fact.dot.a > 0
            Layout.preferredWidth: 10
            Layout.preferredHeight: 10
            radius: 5
            color: fact.dot
        }
        Label {
            Layout.fillWidth: true
            text: fact.value
            color: Theme.text
            font.pixelSize: Theme.fontSm - 1
            font.weight: Font.Medium
            elide: Text.ElideRight
        }
    }

    contentItem: Flickable {
        clip: true
        contentWidth: width
        contentHeight: content.implicitHeight
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: content
            width: parent.width
            spacing: Theme.compact ? 20 : 26

            RowLayout {
                Layout.fillWidth: true
                Column {
                    Layout.fillWidth: true
                    Label { text: qsTr("Settings"); color: Theme.text; font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                    Label { text: qsTr("This display"); color: Theme.textMuted; font.pixelSize: Theme.fontSm }
                }
                IconButton { icon: "close"; fill: Theme.surfaceAlt; onClicked: sheet.close() }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.compact ? 24 : 32

                // Left: screen saver and voice.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 3
                    Layout.alignment: Qt.AlignTop
                    spacing: 12

                    SectionLabel { text: qsTr("SCREEN SAVER") }
                    ScreenSaverOptions {
                        Layout.fillWidth: true
                        cardHeight: Theme.compact ? 176 : 200
                        spacing: 12
                    }

                    SectionLabel { Layout.topMargin: 12; text: qsTr("VOICE") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: voiceRows.implicitHeight
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: voiceRows
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 18
                            anchors.rightMargin: 20
                            spacing: 0
                            SettingRow {
                                icon: Voice.available ? "mic" : "mic-off"
                                title: qsTr("Wake word")
                                detail: !Voice.available ? qsTr("Needs the homeOS voice service")
                                      : Voice.wakewordLabel ? qsTr("Say “%1” to ask a quick question").arg(Voice.wakewordLabel)
                                      : qsTr("Ask a quick question hands-free")
                                Toggle {
                                    enabled: Voice.available
                                    checked: Voice.available && Voice.wakewordEnabled
                                    onToggled: on => Voice.setWakewordEnabled(on)
                                }
                            }
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                icon: "speaker"
                                title: qsTr("Spoken replies")
                                detail: qsTr("Read quick answers out loud")
                                Toggle {
                                    checked: Voice.speakReplies
                                    onToggled: on => Voice.speakReplies = on
                                }
                            }
                        }
                    }
                }

                // Right: about and re-pair.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 2
                    Layout.alignment: Qt.AlignTop
                    spacing: 12

                    SectionLabel { text: qsTr("ABOUT") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: facts.implicitHeight + 20
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: facts
                            anchors.fill: parent
                            anchors.margins: 10
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            spacing: 0
                            Fact { name: qsTr("Mode"); value: sheet.modeLabel }
                            Fact { name: qsTr("Family"); value: Store.familyName || "—" }
                            Fact { name: qsTr("Version"); value: "homeOS " + Qt.application.version }
                            Fact {
                                name: qsTr("Voice service")
                                value: Voice.available ? qsTr("Connected") : qsTr("Not running")
                                dot: Voice.available ? Theme.success : Theme.textMuted
                            }
                            Fact {
                                name: qsTr("Wake word")
                                value: !Voice.available ? "—"
                                     : (Voice.wakewordLabel || qsTr("None")) + (Voice.wakewordEnabled ? "" : qsTr(" · off"))
                            }
                        }
                    }

                    SectionLabel { Layout.topMargin: 12; text: qsTr("PAIRING") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: repair.implicitHeight + 36
                        radius: 24
                        color: sheet.confirmingRepair ? Qt.rgba(0.94, 0.5, 0.35, 0.14) : Theme.surfaceAlt
                        Behavior on color { ColorAnimation { duration: Theme.smooth } }

                        ColumnLayout {
                            id: repair
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            spacing: 14

                            Label {
                                Layout.fillWidth: true
                                text: sheet.confirmingRepair
                                      ? qsTr("Re-pair this display? It forgets %1 and shows a new code to enter in the iOS app.")
                                            .arg(Store.familyName || qsTr("this family"))
                                      : Store.mode === "demo" ? qsTr("Pairing isn't available in demo mode.")
                                      : qsTr("Move this screen to another family, or pair it again after a reset.")
                                color: sheet.confirmingRepair ? Theme.text : Theme.textMuted
                                font.pixelSize: Theme.fontXs + 1
                                wrapMode: Text.WordWrap
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                PillButton {
                                    visible: !sheet.confirmingRepair
                                    Layout.fillWidth: true
                                    text: qsTr("Re-pair this display")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    enabled: Store.mode === "live"
                                    onClicked: sheet.confirmingRepair = true
                                }
                                PillButton {
                                    visible: sheet.confirmingRepair
                                    Layout.fillWidth: true
                                    text: qsTr("Cancel")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    onClicked: sheet.confirmingRepair = false
                                }
                                PillButton {
                                    visible: sheet.confirmingRepair
                                    Layout.fillWidth: true
                                    text: qsTr("Re-pair")
                                    fill: "#E2604A"
                                    ink: "white"
                                    onClicked: { sheet.close(); Store.unpair() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
