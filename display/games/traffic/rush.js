// Rush Hour board logic by Michael Fogleman, https://github.com/fogleman/rush
// MIT License: see LICENSE in this directory.
//
// The Piece, Move and Board types from web/app.js at commit 3e3b8396,
// unchanged. A board is a 36-letter string read row by row: "o" is an empty
// square, "x" a wall, and each other letter one car or truck, with "A" the
// red car that has to leave through the exit on the right of its row.
// TrafficJam.qml draws the board and turns drags into Board moves.
.pragma library

// Piece

function Piece(position, size, stride) {
    this.position = position;
    this.size = size;
    this.stride = stride;
    this.fixed = size === 1;
}

Piece.prototype.move = function(steps) {
    this.position += this.stride * steps;
}

Piece.prototype.draw = function(p5, boardSize, offset) {
    offset = offset || 0;
    var i0 = this.position;
    var i1 = i0 + this.stride * (this.size - 1);
    var x0 = Math.floor(i0 % boardSize);
    var y0 = Math.floor(i0 / boardSize);
    var x1 = Math.floor(i1 % boardSize);
    var y1 = Math.floor(i1 / boardSize);
    var p = 0.1;
    var x = x0 + p;
    var y = y0 + p;
    var w = x1 - x0 + 1 - p * 2;
    var h = y1 - y0 + 1 - p * 2;
    if (this.stride === 1) {
        x += offset;
    } else {
        y += offset;
    }
    p5.rect(x, y, w, h, 0.1);
}

Piece.prototype.pickAxis = function(point) {
    if (this.stride === 1) {
        return point.x;
    } else {
        return point.y;
    }
}

// Move

function Move(piece, steps) {
    this.piece = piece;
    this.steps = steps;
}

// Board

function Board(desc) {
    this.pieces = [];

    // determine board size
    this.size = Math.floor(Math.sqrt(desc.length));
    if (this.size === 0) {
        throw "board cannot be empty";
    }

    this.size2 = this.size * this.size;
    if (this.size2 !== desc.length) {
        throw "boards must be square";
    }

    // parse string
    var positions = new Map();
    for (var i = 0; i < desc.length; i++) {
        var label = desc.charAt(i);
        if (!positions.has(label)) {
            positions.set(label, []);
        }
        positions.get(label).push(i);
    }

    // sort piece labels
    var labels = Array.from(positions.keys());
    labels.sort();

    // add pieces
    for (var label of labels) {
        if (label === '.' || label === 'o') {
            continue;
        }
        if (label === 'x') {
            continue;
        }
        var ps = positions.get(label);
        if (ps.length < 2) {
            throw "piece size must be >= 2";
        }
        var stride = ps[1] - ps[0];
        if (stride !== 1 && stride !== this.size) {
            throw "invalid piece shape";
        }
        for (var i = 2; i < ps.length; i++) {
            if (ps[i] - ps[i-1] !== stride) {
                throw "invalid piece shape";
            }
        }
        var piece = new Piece(ps[0], ps.length, stride);
        this.addPiece(piece);
    }

    // add walls
    if (positions.has('x')) {
        var ps = positions.get('x');
        for (var p of ps) {
            var piece = new Piece(p, 1, 1);
            this.addPiece(piece);
        }
    }

    // compute some stuff
    this.primaryRow = 0;
    if (this.pieces.length !== 0) {
        this.primaryRow = Math.floor(this.pieces[0].position / this.size);
    }
}

Board.prototype.addPiece = function(piece) {
    this.pieces.push(piece);
}

Board.prototype.doMove = function(move) {
    this.pieces[move.piece].move(move.steps);
}

Board.prototype.undoMove = function(move) {
    this.pieces[move.piece].move(-move.steps);
}

Board.prototype.isSolved = function() {
    if (this.pieces.length === 0) {
        return false;
    }
    var piece = this.pieces[0];
    var x = Math.floor(piece.position % this.size);
    return x + piece.size === this.size;
}

Board.prototype.pieceAt = function(index) {
    for (var i = 0; i < this.pieces.length; i++) {
        var piece = this.pieces[i];
        var p = piece.position;
        for (var j = 0; j < piece.size; j++) {
            if (p === index) {
                return i;
            }
            p += piece.stride;
        }
    }
    return -1;
}

Board.prototype.isOccupied = function(index) {
    return this.pieceAt(index) >= 0;
}

Board.prototype.moves = function() {
    var moves = [];
    var size = this.size;
    for (var i = 0; i < this.pieces.length; i++) {
        var piece = this.pieces[i];
        if (piece.fixed) {
            continue;
        }
        var reverseSteps;
        var forwardSteps;
        if (piece.stride == 1) {
            var x = Math.floor(piece.position % size);
            reverseSteps = -x;
            forwardSteps = size - piece.size - x;
        } else {
            var y = Math.floor(piece.position / size);
            reverseSteps = -y;
            forwardSteps = size - piece.size - y;
        }
        var idx = piece.position - piece.stride;
        for (var steps = -1; steps >= reverseSteps; steps--) {
            if (this.isOccupied(idx)) {
                break;
            }
            moves.push(new Move(i, steps));
            idx -= piece.stride;
        }
        idx = piece.position + piece.size * piece.stride;
        for (var steps = 1; steps <= forwardSteps; steps++) {
            if (this.isOccupied(idx)) {
                break;
            }
            moves.push(new Move(i, steps));
            idx += piece.stride;
        }
    }
    return moves;
}
