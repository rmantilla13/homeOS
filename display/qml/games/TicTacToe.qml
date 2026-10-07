import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

// Tic-tac-toe for two people at the screen, or one against Ohana. Easy
// Ohana often plays at random; Hard looks ahead to the end (minimax) and
// never loses. Who goes first alternates every round, and the score is
// kept until the game is closed.
Item {
    id: game

    property bool vsComputer: false
    property bool hard: false
    property var cells: ["", "", "", "", "", "", "", "", ""]
    property string turn: "X"
    property string starter: "X"
    property var winLine: null
    readonly property bool draw: !winLine && cells.every(c => c !== "")
    readonly property bool over: winLine !== null || draw
    readonly property string winner: winLine ? cells[winLine[0]] : ""
    readonly property bool computerTurn: vsComputer && turn === "O" && !over
    property var score: ({ X: 0, O: 0, draw: 0 })
    // Lets the computer's move land a beat after the player's.
    property int thinkMs: 450

    readonly property color xColor: "#F07F5A"
    readonly property color oColor: "#4F7CF7"
    readonly property var lines: [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    function findLine(board) {
        for (const l of lines) {
            if (board[l[0]] && board[l[0]] === board[l[1]] && board[l[0]] === board[l[2]])
                return l
        }
        return null
    }

    // The best square for `player`: wins soonest, loses latest, and picks at
    // random between equally good squares so games don't repeat.
    function bestMove(board, player) {
        board = Array.from(board)
        const empty = board.map((c, i) => c ? -1 : i).filter(i => i >= 0)
        if (empty.length === 9)
            return [0, 2, 4, 6, 8][Math.floor(Math.random() * 5)] // every opening draws
        const other = p => p === "X" ? "O" : "X"
        const value = (turnNow, depth) => {
            const line = findLine(board)
            if (line)
                return board[line[0]] === player ? 10 - depth : depth - 10
            if (board.every(c => c))
                return 0
            let bestValue = turnNow === player ? -100 : 100
            for (let i = 0; i < 9; ++i) {
                if (board[i])
                    continue
                board[i] = turnNow
                const v = value(other(turnNow), depth + 1)
                board[i] = ""
                bestValue = turnNow === player ? Math.max(bestValue, v) : Math.min(bestValue, v)
            }
            return bestValue
        }
        let top = -1000, choices = []
        for (const i of empty) {
            board[i] = player
            const v = value(other(player), 1)
            board[i] = ""
            if (v > top) {
                top = v
                choices = [i]
            } else if (v === top) {
                choices.push(i)
            }
        }
        return choices[Math.floor(Math.random() * choices.length)]
    }

    function place(cell) {
        if (over || cells[cell] !== "")
            return false
        const next = cells.slice()
        next[cell] = turn
        cells = next
        winLine = findLine(next)
        if (over) {
            const s = Object.assign({}, score)
            s[winner || "draw"] += 1
            score = s
        } else {
            turn = turn === "X" ? "O" : "X"
        }
        return true
    }
    // A tap on the board: the person whose turn it is.
    function play(cell) {
        if (computerTurn)
            return false
        return place(cell)
    }
    function computerMove() {
        if (!computerTurn)
            return
        const empty = cells.map((c, i) => c ? -1 : i).filter(i => i >= 0)
        const random = !hard && Math.random() < 0.55
        place(random ? empty[Math.floor(Math.random() * empty.length)] : bestMove(cells, "O"))
    }
    function newRound() {
        starter = starter === "X" ? "O" : "X"
        cells = ["", "", "", "", "", "", "", "", ""]
        winLine = null
        turn = starter
    }
    function reset() {
        score = { X: 0, O: 0, draw: 0 }
        starter = "O"
        newRound()
    }
    onVsComputerChanged: reset()
    onHardChanged: reset()

    Timer {
        interval: game.thinkMs
        running: game.computerTurn
        onTriggered: game.computerMove()
    }

    // ---- Header: mode and score
    RowLayout {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 12

        SegmentedControl {
            options: [qsTr("2 players"), qsTr("vs Ohana")]
            currentIndex: game.vsComputer ? 1 : 0
            onSelected: index => game.vsComputer = index === 1
        }
        SegmentedControl {
            visible: game.vsComputer
            options: [qsTr("Easy"), qsTr("Hard")]
            currentIndex: game.hard ? 1 : 0
            onSelected: index => game.hard = index === 1
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: [{ key: "X", label: game.vsComputer ? qsTr("You") : "X", color: game.xColor },
                    { key: "draw", label: qsTr("Draws"), color: Theme.textMuted },
                    { key: "O", label: game.vsComputer ? qsTr("Ohana") : "O", color: game.oColor }]
            delegate: Rectangle {
                required property var modelData
                implicitWidth: Math.max(88, chip.implicitWidth + 32)
                implicitHeight: 64
                radius: Theme.radiusSm
                color: Theme.surface
                Column {
                    id: chip
                    anchors.centerIn: parent
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.label
                        color: modelData.color
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.DemiBold
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: game.score[modelData.key]
                        color: Theme.text
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.DemiBold
                    }
                }
            }
        }
    }

    Label {
        id: status
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacing
        anchors.horizontalCenter: parent.horizontalCenter
        text: game.winner ? (game.vsComputer ? (game.winner === "X" ? qsTr("You win!") : qsTr("Ohana wins!"))
                                             : qsTr("%1 wins!").arg(game.winner))
            : game.draw ? qsTr("It's a draw")
            : game.computerTurn ? qsTr("Ohana is thinking…")
            : game.vsComputer ? qsTr("Your turn")
            : qsTr("%1's turn").arg(game.turn)
        color: game.winner === "X" ? game.xColor : game.winner === "O" ? game.oColor : Theme.text
        font.pixelSize: Theme.fontLg
        font.weight: Font.DemiBold
    }

    // ---- Board
    Item {
        id: area
        anchors.top: status.bottom
        anchors.topMargin: Theme.spacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: newRoundButton.top
        anchors.bottomMargin: Theme.spacing

        Item {
            id: board
            readonly property real gap: width * 0.03
            readonly property real cell: (width - 2 * gap) / 3
            width: Math.min(area.width, area.height)
            height: width
            anchors.centerIn: parent

            Repeater {
                model: 9
                delegate: Rectangle {
                    id: square
                    required property int index
                    readonly property string mark: game.cells[index]
                    readonly property bool lit: game.winLine !== null && game.winLine.indexOf(index) >= 0
                    x: (index % 3) * (board.cell + board.gap)
                    y: Math.floor(index / 3) * (board.cell + board.gap)
                    width: board.cell
                    height: board.cell
                    radius: Theme.radius
                    color: lit ? (mark === "X" ? Qt.rgba(240 / 255, 127 / 255, 90 / 255, 0.18) : Qt.rgba(79 / 255, 124 / 255, 247 / 255, 0.18))
                               : Theme.surface
                    Behavior on color { ColorAnimation { duration: Theme.smooth } }
                    opacity: game.over && !lit && mark !== "" ? 0.55 : 1
                    Behavior on opacity { NumberAnimation { duration: Theme.smooth } }

                    // X: two rounded bars.
                    Item {
                        anchors.centerIn: parent
                        width: board.cell * 0.56
                        height: width
                        visible: square.mark === "X"
                        scale: visible ? 1 : 0.4
                        Behavior on scale { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutBack } }
                        Repeater {
                            model: [45, -45]
                            delegate: Rectangle {
                                required property real modelData
                                anchors.centerIn: parent
                                width: parent.width * 1.2
                                height: board.cell * 0.12
                                radius: height / 2
                                rotation: modelData
                                color: game.xColor
                            }
                        }
                    }
                    // O: a ring.
                    Rectangle {
                        anchors.centerIn: parent
                        width: board.cell * 0.6
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: board.cell * 0.11
                        border.color: game.oColor
                        visible: square.mark === "O"
                        scale: visible ? 1 : 0.4
                        Behavior on scale { NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutBack } }
                    }

                    TapHandler {
                        onTapped: game.over ? game.newRound() : game.play(square.index)
                    }
                }
            }
        }
    }

    PillButton {
        id: newRoundButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        text: game.over ? qsTr("Play again") : qsTr("Start over")
        fill: game.over ? Theme.accent : Theme.surface
        ink: game.over ? Theme.accentInk : Theme.text
        onClicked: game.newRound()
    }
}
