import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

// Minigames: a card per game; tapping one runs it in place, next to a panel
// with how to play and where the game comes from. 2048, Same Game and Maroon
// in Trouble are open-source games; Traffic Jam plays on open-source Rush
// Hour logic with levels made for Ohana; tic-tac-toe is our own.
//
// A game is loaded only while it's open, and closed when the family leaves
// the tab (the screen saver takes the display back to Home, so that covers
// going idle too). Nothing keeps ticking, animating or making sounds behind
// the other pages. Third-party code and licenses: display/games/README.md.
Item {
    id: games
    // This tab is showing (set by Main.qml).
    property bool shown: true
    property int openIndex: -1
    readonly property var openGame: openIndex >= 0 ? catalog[openIndex] : null
    // The running game's root item, or null.
    readonly property Item game: loader.item

    // `source` is the game's QML; `size` is a fixed-size game's own size,
    // scaled up to fit the stage (the rest fill it); `art` is the card picture.
    readonly property var catalog: [
        {
            title: qsTr("Traffic Jam"),
            tagline: qsTr("Slide the cars to get the red one out."),
            howTo: qsTr("Drag the cars and trucks along their lanes. Cars only go forward and back. Clear a path so the red car can drive out of the exit on the right. 40 levels, from beginner to expert."),
            players: qsTr("1 player"),
            credit: qsTr("Rush Hour board logic by Michael Fogleman (MIT License). Levels made for Ohana."),
            source: "../games/TrafficJam.qml",
            art: artTraffic
        },
        {
            title: qsTr("Tic-tac-toe"),
            tagline: qsTr("Three in a row wins."),
            howTo: qsTr("Take turns tapping a square. The first to get three in a row, across, down or corner to corner, wins. Play someone at the screen, or play Ohana: Easy is beatable, Hard never loses."),
            players: qsTr("1–2 players"),
            credit: qsTr("Made for Ohana."),
            source: "../games/TicTacToe.qml",
            art: artTicTacToe
        },
        {
            title: "2048",
            tagline: qsTr("Slide and join the tiles to reach 2048."),
            howTo: qsTr("Swipe up, down, left or right to slide every tile. Two tiles with the same number join into one. Make a 2048 tile to win, then keep going."),
            players: qsTr("1 player"),
            credit: qsTr("2048 by Gabriele Cirulli. MIT License."),
            source: "../games/Game2048.qml",
            art: art2048
        },
        {
            title: "Same Game",
            tagline: qsTr("Clear the board one color at a time."),
            howTo: qsTr("Tap a group of two or more matching blocks to clear it. Bigger groups score more. Play alone, take turns with someone across the board, relax in Zen or solve puzzles."),
            players: qsTr("1–2 players"),
            credit: qsTr("Same Game, a Qt demo by The Qt Company. BSD-3-Clause."),
            source: "../../games/samegame/samegame.qml",
            size: Qt.size(320, 480),
            art: artSameGame
        },
        {
            title: "Maroon in Trouble",
            tagline: qsTr("Pop the bubbles and save the fish."),
            howTo: qsTr("Clownfish in bubbles float up from the deep. Tap the sea to place helpers that pop the bubbles before they reach the surface: starfish make coins, crabs, octopuses and pufferfish pop bubbles."),
            players: qsTr("1 player"),
            credit: qsTr("Maroon in Trouble, a Qt demo by The Qt Company. BSD-3-Clause."),
            source: "../../games/maroon/maroon.qml",
            size: Qt.size(320, 480),
            art: artMaroon
        }
    ]

    function open(index) { openIndex = index }
    function close() { openIndex = -1 }
    onShownChanged: if (!shown) close()

    // ---- The list of games
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing
        visible: games.openGame === null

        Column {
            Layout.fillWidth: true
            Label { text: qsTr("Games"); color: Theme.text; font.pixelSize: Theme.compact ? 34 : Theme.fontXl; font.weight: Font.Medium }
            Label { text: qsTr("Puzzles and games for the whole family"); color: Theme.textMuted; font.pixelSize: Theme.fontSm }
        }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 3
            rowSpacing: Theme.spacing
            columnSpacing: Theme.spacing

            Repeater {
                model: games.catalog
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 1
                    radius: Theme.radius
                    color: Theme.surface
                    scale: cardTap.pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.quick } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.compact ? 14 : 20
                        spacing: 6

                        Loader {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.bottomMargin: 6
                            sourceComponent: card.modelData.art
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label {
                                Layout.fillWidth: true
                                text: card.modelData.title
                                color: Theme.text
                                font.pixelSize: Theme.compact ? Theme.fontMd : Theme.fontLg
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Tag { text: card.modelData.players }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: card.modelData.tagline
                            color: Theme.textMuted
                            font.pixelSize: Theme.compact ? Theme.fontXs : Theme.fontSm
                            elide: Text.ElideRight
                        }
                    }
                    TapHandler { id: cardTap; onTapped: games.open(card.index) }
                }
            }
        }
    }

    // ---- Card art, drawn from each game's own colors and graphics
    Component {
        id: artTraffic
        Rectangle {
            radius: Theme.radiusSm
            color: Theme.sunken
            Item {
                id: lot
                readonly property real cell: Math.min(parent.width, parent.height) * 0.8 / 6
                width: cell * 6
                height: cell * 6
                anchors.centerIn: parent
                Rectangle {
                    x: lot.width - 2
                    y: lot.cell * 2 + lot.cell * 0.1
                    width: lot.cell * 0.5
                    height: lot.cell * 0.8
                    radius: 4
                    color: Theme.surface
                }
                // [column, row, length, horizontal, color]: a level's opening position.
                Repeater {
                    model: [[0, 2, 2, true, "#E5484D"], [2, 1, 3, false, "#5B8DEF"], [3, 0, 3, true, "#F2B84B"],
                            [4, 2, 2, false, "#3DB37A"], [0, 4, 2, true, "#8E7CE6"], [5, 3, 3, false, "#EF8A6F"],
                            [1, 0, 2, false, "#5FB3B3"]]
                    delegate: Rectangle {
                        required property var modelData
                        x: modelData[0] * lot.cell + lot.cell * 0.06
                        y: modelData[1] * lot.cell + lot.cell * 0.06
                        width: (modelData[3] ? modelData[2] : 1) * lot.cell - lot.cell * 0.12
                        height: (modelData[3] ? 1 : modelData[2]) * lot.cell - lot.cell * 0.12
                        radius: lot.cell * 0.2
                        color: modelData[4]
                    }
                }
            }
        }
    }
    Component {
        id: artTicTacToe
        Rectangle {
            radius: Theme.radiusSm
            color: Theme.sunken
            Grid {
                id: ttt
                readonly property real cell: Math.min(parent.width, parent.height) * 0.26
                anchors.centerIn: parent
                columns: 3
                spacing: cell * 0.08
                Repeater {
                    model: ["X", "O", "", "", "X", "O", "", "", "X"]
                    delegate: Rectangle {
                        required property string modelData
                        width: ttt.cell
                        height: ttt.cell
                        radius: Theme.radiusSm
                        color: Theme.surface
                        Repeater {
                            model: modelData === "X" ? [45, -45] : []
                            delegate: Rectangle {
                                required property real modelData
                                anchors.centerIn: parent
                                width: ttt.cell * 0.62
                                height: ttt.cell * 0.12
                                radius: height / 2
                                rotation: modelData
                                color: "#F07F5A"
                            }
                        }
                        Rectangle {
                            visible: modelData === "O"
                            anchors.centerIn: parent
                            width: ttt.cell * 0.5
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: ttt.cell * 0.1
                            border.color: "#4F7CF7"
                        }
                    }
                }
            }
        }
    }
    Component {
        id: art2048
        Rectangle {
            radius: Theme.radiusSm
            color: "#faf8ef"
            Grid {
                id: mini
                readonly property real cell: Math.min(parent.width, parent.height) * 0.3
                anchors.centerIn: parent
                columns: 2
                spacing: cell * 0.12
                Repeater {
                    model: [{ v: 2, c: "#eee4da" }, { v: 8, c: "#f2b179" }, { v: 64, c: "#f65e3b" }, { v: 2048, c: "#edc22e" }]
                    delegate: Rectangle {
                        required property var modelData
                        width: mini.cell
                        height: mini.cell
                        radius: 6
                        color: modelData.c
                        Label {
                            anchors.centerIn: parent
                            text: modelData.v
                            color: modelData.v <= 4 ? "#776e65" : "#f9f6f2"
                            font.pixelSize: mini.cell * (modelData.v > 1000 ? 0.3 : 0.45)
                            font.bold: true
                        }
                    }
                }
            }
        }
    }
    Component {
        id: artSameGame
        Rectangle {
            radius: Theme.radiusSm
            color: "#ececec"
            Column {
                anchors.centerIn: parent
                spacing: 18
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: ["s", "a", "m", "e"]
                        delegate: Image {
                            required property string modelData
                            source: Qt.resolvedUrl("../../games/samegame/content/gfx/logo-" + modelData + ".png")
                        }
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: ["red", "green", "blue", "yellow"]
                        delegate: Image {
                            required property string modelData
                            source: Qt.resolvedUrl("../../games/samegame/content/gfx/" + modelData + ".png")
                        }
                    }
                }
            }
        }
    }
    Component {
        id: artMaroon
        Rectangle {
            radius: Theme.radiusSm
            gradient: Gradient {
                GradientStop { position: 0; color: "#97cfe5" }
                GradientStop { position: 1; color: "#276280" }
            }
            Image {
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.9, sourceSize.width)
                height: width * sourceSize.height / Math.max(1, sourceSize.width)
                source: Qt.resolvedUrl("../../games/maroon/content/gfx/logo.png")
            }
        }
    }

    // ---- An open game
    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.pageMargin
        spacing: Theme.spacing
        visible: games.openGame !== null

        ColumnLayout {
            Layout.fillHeight: true
            Layout.preferredWidth: Theme.compact ? 300 : 380
            Layout.maximumWidth: Theme.compact ? 300 : 380
            spacing: 16

            PillButton {
                text: qsTr("‹  All games")
                fill: Theme.surface
                ink: Theme.text
                onClicked: games.close()
            }
            Label {
                Layout.fillWidth: true
                Layout.topMargin: 8
                text: games.openGame ? games.openGame.title : ""
                color: Theme.text
                font.pixelSize: Theme.compact ? 34 : Theme.fontXl
                font.weight: Font.Medium
                wrapMode: Text.WordWrap
            }
            Tag { text: games.openGame ? games.openGame.players : "" }
            Label {
                Layout.fillWidth: true
                text: games.openGame ? games.openGame.howTo : ""
                color: Theme.text
                font.pixelSize: Theme.fontSm
                lineHeight: 1.2
                wrapMode: Text.WordWrap
            }
            Item { Layout.fillHeight: true }
            Label {
                Layout.fillWidth: true
                text: games.openGame ? games.openGame.credit : ""
                color: Theme.textMuted
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
            }
        }

        // The game, centered and as large as fits.
        Item {
            id: stage
            Layout.fillWidth: true
            Layout.fillHeight: true

            Item {
                id: frame
                readonly property size size: games.openGame && games.openGame.size ? games.openGame.size : Qt.size(0, 0)
                readonly property bool fixed: size.width > 0
                readonly property real fit: fixed ? Math.min(stage.width / size.width, stage.height / size.height) : 1
                width: fixed ? size.width * fit : stage.width
                height: fixed ? size.height * fit : stage.height
                anchors.centerIn: parent
                // Fixed-size games draw past their edges (Maroon slides its
                // screens in from above and below).
                clip: true

                Loader {
                    id: loader
                    width: frame.fixed ? frame.size.width : frame.width
                    height: frame.fixed ? frame.size.height : frame.height
                    scale: frame.fit
                    transformOrigin: Item.TopLeft
                    focus: true
                    active: games.openGame !== null
                    source: active ? Qt.resolvedUrl(games.openGame.source) : ""
                    onLoaded: item.forceActiveFocus() // arrow keys on a desktop
                    onStatusChanged: if (status === Loader.Error) console.warn("Games: could not load", source)
                }
                // Same Game's own Quit button.
                Connections {
                    target: loader.item
                    ignoreUnknownSignals: true
                    function onQuitRequested() { games.close() }
                }
            }
            // Round the frame's corners by painting the page color over them.
            Rectangle {
                visible: frame.fixed
                anchors.fill: frame
                anchors.margins: -Theme.radiusSm
                radius: Theme.radiusSm * 2
                color: "transparent"
                border.width: Theme.radiusSm
                border.color: Theme.background
            }
        }
    }
}
