import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.LocalStorage
import HomeOS
import "../../games/traffic/rush.js" as Rush
import "../../games/traffic/puzzles.js" as Puzzles

// Traffic Jam: slide the cars and trucks until the red car can drive out.
//
// The board is Michael Fogleman's Rush Hour logic, unchanged in rush.js
// (MIT): a drag only lands where Board.moves() allows, the same way his web
// player checks it. The levels in puzzles.js were generated and solved for
// this display by make-puzzles.py, easiest first. The current level and each
// level's fewest moves are remembered (one small write per solve).
Item {
    id: game

    readonly property int levelCount: Puzzles.levels.length
    property int level: 0
    property var board: null
    // Each piece's first square (0-35), refreshed after every move.
    property var positions: []
    property var undoStack: []
    property int moves: 0
    property bool solved: false
    // Fewest moves each solved level took, by level index.
    property var best: ({})
    property int dragIndex: -1
    property bool pickerOpen: false
    readonly property int par: Puzzles.levels[level][1]
    readonly property var bands: [
        { name: qsTr("Beginner"), upTo: 8, color: "#3DB37A", tint: "#293DB37A" },
        { name: qsTr("Intermediate"), upTo: 16, color: "#4F7CF7", tint: "#294F7CF7" },
        { name: qsTr("Advanced"), upTo: 25, color: "#E0912A", tint: "#29F2A93B" },
        { name: qsTr("Expert"), upTo: 1000, color: "#E5484D", tint: "#29E5484D" }
    ]
    readonly property var carColors: ["#5B8DEF", "#F2B84B", "#3DB37A", "#8E7CE6", "#EF8A6F", "#5FB3B3",
                                      "#D77FC1", "#F29F67", "#6BC2E8", "#A3C55A", "#C9A27A", "#7F8FA6"]

    function band(moves) { return bands.find(b => moves <= b.upTo) }
    // Three stars for the fewest possible moves, two for close to it.
    function stars(moves, fewest) { return moves <= fewest ? 3 : moves <= fewest + Math.max(2, Math.ceil(fewest / 2)) ? 2 : 1 }

    function load(index) {
        level = Math.max(0, Math.min(levelCount - 1, index))
        board = new Rush.Board(Puzzles.levels[level][0])
        undoStack = []
        moves = 0
        solved = false
        dragIndex = -1
        refresh()
        remember("level", level)
    }
    function refresh() { positions = board.pieces.map(p => p.position) }

    // Slides piece `index` by `steps` squares (negative: left or up) if the
    // board allows it. Drags end here.
    function slide(index, steps) {
        if (solved || steps === 0)
            return false
        const move = board.moves().find(m => m.piece === index && m.steps === steps)
        if (!move)
            return false
        board.doMove(move)
        undoStack.push(move)
        moves = undoStack.length
        refresh()
        if (board.isSolved()) {
            solved = true
            recordSolve()
        }
        return true
    }
    function undo() {
        if (solved || !undoStack.length)
            return
        board.undoMove(undoStack.pop())
        moves = undoStack.length
        refresh()
    }
    // How far piece `index` can slide right now: [fewest, most] steps.
    function range(index) {
        let lo = 0, hi = 0
        for (const m of board.moves()) {
            if (m.piece === index) {
                lo = Math.min(lo, m.steps)
                hi = Math.max(hi, m.steps)
            }
        }
        return [lo, hi]
    }

    // ---- Progress, in LocalStorage
    function database() {
        try {
            const db = LocalStorage.openDatabaseSync("OhanaTrafficJam", "1.0", "Traffic Jam progress", 10000)
            db.transaction(tx => {
                tx.executeSql("CREATE TABLE IF NOT EXISTS solved(level INTEGER PRIMARY KEY, moves INTEGER)")
                tx.executeSql("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT)")
            })
            return db
        } catch (e) {
            console.warn("Traffic Jam: progress is not saved:", e)
            return null
        }
    }
    function restore() {
        const db = database()
        if (!db)
            return 0
        let start = 0
        try {
            db.readTransaction(tx => {
                const rows = tx.executeSql("SELECT level, moves FROM solved").rows
                const solvedLevels = {}
                for (let i = 0; i < rows.length; ++i)
                    solvedLevels[rows.item(i).level] = rows.item(i).moves
                best = solvedLevels
                const saved = tx.executeSql("SELECT value FROM kv WHERE key = 'level'").rows
                if (saved.length)
                    start = Number(saved.item(0).value) || 0
            })
        } catch (e) {
            console.warn("Traffic Jam: could not read progress:", e)
        }
        return start
    }
    function remember(key, value) {
        const db = database()
        if (!db)
            return
        try {
            db.transaction(tx => tx.executeSql("INSERT OR REPLACE INTO kv VALUES (?, ?)", [key, String(value)]))
        } catch (e) {
            console.warn("Traffic Jam: could not save:", e)
        }
    }
    function recordSolve() {
        if (best[level] !== undefined && best[level] <= moves)
            return
        const updated = Object.assign({}, best)
        updated[level] = moves
        best = updated
        const db = database()
        if (!db)
            return
        try {
            db.transaction(tx => tx.executeSql("INSERT OR REPLACE INTO solved VALUES (?, ?)", [level, moves]))
        } catch (e) {
            console.warn("Traffic Jam: could not save:", e)
        }
    }

    Component.onCompleted: load(restore())

    // ---- Header
    RowLayout {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 12

        Column {
            Layout.fillWidth: true
            Label {
                text: qsTr("Level %1").arg(game.level + 1)
                color: Theme.text
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
            }
            Row {
                spacing: 10
                Tag {
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property var b: game.band(game.par)
                    text: b.name
                    ink: b.color
                    tint: b.tint
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: game.best[game.level] !== undefined
                          ? qsTr("Fewest moves %1 · your best %2").arg(game.par).arg(game.best[game.level])
                          : qsTr("Fewest moves %1").arg(game.par)
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontXs
                }
            }
        }
        Column {
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Moves")
                color: Theme.textMuted
                font.pixelSize: Theme.fontXs
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: game.moves
                color: Theme.text
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
            }
        }
        Item { implicitWidth: 4 }
        IconButton {
            icon: "undo"
            enabled: game.moves > 0 && !game.solved
            onClicked: game.undo()
        }
        IconButton {
            icon: "refresh"
            onClicked: game.load(game.level)
        }
        PillButton {
            text: qsTr("Levels")
            fill: Theme.surface
            ink: Theme.text
            onClicked: game.pickerOpen = true
        }
    }

    // ---- Board
    Item {
        id: area
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        Rectangle {
            id: frame
            readonly property real pad: width * 0.035
            readonly property real cell: (width - 2 * pad) / 6
            readonly property real inset: cell * 0.05
            function at(i) { return pad + i * cell }

            // Leave room on the right for the exit lane.
            width: Math.max(0, Math.min(area.height, area.width / 1.12))
            height: width
            anchors.verticalCenter: parent.verticalCenter
            x: (area.width - width * 1.08) / 2
            radius: Theme.radius
            color: Theme.surface

            Repeater {
                model: 36
                delegate: Rectangle {
                    required property int index
                    x: frame.at(index % 6) + frame.inset
                    y: frame.at(Math.floor(index / 6)) + frame.inset
                    width: frame.cell - 2 * frame.inset
                    height: width
                    radius: frame.cell * 0.14
                    color: Theme.sunken
                }
            }

            // The way out, on the right of the red car's row.
            Rectangle {
                readonly property int row: game.board ? game.board.primaryRow : 2
                x: frame.width - frame.pad - frame.inset
                y: frame.at(row) + frame.inset
                width: frame.pad + frame.cell * 0.55
                height: frame.cell - 2 * frame.inset
                radius: frame.cell * 0.14
                color: Theme.sunken
                Icon {
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    name: "right"
                    size: Math.min(36, frame.cell * 0.4)
                    color: game.solved ? Theme.success : Theme.textMuted
                }
            }

            Repeater {
                model: game.board ? game.board.pieces.length : 0
                delegate: Item {
                    id: car
                    required property int index
                    readonly property var piece: game.board.pieces[index]
                    readonly property int pos: game.positions[index] !== undefined ? game.positions[index] : 0
                    readonly property bool horizontal: piece.stride === 1
                    readonly property bool primary: index === 0
                    readonly property color paint: piece.fixed ? Theme.textMuted
                                                 : primary ? "#E5484D"
                                                 : game.carColors[(index - 1) % game.carColors.length]
                    property real dragOffset: 0     // px along the car's axis while dragging
                    property real exitOffset: 0     // drives the red car out once solved
                    property var limits: [0, 0]

                    x: frame.at(pos % 6) + frame.inset + (horizontal ? dragOffset + exitOffset : 0)
                    y: frame.at(Math.floor(pos / 6)) + frame.inset + (horizontal ? 0 : dragOffset)
                    width: (horizontal ? piece.size : 1) * frame.cell - 2 * frame.inset
                    height: (horizontal ? 1 : piece.size) * frame.cell - 2 * frame.inset
                    z: game.dragIndex === index ? 2 : 1
                    Behavior on x { enabled: game.dragIndex !== car.index; NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: game.dragIndex !== car.index; NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutCubic } }

                    // Seen from above: body, a windscreen at each end, roof between.
                    Rectangle {
                        anchors.fill: parent
                        radius: frame.cell * 0.2
                        color: car.paint
                        scale: drag.active ? 1.03 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.quick } }

                        readonly property real along: car.horizontal ? car.width : car.height
                        readonly property real across: car.horizontal ? car.height : car.width
                        readonly property real glass: frame.cell * 0.13

                        Repeater {
                            model: car.piece.fixed ? 0 : 2
                            delegate: Rectangle {
                                required property int index
                                readonly property real start: index === 0 ? frame.cell * 0.16
                                                                          : parent.along - frame.cell * 0.16 - parent.glass
                                x: car.horizontal ? start : parent.across * 0.17
                                y: car.horizontal ? parent.across * 0.17 : start
                                width: car.horizontal ? parent.glass : parent.across * 0.66
                                height: car.horizontal ? parent.across * 0.66 : parent.glass
                                radius: frame.cell * 0.05
                                color: Qt.darker(car.paint, 1.5)
                            }
                        }
                        Rectangle {
                            visible: !car.piece.fixed
                            anchors.centerIn: parent
                            readonly property real length: parent.along - 2 * (frame.cell * 0.16 + parent.glass + frame.cell * 0.07)
                            width: car.horizontal ? length : parent.across * 0.62
                            height: car.horizontal ? parent.across * 0.62 : length
                            radius: frame.cell * 0.1
                            color: Qt.lighter(car.paint, 1.12)
                        }
                    }

                    DragHandler {
                        id: drag
                        target: null
                        enabled: !car.piece.fixed && !game.solved && (game.dragIndex < 0 || game.dragIndex === car.index)
                        xAxis.enabled: car.horizontal
                        yAxis.enabled: !car.horizontal
                        onActiveChanged: {
                            if (active) {
                                car.limits = game.range(car.index)
                                game.dragIndex = car.index
                            } else {
                                const steps = Math.round(car.dragOffset / frame.cell)
                                game.dragIndex = -1
                                car.dragOffset = 0
                                game.slide(car.index, steps)
                            }
                        }
                        onActiveTranslationChanged: {
                            if (!active)
                                return
                            const along = car.horizontal ? activeTranslation.x : activeTranslation.y
                            car.dragOffset = Math.max(car.limits[0] * frame.cell, Math.min(car.limits[1] * frame.cell, along))
                        }
                    }

                    NumberAnimation on exitOffset {
                        running: car.primary && game.solved
                        to: frame.cell * 2.6
                        duration: 600
                        easing.type: Easing.InCubic
                    }
                    opacity: car.primary && game.solved ? Math.max(0, 1 - exitOffset / (frame.cell * 2.6)) : 1
                    Connections {
                        target: game
                        function onBoardChanged() { car.exitOffset = 0 }
                    }
                }
            }

            // ---- Solved
            Rectangle {
                id: solvedCard
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.86, 520)
                height: solvedColumn.implicitHeight + 64
                radius: Theme.radius
                color: Theme.surface
                border.width: 1
                border.color: Theme.divider
                z: 5
                opacity: game.solved ? 1 : 0
                visible: opacity > 0
                scale: game.solved ? 1 : 0.9
                Behavior on opacity { SequentialAnimation { PauseAnimation { duration: game.solved ? 500 : 0 } NumberAnimation { duration: Theme.smooth } } }
                Behavior on scale { SequentialAnimation { PauseAnimation { duration: game.solved ? 500 : 0 } NumberAnimation { duration: Theme.smooth; easing.type: Easing.OutBack } } }

                ColumnLayout {
                    id: solvedColumn
                    anchors.centerIn: parent
                    width: parent.width - 64
                    spacing: 14
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        readonly property int count: game.stars(game.moves, game.par)
                        text: "★".repeat(count) + "☆".repeat(3 - count)
                        color: Theme.warning
                        font.pixelSize: 44
                    }
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Out in %1 moves!").arg(game.moves)
                        color: Theme.text
                        font.pixelSize: Theme.fontLg
                        font.weight: Font.DemiBold
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: game.moves <= game.par ? qsTr("That's the fewest possible.")
                                                     : qsTr("It can be done in %1.").arg(game.par)
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontSm
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 8
                        spacing: 16
                        PillButton {
                            text: qsTr("Play again")
                            fill: Theme.surfaceAlt
                            ink: Theme.text
                            onClicked: game.load(game.level)
                        }
                        PillButton {
                            text: game.level + 1 < game.levelCount ? qsTr("Next level") : qsTr("All levels")
                            onClicked: game.level + 1 < game.levelCount ? game.load(game.level + 1) : game.pickerOpen = true
                        }
                    }
                }
            }
        }
    }

    // ---- Level picker
    Rectangle {
        anchors.fill: parent
        z: 10
        color: Theme.background
        opacity: game.pickerOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.smooth } }
        // Keep taps from reaching the board underneath.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.spacing

            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Choose a level")
                    color: Theme.text
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.DemiBold
                }
                Label {
                    text: qsTr("%1 of %2 solved").arg(Object.keys(game.best).length).arg(game.levelCount)
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSm
                }
                IconButton { icon: "close"; onClicked: game.pickerOpen = false }
            }

            GridView {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                readonly property int columns: 8
                cellWidth: width / columns
                cellHeight: Math.min(cellWidth, 110)
                model: game.levelCount
                delegate: Item {
                    id: tile
                    required property int index
                    readonly property int par: Puzzles.levels[index][1]
                    readonly property bool done: game.best[index] !== undefined
                    width: grid.cellWidth
                    height: grid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 6
                        radius: Theme.radiusSm
                        color: tile.done ? Theme.accentSoft : Theme.surface
                        border.width: index === game.level ? 3 : 0
                        border.color: Theme.accent
                        scale: levelTap.pressed ? 0.95 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.quick } }

                        Label {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -6
                            text: tile.index + 1
                            color: Theme.text
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 8
                            text: tile.done ? "★".repeat(game.stars(game.best[tile.index], tile.par)) : ""
                            color: Theme.warning
                            font.pixelSize: 13
                        }
                        // Difficulty, as a dot in the corner.
                        Rectangle {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 8
                            width: 10
                            height: 10
                            radius: 5
                            color: game.band(tile.par).color
                        }
                        TapHandler {
                            id: levelTap
                            onTapped: {
                                game.load(tile.index)
                                game.pickerOpen = false
                            }
                        }
                    }
                }
            }
        }
    }
}
