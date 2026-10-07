#!/usr/bin/env python3
"""Generates the Traffic Jam levels (puzzles.js) for the display's Games tab.

Each level is the hardest position of a random board's cluster, the way
Michael Fogleman's rush project finds puzzles: collect every position the
board can reach, measure each one's distance to a solved position with a
breadth-first search, and keep the farthest. A move slides one car or truck
any distance, so a level's par is the fewest moves that solve it.

Random boards rarely make hard puzzles, so the best ones are then improved by
hill climbing (add, remove or shift one vehicle; keep the change when the
puzzle gets harder). The run is seeded, so it prints the same levels every
time:

    python3 make-puzzles.py > puzzles.js     # about ten minutes on four cores
"""

import multiprocessing as mp
import random
import sys
from collections import deque

N = 6                 # 6x6 board
ROW = 2               # the red car's row; the exit is on its right
EXIT = ROW * N + N - 2
MAX_CLUSTER = 150_000  # skip boards whose clusters take too long to search
LEVELS = 40
SEED = 2026


def cells(pos, length, stride):
    return [pos + k * stride for k in range(length)]


def fits(pos, length, stride):
    x, y = pos % N, pos // N
    return (x + length <= N) if stride == 1 else (y + length <= N)


class Shape:
    """Vehicles' lengths and directions; a position is a tuple of their first cells."""

    def __init__(self, vehicles):
        self.vehicles = vehicles  # [(length, stride)], the red car first
        self.masks = [{} for _ in vehicles]
        for i, (length, stride) in enumerate(vehicles):
            for pos in range(N * N):
                if fits(pos, length, stride):
                    m = 0
                    for c in cells(pos, length, stride):
                        m |= 1 << c
                    self.masks[i][pos] = m

    def neighbors(self, state):
        occ = 0
        for i, p in enumerate(state):
            occ |= self.masks[i][p]
        for i, p in enumerate(state):
            length, stride = self.vehicles[i]
            line = p % N if stride == 1 else p // N
            # Backward, one square at a time until something is in the way.
            step = 1
            while line - step >= 0 and not occ >> (p - step * stride) & 1:
                yield state[:i] + (p - step * stride,) + state[i + 1:]
                step += 1
            step = 1
            while line + length - 1 + step < N and not occ >> (p + (length - 1 + step) * stride) & 1:
                yield state[:i] + (p + step * stride,) + state[i + 1:]
                step += 1


def hardest(shape, start):
    """(moves, cluster size, position) for start's cluster, or None."""
    seen = {start}
    queue = deque([start])
    while queue:
        for n in shape.neighbors(queue.popleft()):
            if n not in seen:
                if len(seen) >= MAX_CLUSTER:
                    return None
                seen.add(n)
                queue.append(n)
    solved = [s for s in seen if s[0] == EXIT]
    if not solved:
        return None
    dist = dict.fromkeys(solved, 0)
    queue = deque(solved)
    while queue:
        s = queue.popleft()
        for n in shape.neighbors(s):
            if n not in dist:
                dist[n] = dist[s] + 1
                queue.append(n)
    far = max(dist.values())
    return far, len(seen), min(s for s, d in dist.items() if d == far)


def describe(shape, state):
    """The board as a 36-letter string, cars lettered in reading order, red car A."""
    board = ["o"] * (N * N)
    order = sorted(range(1, len(state)), key=lambda i: state[i])
    for label, i in zip("A" + "BCDEFGHIJKLMNOPQRSTUVWXYZ", [0] + order):
        length, stride = shape.vehicles[i]
        for c in cells(state[i], length, stride):
            board[c] = label
    return "".join(board)


def place(rng, vehicles, positions, occ):
    """Adds one random vehicle that doesn't overlap or sit across the exit row."""
    for _ in range(50):
        length = 3 if rng.random() < 0.25 else 2
        stride = rng.choice([1, N])
        pos = rng.randrange(N * N)
        if not fits(pos, length, stride):
            continue
        if stride == 1 and pos // N == ROW:
            continue  # it could never get out of the red car's way
        m = 0
        for c in cells(pos, length, stride):
            m |= 1 << c
        if occ & m:
            continue
        return vehicles + [(length, stride)], positions + [pos], occ | m
    return None


def random_board(rng):
    vehicles, positions = [(2, 1)], [ROW * N + rng.randrange(N - 2)]
    occ = (1 << positions[0]) | (1 << positions[0] + 1)
    for _ in range(rng.randint(10, 14)):
        added = place(rng, vehicles, positions, occ)
        if added:
            vehicles, positions, occ = added
    return vehicles, positions


def occupancy(vehicles, positions):
    occ = 0
    for (length, stride), pos in zip(vehicles, positions):
        for c in cells(pos, length, stride):
            occ |= 1 << c
    return occ


def mutate(rng, vehicles, positions):
    vehicles, positions = list(vehicles), list(positions)
    kind = rng.random()
    if kind < 0.35 and len(vehicles) > 2:
        i = rng.randrange(1, len(vehicles))
        del vehicles[i], positions[i]
    elif kind < 0.7:
        added = place(rng, vehicles, positions, occupancy(vehicles, positions))
        if not added:
            return None
        vehicles, positions, _ = added
    else:
        i = rng.randrange(1, len(vehicles))
        rest_v = vehicles[:i] + vehicles[i + 1:]
        rest_p = positions[:i] + positions[i + 1:]
        added = place(rng, rest_v, rest_p, occupancy(rest_v, rest_p))
        if not added:
            return None
        vehicles, positions, _ = added
    return vehicles, positions


def evaluate(vehicles, positions):
    shape = Shape(vehicles)
    found = hardest(shape, tuple(positions))
    if not found:
        return None
    moves, size, state = found
    return moves, size, describe(shape, state), vehicles, list(state)


def sample(seed):
    rng = random.Random(seed)
    out = []
    for _ in range(100):
        found = evaluate(*random_board(rng))
        if found and found[0] >= 3:
            out.append(found)
    return out


def climb(args):
    seed, start = args
    rng = random.Random(seed)
    best = start
    for _ in range(120):
        changed = mutate(rng, best[3], best[4])
        if not changed:
            continue
        found = evaluate(*changed)
        if found and found[0] >= best[0]:
            best = found
    return best


def main():
    with mp.Pool() as pool:
        found = [p for batch in pool.map(sample, range(SEED, SEED + 40)) for p in batch]
        print(f"sampled {len(found)} puzzles, hardest {max(f[0] for f in found)} moves",
              file=sys.stderr)
        starts = sorted(found, key=lambda f: -f[0])[:24]
        climbed = pool.map(climb, [(SEED * 7 + i, s) for i, s in enumerate(starts)])
        print(f"climbed to {max(f[0] for f in climbed)} moves", file=sys.stderr)

    by_board = {}
    for moves, size, board, _, _ in found + climbed:
        by_board.setdefault(board, (moves, size))
    pool_ = sorted(((m, -s, b) for b, (m, s) in by_board.items()), key=lambda t: (t[0], t[1]))

    # A steady climb from four moves to the hardest puzzle found. Each pick
    # leaves enough harder puzzles for the levels still to come.
    hardest_moves = pool_[-1][0]
    levels, used = [], set()
    for i in range(LEVELS):
        target = round(4 + (hardest_moves - 4) * (i / (LEVELS - 1)) ** 1.3)
        floor = levels[-1][1] if levels else 0
        left = LEVELS - i - 1
        options = [t for k, t in enumerate(pool_)
                   if t[2] not in used and t[0] >= floor
                   and sum(1 for u in pool_[k + 1:] if u[2] not in used) >= left]
        pick = min(options, key=lambda t: (abs(t[0] - target), t[1]))
        used.add(pick[2])
        levels.append((pick[2], pick[0]))

    print("// Traffic Jam levels, easiest first: [board, fewest moves to solve].")
    print("// Generated by make-puzzles.py; do not edit by hand.")
    print(".pragma library")
    print()
    print("var levels = [")
    print(",\n".join(f'    ["{b}", {m}]' for b, m in levels))
    print("]")


if __name__ == "__main__":
    main()
