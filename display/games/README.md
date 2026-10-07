# Games

Open-source code behind the display's Games tab
(`qml/screens/GamesScreen.qml`). Each directory keeps its license next to the
code. Everything runs inside the display app; nothing is downloaded at run
time.

| Game | Directory | Source | License |
|------|-----------|--------|---------|
| Same Game | `samegame/` | Qt demo [`examples/demos/samegame`](https://github.com/qt/qtdoc/tree/6.4/examples/demos/samegame), qtdoc 6.4 branch at `eb33fc97` | BSD-3-Clause |
| Maroon in Trouble | `maroon/` | Qt demo [`examples/demos/maroon`](https://github.com/qt/qtdoc/tree/6.4/examples/demos/maroon), qtdoc 6.4 branch at `eb33fc97` | BSD-3-Clause |
| 2048 | `2048/` | Gabriele Cirulli's [2048](https://github.com/gabrielecirulli/2048) at `478b6ec3` | MIT |
| Traffic Jam | `traffic/` | Michael Fogleman's [rush](https://github.com/fogleman/rush) (Rush Hour) at `3e3b8396` | MIT |

## What we changed

- **Same Game, Maroon in Trouble**: the 6.4 versions, because they load from
  resources with relative imports and run on Qt 6.4 (CI) and 6.8 (the Pi).
  Same Game's Quit button now goes back to the list of games
  (`quitRequested()`) instead of quitting the app. Three fixes come from the
  6.8 versions: Maroon uses QtMultimedia's `SoundEffect` directly (the 6.4
  wrapper, `content/SoundEffect.qml`, looked for the sounds in the wrong
  directory under Qt 6, so they never played), and two signal handlers name
  their `mouse` and `event` parameters. Images and sounds are unchanged.
- **2048**: `game.js` is `tile.js`, `grid.js` and `game_manager.js` joined
  into one file, otherwise unchanged. The board, swipes and storage that
  replace the web page are ours, in `qml/games/Game2048.qml`, with the
  original colors and animations.
- **Traffic Jam**: `rush.js` is the `Piece`, `Move` and `Board` code from
  `web/app.js`, unchanged. The levels in `puzzles.js` are our own, made by
  `make-puzzles.py` (seeded, so it prints the same levels each run) and
  checked against `rush.js` by `tests/tst_games.cpp`. The board is
  `qml/games/TrafficJam.qml`.

Tic-tac-toe (`qml/games/TicTacToe.qml`) is written for this app.

## Saved scores

Same Game, 2048 and Traffic Jam keep high scores, the 2048 game in progress
and Traffic Jam progress in Qt's LocalStorage (SQLite), under
`~/.local/share/homeOS/display/QML/OfflineStorage`. This needs the
`qml6-module-qtquick-localstorage` and `libqt6sql6-sqlite` packages;
Same Game and Maroon also need `qml6-module-qtquick-particles`.
`install-pi.sh` installs all three.

## Adding a game

Add an entry to `catalog` in `GamesScreen.qml`, with a card picture. Our own
QML goes in `qml/games/` and the module's `QML_FILES`; a third-party game kept
as-is goes in a directory here and into the resources glob in
`display/CMakeLists.txt`. Add it to `tests/tst_games.cpp` too. A game is
loaded only while it is open, so it doesn't need to pause or clean up when
it is hidden.
