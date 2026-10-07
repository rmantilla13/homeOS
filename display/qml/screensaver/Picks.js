// Which photos the screen savers show, and where. Plain functions over the
// rows in Store.photos, so tests can call them without a screen.
.pragma library

// Rows from the cloud have an id; demo rows only a url.
function keyOf(photo) {
    return photo ? (photo.id || photo.storage_path || photo.url || "") : ""
}

// -1 portrait, 1 landscape, 0 square or unknown (rows without a size).
function shapeOf(aspect) {
    return !(aspect > 0) ? 0 : aspect < 0.9 ? -1 : aspect > 1.1 ? 1 : 0
}

function photoShape(photo) {
    return shapeOf(photo ? photo.aspect : 0)
}

// ── Collage ──────────────────────────────────────────────────────────────

// The layouts the collage takes turns with, one per start.
var TURNS = ["classic", "grid", "mosaic", "trio", "columns"]

// Tiles on a grid of cols x rows cells: column, row, and a span of w x h
// cells. The first tile is the biggest; it sets the backdrop's color.
var LAYOUTS = {
    single:   { cols: 1, rows: 1, tiles: [[0, 0, 1, 1]] },
    duo:      { cols: 2, rows: 1, tiles: [[0, 0, 1, 1], [1, 0, 1, 1]] },
    trio:     { cols: 3, rows: 2, tiles: [[0, 0, 2, 2], [2, 0, 1, 1], [2, 1, 1, 1]] },
    grid4:    { cols: 2, rows: 2, tiles: [[0, 0, 1, 1], [1, 0, 1, 1], [0, 1, 1, 1], [1, 1, 1, 1]] },
    classic:  { cols: 4, rows: 2, tiles: [[0, 0, 2, 2], [2, 0, 1, 1], [3, 0, 1, 1], [2, 1, 1, 1], [3, 1, 1, 1]] },
    grid6:    { cols: 3, rows: 2, tiles: [[0, 0, 1, 1], [1, 0, 1, 1], [2, 0, 1, 1],
                                          [0, 1, 1, 1], [1, 1, 1, 1], [2, 1, 1, 1]] },
    // A big one, two stacked, a tall one; a wide one between two small below.
    mosaic:   { cols: 4, rows: 3, tiles: [[0, 0, 2, 2], [3, 0, 1, 2], [2, 0, 1, 1], [2, 1, 1, 1],
                                          [1, 2, 2, 1], [0, 2, 1, 1], [3, 2, 1, 1]] },
    columns3: { cols: 3, rows: 1, tiles: [[0, 0, 1, 1], [1, 0, 1, 1], [2, 0, 1, 1]] },
    columns4: { cols: 4, rows: 1, tiles: [[0, 0, 1, 1], [1, 0, 1, 1], [2, 0, 1, 1], [3, 0, 1, 1]] }
}

// The layout a turn uses with `count` photos: its own when there is a photo
// for every tile, else a smaller one, so no tile is empty or repeats a
// photo. null with no photos. Tiles come back as {c, r, w, h}.
function layout(turn, count) {
    if (!(count > 0))
        return null
    let name = ""
    if (turn === "grid")
        name = count >= 6 ? "grid6" : count >= 4 ? "grid4" : ""
    else if (turn === "columns")
        name = count >= 4 ? "columns4" : count >= 3 ? "columns3" : ""
    else if (turn === "mosaic")
        name = count >= 7 ? "mosaic" : ""
    else if (turn === "trio")
        name = count >= 3 ? "trio" : ""
    if (!name)
        name = count >= 5 ? "classic" : count === 4 ? "grid4" : count === 3 ? "trio" : count === 2 ? "duo" : "single"
    const spec = LAYOUTS[name]
    return {
        name: name,
        cols: spec.cols,
        rows: spec.rows,
        tiles: spec.tiles.map(t => ({ c: t[0], r: t[1], w: t[2], h: t[3] }))
    }
}

// width / height of a tile on a screen of `width` x `height` with `gap`
// between and around the tiles.
function tileAspect(lay, tile, width, height, gap) {
    const cellW = (width - gap * (lay.cols + 1)) / lay.cols
    const cellH = (height - gap * (lay.rows + 1)) / lay.rows
    const w = tile.w * cellW + (tile.w - 1) * gap
    const h = tile.h * cellH + (tile.h - 1) * gap
    return h > 0 && w > 0 ? w / h : 0
}

// The photo for a tile, or null when none may go there now. Never one that
// is on screen (`showing`, keys) or left it less than `restMs` ago (`seen`:
// key -> when it was last on screen), so photos don't hop from tile to
// tile. Then one of the tile's shape if there is one (portraits in tall
// tiles), and of those the one off screen longest, new photos first in
// list order (newest first).
function pick(photos, aspect, showing, seen, now, restMs) {
    const want = shapeOf(aspect)
    let best = null, bestFit = 0, bestLast = 0
    for (let i = 0; i < photos.length; ++i) {
        const photo = photos[i]
        const key = keyOf(photo)
        if (!key || showing.indexOf(key) >= 0)
            continue
        const last = seen[key]
        if (last !== undefined && now - last < restMs)
            continue
        const shape = photoShape(photo)
        const fit = want === 0 || shape === 0 || shape === want ? 0 : 1
        const lastShown = last === undefined ? -Infinity : last
        if (best === null || fit < bestFit || (fit === bestFit && lastShown < bestLast)) {
            best = photo
            bestFit = fit
            bestLast = lastShown
        }
    }
    return best
}

// The tile to change next, given `random` in [0, 1): big tiles less often
// (by the square root of their area), and not the one changed last time.
function chooseTile(tiles, lastTile, random) {
    const weights = tiles.map((t, i) => (i === lastTile && tiles.length > 1) ? 0 : 1 / Math.sqrt(t.w * t.h))
    let left = random * weights.reduce((a, b) => a + b, 0)
    for (let i = 0; i < weights.length; ++i) {
        left -= weights[i]
        if (left < 0 && weights[i] > 0)
            return i
    }
    for (let i = weights.length - 1; i >= 0; --i) {
        if (weights[i] > 0)
            return i
    }
    return 0
}

// ── Smart frame ──────────────────────────────────────────────────────────

// What the smart frame shows, screen by screen: a landscape (or unknown)
// photo on its own, or two portrait photos side by side. A portrait photo
// waits for the next one; one left over is shown on its own.
function frames(photos) {
    const used = {}
    const out = []
    for (let i = 0; i < photos.length; ++i) {
        const photo = photos[i]
        const key = keyOf(photo)
        if (used[key])
            continue
        used[key] = true
        if (photoShape(photo) !== -1) {
            out.push([photo])
            continue
        }
        let partner = null
        for (let j = i + 1; j < photos.length && !partner; ++j) {
            const other = photos[j]
            if (!used[keyOf(other)] && photoShape(other) === -1)
                partner = other
        }
        if (partner) {
            used[keyOf(partner)] = true
            out.push([photo, partner])
        } else {
            out.push([photo])
        }
    }
    return out
}

// ── On this day ──────────────────────────────────────────────────────────

function dayNumber(date) {
    return Math.round(new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime() / 86400000)
}

// Photos taken on this date in earlier years, then within three days of it,
// as {photo, years, sameDay}. Today's first, then the nearest days, then the
// oldest years. [] when there are none.
function memories(photos, now) {
    const today = dayNumber(now)
    const out = []
    for (let i = 0; i < photos.length; ++i) {
        const photo = photos[i]
        if (!(photo.takenMs > 0))
            continue
        const taken = new Date(photo.takenMs)
        // The anniversary nearest today: last year's, this year's or next
        // year's, so the days around New Year count too.
        for (let shift = -1; shift <= 1; ++shift) {
            const year = now.getFullYear() + shift
            if (year <= taken.getFullYear())
                continue
            const anniversary = new Date(year, taken.getMonth(), taken.getDate())
            const days = dayNumber(anniversary) - today
            if (Math.abs(days) <= 3) {
                out.push({ photo: photo, years: year - taken.getFullYear(), sameDay: days === 0, distance: Math.abs(days) })
                break
            }
        }
    }
    out.sort((a, b) => a.distance - b.distance || b.years - a.years)
    return out
}

// ── Today and Clock ──────────────────────────────────────────────────────

function isoDay(date) {
    const m = date.getMonth() + 1, d = date.getDate()
    return date.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d
}

// Today's events, all-day ones first, then by start.
function todaysEvents(events, now) {
    const day = isoDay(now)
    return events.filter(e => e.day === day)
                 .sort((a, b) => (b.all_day ? 1 : 0) - (a.all_day ? 1 : 0) || a.startMs - b.startMs)
}

// The next `count` timed events that haven't started.
function upcoming(events, now, count) {
    const t = now.getTime()
    return events.filter(e => !e.all_day && e.startMs > t)
                 .sort((a, b) => a.startMs - b.startMs)
                 .slice(0, count)
}
