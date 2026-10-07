import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS
import HomeOS.Core

// Display settings, from the gear in the nav rail: screen saver, dark mode,
// sleep, voice, Wi-Fi, speaker volume, restart, about this display, and
// re-pairing.
Popup {
    id: sheet
    modal: true
    // Lift the sheet while the Wi-Fi password keyboard is open.
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: {
        if (!parent)
            return 0
        var top = (parent.height - height) / 2
        if (passwordFocused)
            top -= parent.height * 0.22
        return Math.max(16, Math.round(top))
    }
    width: Math.min(parent ? parent.width - 64 : 1100, 1100)
    height: Math.min(parent ? parent.height - 48 : 760, content.implicitHeight + topPadding + bottomPadding)
    padding: Theme.compact ? 28 : 36
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    property string page: "main"          // main | wifi
    property bool confirmingRepair: false
    property string confirmingPower: ""   // "" | restart | reboot
    property string joinSsid: ""
    property bool passwordFocused: false
    onOpened: System.refresh()
    onClosed: {
        confirmingRepair = false
        confirmingPower = ""
        joinSsid = ""
        passwordFocused = false
        page = "main"
        Qt.inputMethod.hide()
    }
    onPageChanged: {
        if (page === "wifi")
            System.scanWifi()
        else
            joinSsid = ""
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.smooth }
            NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: Theme.smooth; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.smooth } }

    background: Rectangle { radius: 32; color: Theme.surface }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }

    readonly property string modeLabel: Store.mode === "demo" ? qsTr("Demo · sample data")
                                      : Store.mode === "pairing" ? qsTr("Waiting to be paired")
                                      : Store.online ? qsTr("Live · online") : qsTr("Live · offline")

    // Choices for Sleep → Turn screen off, in seconds; 0 is never.
    readonly property var offChoices: [0, 300, 600, 900, 1800, 3600, 7200, 14400]

    // The next choice up (dir > 0) or down from the current delay, which may
    // sit between two of them; undefined at either end.
    function offStep(dir) {
        const now = Device.offAfterSec
        if (dir > 0)
            return offChoices.find(sec => sec > now)
        return offChoices.slice().reverse().find(sec => sec < now)
    }

    function durationLabel(sec) {
        if (sec <= 0)
            return qsTr("Never")
        if (sec < 3600)
            return qsTr("%1 min").arg(Math.round(sec / 60))
        const hours = Math.round(sec / 360) / 10
        return hours === 1 ? qsTr("1 hour") : qsTr("%1 hours").arg(hours)
    }

    function clockLabel(minuteOfDay) {
        return Qt.formatTime(new Date(2000, 0, 1, Math.floor(minuteOfDay / 60), minuteOfDay % 60), "h:mm AP")
    }

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

    // − value + for a setting that moves in steps.
    component Stepper: RowLayout {
        id: stepper
        property string text: ""
        property bool canDown: true
        property bool canUp: true
        signal down()
        signal up()
        spacing: 6
        IconButton {
            icon: "minus"
            fill: Theme.surface
            implicitWidth: 52
            implicitHeight: 52
            enabled: stepper.canDown
            onClicked: stepper.down()
        }
        Label {
            Layout.preferredWidth: Theme.compact ? 100 : 112
            text: stepper.text
            color: Theme.text
            font.pixelSize: Theme.fontSm
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }
        IconButton {
            icon: "plus"
            fill: Theme.surface
            implicitWidth: 52
            implicitHeight: 52
            enabled: stepper.canUp
            onClicked: stepper.up()
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
                IconButton {
                    visible: sheet.page === "wifi"
                    icon: "left"
                    fill: Theme.surfaceAlt
                    onClicked: sheet.page = "main"
                }
                Column {
                    Layout.fillWidth: true
                    Label {
                        text: sheet.page === "wifi" ? qsTr("Wi-Fi") : qsTr("Settings")
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.weight: Font.DemiBold
                    }
                    Label {
                        text: sheet.page === "wifi"
                              ? (System.busy ? qsTr("Looking for networks…") : qsTr("Choose a network"))
                              : qsTr("This display")
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontSm
                    }
                }
                IconButton {
                    visible: sheet.page === "wifi"
                    icon: "refresh"
                    fill: Theme.surfaceAlt
                    enabled: !System.busy && System.canManageWifi
                    onClicked: System.scanWifi()
                }
                IconButton { icon: "close"; fill: Theme.surfaceAlt; onClicked: sheet.close() }
            }

            RowLayout {
                visible: sheet.page === "main"
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

                    SectionLabel { Layout.topMargin: 12; text: qsTr("DISPLAY") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: displayRows.implicitHeight
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: displayRows
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 18
                            anchors.rightMargin: 20
                            spacing: 0
                            SettingRow {
                                icon: "moon"
                                title: qsTr("Dark mode")
                                detail: qsTr("Warm dark background for the whole screen")
                                Toggle {
                                    checked: Device.darkMode
                                    onToggled: on => Device.darkMode = on
                                }
                            }
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                icon: "sparkle"
                                title: qsTr("Animated tiles")
                                detail: qsTr("Let the colors on Home and Rewards drift slowly")
                                Toggle {
                                    checked: Device.animatedTiles
                                    onToggled: on => Device.animatedTiles = on
                                }
                            }
                        }
                    }

                    SectionLabel { Layout.topMargin: 12; text: qsTr("SLEEP") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: sleepRows.implicitHeight
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: sleepRows
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 18
                            anchors.rightMargin: 20
                            spacing: 0
                            SettingRow {
                                icon: "clock"
                                title: qsTr("Turn screen off")
                                detail: Device.offAfterSec > 0
                                        ? qsTr("After %1 without a touch. A tap turns it back on.").arg(sheet.durationLabel(Device.offAfterSec))
                                        : qsTr("Never. The screen saver stays on.")
                                Stepper {
                                    text: sheet.durationLabel(Device.offAfterSec)
                                    canDown: sheet.offStep(-1) !== undefined
                                    canUp: sheet.offStep(1) !== undefined
                                    onDown: Device.offAfterSec = sheet.offStep(-1)
                                    onUp: Device.offAfterSec = sheet.offStep(1)
                                }
                            }
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                icon: "bed"
                                title: qsTr("Off overnight")
                                detail: qsTr("%1 to %2. Off once nobody is using it; a tap still wakes it.")
                                        .arg(sheet.clockLabel(Device.bedtime)).arg(sheet.clockLabel(Device.wakeTime))
                                Toggle {
                                    checked: Device.offAtNight
                                    onToggled: on => Device.offAtNight = on
                                }
                            }
                            Rectangle { visible: Device.offAtNight; Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                visible: Device.offAtNight
                                icon: "moon"
                                title: qsTr("Bedtime")
                                detail: qsTr("The screen saver turns off")
                                Stepper {
                                    text: sheet.clockLabel(Device.bedtime)
                                    onDown: Device.bedtime = Device.bedtime - 30
                                    onUp: Device.bedtime = Device.bedtime + 30
                                }
                            }
                            Rectangle { visible: Device.offAtNight; Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                visible: Device.offAtNight
                                icon: "sun"
                                title: qsTr("Wake up")
                                detail: qsTr("The screen saver comes back on")
                                Stepper {
                                    text: sheet.clockLabel(Device.wakeTime)
                                    onDown: Device.wakeTime = Device.wakeTime - 30
                                    onUp: Device.wakeTime = Device.wakeTime + 30
                                }
                            }
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                icon: "power"
                                title: qsTr("Turn off now")
                                detail: qsTr("Until someone taps the screen")
                                PillButton {
                                    text: qsTr("Turn off")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    onClicked: {
                                        sheet.close()
                                        Device.turnOffNow()
                                    }
                                }
                            }
                        }
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
                                detail: !Voice.available ? qsTr("Needs the Ohana voice service")
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

                    SectionLabel { visible: System.volumeAvailable; Layout.topMargin: 12; text: qsTr("SPEAKERS") }
                    Rectangle {
                        visible: System.volumeAvailable
                        Layout.fillWidth: true
                        Layout.preferredHeight: speakerRows.implicitHeight
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: speakerRows
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 18
                            anchors.rightMargin: 20
                            spacing: 0
                            SettingRow {
                                icon: System.muted ? "speaker-off" : "speaker"
                                title: qsTr("Screen speakers")
                                detail: System.muted
                                        ? qsTr("Off. This stops the hiss from the screen.")
                                        : qsTr("Built into the screen. Its own buttons still change how loud it is.")
                                Toggle {
                                    checked: !System.muted
                                    onToggled: on => System.setMuted(!on)
                                }
                            }
                            Rectangle { Layout.fillWidth: true; Layout.leftMargin: 68; height: 1; color: Theme.divider }
                            SettingRow {
                                enabled: !System.muted
                                icon: "speaker"
                                title: qsTr("Volume")
                                detail: System.muted ? qsTr("Turn the speakers on to change this.") : qsTr("Lower this if a hiss remains.")
                                RowLayout {
                                    spacing: 8
                                    enabled: !System.muted
                                    Label {
                                        text: Math.round(volume.value) + "%"
                                        color: Theme.textMuted
                                        font.pixelSize: Theme.fontXs
                                        Layout.preferredWidth: 48
                                    }
                                    Slider {
                                        id: volume
                                        from: 0
                                        to: 100
                                        stepSize: 1
                                        enabled: !System.muted
                                        value: System.volume < 0 ? 0 : System.volume
                                        implicitWidth: Theme.compact ? 160 : 200
                                        implicitHeight: 44
                                        onPressedChanged: if (!pressed) System.setVolume(Math.round(value))
                                        background: Rectangle {
                                            x: volume.leftPadding
                                            y: volume.topPadding + volume.availableHeight / 2 - 3
                                            implicitWidth: 160
                                            width: volume.availableWidth
                                            height: 6
                                            radius: 3
                                            color: Theme.divider
                                            Rectangle {
                                                width: volume.visualPosition * parent.width
                                                height: parent.height
                                                radius: 3
                                                color: Theme.accent
                                            }
                                        }
                                        handle: Rectangle {
                                            x: volume.leftPadding + volume.visualPosition * (volume.availableWidth - width)
                                            y: volume.topPadding + volume.availableHeight / 2 - height / 2
                                            width: 28
                                            height: 28
                                            radius: 14
                                            color: Theme.surface
                                            border.color: Theme.divider
                                        }
                                    }
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
                            Fact {
                                name: qsTr("Wi-Fi")
                                value: !System.wifiAvailable ? qsTr("Unavailable")
                                     : !System.wifiEnabled ? qsTr("Off")
                                     : (System.wifiSsid || qsTr("Not connected"))
                            }
                            Fact { name: qsTr("Address"); value: System.ipAddress || "—" }
                            Fact { name: qsTr("Version"); value: "Ohana " + Qt.application.version }
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

                    SectionLabel { Layout.topMargin: 12; text: qsTr("WI-FI") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: wifiCard.implicitHeight + 36
                        radius: 24
                        color: Theme.surfaceAlt
                        ColumnLayout {
                            id: wifiCard
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            spacing: 14
                            Label {
                                Layout.fillWidth: true
                                text: !System.wifiAvailable
                                      ? qsTr("This computer has no Wi-Fi controls.")
                                      : System.wifiSsid
                                      ? qsTr("Joined %1%2").arg(System.wifiSsid).arg(System.wifiSignal >= 0 ? qsTr(" · %1%").arg(System.wifiSignal) : "")
                                      : System.wifiEnabled ? qsTr("Not joined to a network.") : qsTr("Wi-Fi is off.")
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontXs + 1
                                wrapMode: Text.WordWrap
                            }
                            PillButton {
                                Layout.fillWidth: true
                                text: qsTr("Choose network")
                                fill: Theme.surface
                                ink: Theme.text
                                enabled: System.wifiAvailable
                                onClicked: sheet.page = "wifi"
                            }
                        }
                    }

                    SectionLabel { Layout.topMargin: 12; text: qsTr("POWER") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: power.implicitHeight + 36
                        radius: 24
                        color: sheet.confirmingPower === "" ? Theme.surfaceAlt : Qt.rgba(0.94, 0.5, 0.35, 0.14)
                        Behavior on color { ColorAnimation { duration: Theme.quick } }
                        ColumnLayout {
                            id: power
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            spacing: 14
                            Label {
                                Layout.fillWidth: true
                                text: sheet.confirmingPower === "reboot"
                                      ? qsTr("Reboot the Pi? The screen stays dark for about a minute.")
                                      : sheet.confirmingPower === "restart"
                                      ? qsTr("Restart Ohana? The screen goes blank for a few seconds.")
                                      : qsTr("Restart the app, or reboot the Pi, without unplugging it.")
                                color: sheet.confirmingPower === "" ? Theme.textMuted : Theme.text
                                font.pixelSize: Theme.fontXs + 1
                                wrapMode: Text.WordWrap
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                PillButton {
                                    visible: sheet.confirmingPower === ""
                                    Layout.fillWidth: true
                                    text: qsTr("Restart")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    onClicked: sheet.confirmingPower = "restart"
                                }
                                PillButton {
                                    visible: sheet.confirmingPower === ""
                                    Layout.fillWidth: true
                                    text: qsTr("Reboot")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    enabled: System.canReboot
                                    onClicked: sheet.confirmingPower = "reboot"
                                }
                                PillButton {
                                    visible: sheet.confirmingPower !== ""
                                    Layout.fillWidth: true
                                    text: qsTr("Cancel")
                                    fill: Theme.surface
                                    ink: Theme.text
                                    onClicked: sheet.confirmingPower = ""
                                }
                                PillButton {
                                    visible: sheet.confirmingPower !== ""
                                    Layout.fillWidth: true
                                    text: sheet.confirmingPower === "reboot" ? qsTr("Reboot") : qsTr("Restart")
                                    fill: "#E2604A"
                                    ink: "white"
                                    onClicked: {
                                        var which = sheet.confirmingPower
                                        sheet.close()
                                        if (which === "reboot")
                                            System.reboot()
                                        else
                                            System.restartApp()
                                    }
                                }
                            }
                        }
                    }

                    SectionLabel { Layout.topMargin: 12; text: qsTr("PAIRING") }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: repair.implicitHeight + 36
                        radius: 24
                        color: sheet.confirmingRepair ? Qt.rgba(0.94, 0.5, 0.35, 0.14) : Theme.surfaceAlt
                        Behavior on color { ColorAnimation { duration: Theme.quick } }

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

            ColumnLayout {
                visible: sheet.page === "wifi"
                Layout.fillWidth: true
                spacing: 12

                Rectangle {
                    visible: System.wifiAvailable
                    Layout.fillWidth: true
                    Layout.preferredHeight: radioRow.implicitHeight
                    radius: 24
                    color: Theme.surfaceAlt
                    ColumnLayout {
                        id: radioRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 18
                        anchors.rightMargin: 20
                        SettingRow {
                            icon: "wifi"
                            title: qsTr("Wi-Fi")
                            detail: System.wifiEnabled ? qsTr("On") : qsTr("Off")
                            Toggle {
                                enabled: System.canManageWifi && !System.busy
                                checked: System.wifiEnabled
                                onToggled: function (on) { System.setWifiEnabled(on) }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: sheet.joinSsid.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: joinBox.implicitHeight + 28
                    radius: 24
                    color: Theme.surfaceAlt
                    ColumnLayout {
                        id: joinBox
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 16
                        spacing: 12
                        Label {
                            text: qsTr("Join %1").arg(sheet.joinSsid)
                            color: Theme.text
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 64
                            radius: 32
                            color: Theme.surface
                            border.color: wifiPassword.activeFocus ? Theme.accent : Theme.divider
                            border.width: wifiPassword.activeFocus ? 2 : 1
                            TextField {
                                id: wifiPassword
                                anchors.fill: parent
                                anchors.leftMargin: 22
                                anchors.rightMargin: 22
                                placeholderText: qsTr("Password, usually 8 or more characters")
                                font.pixelSize: Theme.fontSm
                                color: Theme.text
                                placeholderTextColor: Theme.textMuted
                                background: null
                                echoMode: TextInput.Password
                                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                                onActiveFocusChanged: sheet.passwordFocused = activeFocus
                                onAccepted: System.connectWifi(sheet.joinSsid, text, false)
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            PillButton {
                                Layout.fillWidth: true
                                text: qsTr("Cancel")
                                fill: Theme.surface
                                ink: Theme.text
                                onClicked: sheet.joinSsid = ""
                            }
                            PillButton {
                                Layout.fillWidth: true
                                text: System.busy ? qsTr("Joining…") : qsTr("Join")
                                enabled: !System.busy && wifiPassword.text.length > 0
                                onClicked: System.connectWifi(sheet.joinSsid, wifiPassword.text, false)
                            }
                        }
                    }
                }

                Label {
                    visible: System.message.length > 0
                    Layout.fillWidth: true
                    text: System.message
                    color: Theme.text
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }

                Label {
                    visible: !System.wifiAvailable
                    Layout.fillWidth: true
                    text: qsTr("Wi-Fi controls are on the Pi. Run the display install again, then open this page.")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    visible: System.wifiAvailable
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(72, netCol.implicitHeight)
                    radius: 24
                    color: Theme.surfaceAlt
                    ColumnLayout {
                        id: netCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 0
                        Repeater {
                            model: System.networks
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 76
                                color: modelData.inUse ? Theme.accentSoft : "transparent"
                                radius: 18
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 18
                                    anchors.rightMargin: 18
                                    spacing: 14
                                    Icon { name: "wifi"; size: 22; color: Theme.text }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Label {
                                            text: modelData.ssid
                                            color: Theme.text
                                            font.pixelSize: Theme.fontSm
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Label {
                                            text: modelData.signal + "%"
                                                  + (modelData.secure ? (modelData.saved ? qsTr(" · Saved") : qsTr(" · Password")) : qsTr(" · Open"))
                                                  + (modelData.inUse ? qsTr(" · Connected") : "")
                                            color: Theme.textMuted
                                            font.pixelSize: Theme.fontXs
                                        }
                                    }
                                }
                                TapHandler {
                                    enabled: !modelData.inUse && !System.busy
                                    onTapped: {
                                        if (modelData.secure && !modelData.saved) {
                                            sheet.joinSsid = modelData.ssid
                                            wifiPassword.text = ""
                                            wifiPassword.forceActiveFocus()
                                        } else {
                                            sheet.joinSsid = ""
                                            System.connectWifi(modelData.ssid, "", modelData.saved)
                                        }
                                    }
                                }
                            }
                        }
                        Label {
                            visible: System.networks.length === 0 && !System.busy
                            Layout.fillWidth: true
                            Layout.margins: 18
                            text: System.wifiEnabled ? qsTr("No networks found. Try refresh.") : qsTr("Turn Wi-Fi on to look for networks.")
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontSm
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }
}
