// 2048 on the wall display: swipe the board to slide the tiles.
//
// The rules are the original game's, unchanged in game.js (MIT, see LICENSE).
// This file rebuilds the browser side for Qt Quick: swipes and the arrow keys
// stand in for keyboard_input_manager.js, the board below for html_actuator.js
// and main.scss (same colors, same 100 ms slide and 200 ms pop), and
// LocalStorage for local_storage_manager.js. Moves only touch memory; the best
// score and the game in progress are written when the game closes, so a swipe
// never waits on the SD card.
import QtQuick
import QtQuick.Controls
import QtQuick.LocalStorage
import "../../games/2048/game.js" as Game

Rectangle {
    id: game

    property int score: 0
    property int best: 0
    property bool over: false
    property bool won: false
    property bool terminated: false
    // Tiles to draw after the last move, in html_actuator.js's terms: kind is
    // "moved" (slides from fromX/fromY), "merged" (pops in over the two tiles
    // that slid into it) or "new" (appears).
    property var tiles: []
    property var manager: null
    // Upstream InputManager callbacks, by event name.
    property var events: ({})
    // What local_storage_manager.js keeps: bestScore and gameState, as strings.
    property var saved: ({})

    readonly property int pad: 24
    readonly property color ink: "#776e65"
    readonly property color brightInk: "#f9f6f2"

    // 0 up, 1 right, 2 down, 3 left (game_manager.js).
    function move(direction) { emit("move", direction) }
    function restart() { emit("restart") }
    function keepPlaying() { emit("keepPlaying") }
    function emit(event, data) { (events[event] || []).forEach(callback => callback(data)) }

    function actuate(grid, metadata) {
        const list = []
        grid.cells.forEach(column => column.forEach(cell => { if (cell) addTile(list, cell) }))
        tiles = list
        const gained = metadata.score - score
        score = metadata.score
        best = metadata.bestScore
        over = metadata.over
        won = metadata.won
        terminated = metadata.terminated
        if (gained > 0) {
            gain.text = "+" + gained
            gainAnim.restart()
        }
    }
    function addTile(list, tile) {
        const from = tile.previousPosition || { x: tile.x, y: tile.y }
        const kind = tile.previousPosition ? "moved" : tile.mergedFrom ? "merged" : "new"
        list.push({ value: tile.value, x: tile.x, y: tile.y, fromX: from.x, fromY: from.y, kind: kind })
        if (kind === "merged")
            tile.mergedFrom.forEach(merged => addTile(list, merged))
    }

    function tileColor(value) {
        return ({ 2: "#eee4da", 4: "#ede0c8", 8: "#f2b179", 16: "#f59563", 32: "#f67c5f",
                  64: "#f65e3b", 128: "#edcf72", 256: "#edcc61", 512: "#edc850",
                  1024: "#edc53f", 2048: "#edc22e" })[value] || "#3c3a32"
    }
    // Font size as a share of the tile (55, 45, 35 and 30 px on a 106 px tile).
    function textScale(value) {
        return value < 100 ? 0.52 : value < 1000 ? 0.42 : value <= 2048 ? 0.33 : 0.28
    }

    function database() {
        try {
            return LocalStorage.openDatabaseSync("Ohana2048", "1.0", "2048 best score and game in progress", 100000)
        } catch (e) {
            console.warn("2048: no LocalStorage, scores are kept until the game closes:", e)
            return null
        }
    }
    function load() {
        const db = database()
        if (!db) return
        try {
            db.transaction(tx => {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT)")
                const rows = tx.executeSql("SELECT key, value FROM kv").rows
                for (let i = 0; i < rows.length; ++i)
                    saved[rows.item(i).key] = rows.item(i).value
            })
        } catch (e) {
            console.warn("2048: could not read the saved game:", e)
        }
    }
    function save() {
        const db = database()
        if (!db) return
        try {
            db.transaction(tx => {
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT)")
                tx.executeSql("DELETE FROM kv")
                for (const key in saved)
                    tx.executeSql("INSERT INTO kv VALUES (?, ?)", [key, saved[key]])
            })
        } catch (e) {
            console.warn("2048: could not save the game:", e)
        }
    }

    Component.onCompleted: {
        load()
        const view = game
        const InputManager = function () {}
        InputManager.prototype.on = function (event, callback) {
            (view.events[event] = view.events[event] || []).push(callback)
        }
        const Actuator = function () {}
        Actuator.prototype.actuate = function (grid, metadata) { view.actuate(grid, metadata) }
        Actuator.prototype.continueGame = function () {
            view.over = false
            view.won = false
            view.terminated = false
        }
        const StorageManager = function () {}
        StorageManager.prototype.getBestScore = function () { return Number(view.saved.bestScore) || 0 }
        StorageManager.prototype.setBestScore = function (value) { view.saved.bestScore = String(value) }
        StorageManager.prototype.getGameState = function () {
            try {
                return view.saved.gameState ? JSON.parse(view.saved.gameState) : null
            } catch (e) {
                return null
            }
        }
        StorageManager.prototype.setGameState = function (state) { view.saved.gameState = JSON.stringify(state) }
        StorageManager.prototype.clearGameState = function () { delete view.saved.gameState }
        manager = new Game.GameManager(4, InputManager, Actuator, StorageManager)
    }
    Component.onDestruction: save()

    color: "#faf8ef"
    radius: 18
    focus: true

    Keys.onPressed: event => {
        const direction = { [Qt.Key_Up]: 0, [Qt.Key_Right]: 1, [Qt.Key_Down]: 2, [Qt.Key_Left]: 3,
                            [Qt.Key_W]: 0, [Qt.Key_D]: 1, [Qt.Key_S]: 2, [Qt.Key_A]: 3 }[event.key]
        if (direction !== undefined) {
            game.move(direction)
            event.accepted = true
        } else if (event.key === Qt.Key_R) {
            game.restart()
            event.accepted = true
        }
    }

    // A swipe anywhere on the game moves the tiles; the buttons sit on top.
    MouseArea {
        anchors.fill: parent
        property point start
        onPressed: mouse => start = Qt.point(mouse.x, mouse.y)
        onReleased: mouse => {
            const dx = mouse.x - start.x
            const dy = mouse.y - start.y
            if (Math.max(Math.abs(dx), Math.abs(dy)) < 30)
                return
            game.move(Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0))
        }
    }

    Item {
        id: header
        x: board.x
        y: game.pad
        width: board.width
        height: 96

        Label {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "2048"
            color: game.ink
            font.pixelSize: 64
            font.bold: true
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            ScoreBox {
                label: qsTr("SCORE")
                value: game.score
                // Points from the last move float up out of the score.
                Label {
                    id: gain
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Qt.rgba(119 / 255, 110 / 255, 101 / 255, 0.9)
                    font.pixelSize: 30
                    font.bold: true
                    opacity: 0
                }
            }
            ScoreBox { label: qsTr("BEST"); value: game.best }

            Rectangle {
                width: newGameLabel.implicitWidth + 48
                height: 76
                radius: 6
                color: "#8f7a66"
                scale: newGameTap.pressed ? 0.96 : 1
                Label {
                    id: newGameLabel
                    anchors.centerIn: parent
                    text: qsTr("New Game")
                    color: game.brightInk
                    font.pixelSize: 22
                    font.bold: true
                }
                TapHandler { id: newGameTap; onTapped: game.restart() }
            }
        }
    }

    ParallelAnimation {
        id: gainAnim
        NumberAnimation { target: gain; property: "y"; from: 20; to: -60; duration: 600; easing.type: Easing.InQuad }
        NumberAnimation { target: gain; property: "opacity"; from: 1; to: 0; duration: 600; easing.type: Easing.InQuad }
    }

    component ScoreBox: Rectangle {
        id: box
        property string label
        property int value
        width: Math.max(110, scoreColumn.implicitWidth + 40)
        height: 76
        radius: 6
        color: "#bbada0"
        Column {
            id: scoreColumn
            anchors.centerIn: parent
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: box.label
                color: "#eee4da"
                font.pixelSize: 15
                font.bold: true
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: box.value
                color: "white"
                font.pixelSize: 30
                font.bold: true
            }
        }
    }

    Rectangle {
        id: board
        readonly property real gap: width * 0.03          // 15 px on the 500 px web board
        readonly property real cell: (width - gap * 5) / 4
        function at(i) { return gap + i * (cell + gap) }

        anchors.horizontalCenter: parent.horizontalCenter
        y: header.y + header.height + game.pad
        width: Math.max(0, Math.min(game.width - 2 * game.pad, game.height - y - game.pad))
        height: width
        radius: 8
        color: "#bbada0"

        Repeater {
            model: 16
            delegate: Rectangle {
                required property int index
                x: board.at(index % 4)
                y: board.at(Math.floor(index / 4))
                width: board.cell
                height: board.cell
                radius: 5
                color: Qt.rgba(238 / 255, 228 / 255, 218 / 255, 0.35)
            }
        }

        Repeater {
            model: game.tiles
            delegate: Rectangle {
                id: tile
                required property var modelData
                // 1 at the previous cell, 0 at the new one.
                property real slide: modelData.kind === "moved" ? 1 : 0
                x: board.at(modelData.x) + (board.at(modelData.fromX) - board.at(modelData.x)) * slide
                y: board.at(modelData.y) + (board.at(modelData.fromY) - board.at(modelData.y)) * slide
                z: modelData.kind === "merged" ? 2 : 1
                width: board.cell
                height: board.cell
                radius: 5
                color: game.tileColor(modelData.value)
                scale: modelData.kind === "moved" ? 1 : 0

                Label {
                    anchors.centerIn: parent
                    text: tile.modelData.value
                    color: tile.modelData.value <= 4 ? game.ink : game.brightInk
                    font.pixelSize: Math.max(1, board.cell * game.textScale(tile.modelData.value))
                    font.bold: true
                }

                NumberAnimation on slide {
                    running: tile.modelData.kind === "moved"
                    from: 1; to: 0; duration: 100; easing.type: Easing.InOutQuad
                }
                SequentialAnimation on scale {
                    running: tile.modelData.kind === "new"
                    PauseAnimation { duration: 100 }
                    NumberAnimation { from: 0; to: 1; duration: 200; easing.type: Easing.InOutQuad }
                }
                SequentialAnimation on scale {
                    running: tile.modelData.kind === "merged"
                    PauseAnimation { duration: 100 }
                    NumberAnimation { from: 0; to: 1.2; duration: 100; easing.type: Easing.InOutQuad }
                    NumberAnimation { from: 1.2; to: 1; duration: 100; easing.type: Easing.InOutQuad }
                }
            }
        }

        // "You win!" / "Game over!" fades in over the board once the last tiles settle.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            z: 3
            color: game.won ? Qt.rgba(237 / 255, 194 / 255, 46 / 255, 0.5) : Qt.rgba(238 / 255, 228 / 255, 218 / 255, 0.73)
            opacity: game.terminated ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                SequentialAnimation {
                    PauseAnimation { duration: game.terminated ? 1200 : 0 }
                    NumberAnimation { duration: game.terminated ? 800 : 0 }
                }
            }
            // Swallow taps so the board underneath stays put.
            MouseArea { anchors.fill: parent }

            Column {
                anchors.centerIn: parent
                spacing: 32
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: game.won ? qsTr("You win!") : qsTr("Game over!")
                    color: game.won ? game.brightInk : game.ink
                    font.pixelSize: 60
                    font.bold: true
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 16
                    Repeater {
                        model: game.won ? [{ text: qsTr("Keep going"), keep: true }, { text: qsTr("Try again"), keep: false }]
                                        : [{ text: qsTr("Try again"), keep: false }]
                        delegate: Rectangle {
                            required property var modelData
                            width: messageLabel.implicitWidth + 48
                            height: 72
                            radius: 6
                            color: "#8f7a66"
                            scale: messageTap.pressed ? 0.96 : 1
                            Label {
                                id: messageLabel
                                anchors.centerIn: parent
                                text: modelData.text
                                color: game.brightInk
                                font.pixelSize: 22
                                font.bold: true
                            }
                            TapHandler {
                                id: messageTap
                                onTapped: modelData.keep ? game.keepPlaying() : game.restart()
                            }
                        }
                    }
                }
            }
        }
    }
}
