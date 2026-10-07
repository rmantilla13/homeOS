#include <QtTest>

#include <QQmlComponent>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>

// Stands in for DisplayController: the theme reads the mood and dark mode.
class FakeDevice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mood READ mood CONSTANT)
    Q_PROPERTY(bool darkMode READ darkMode CONSTANT)
public:
    QString mood() const { return QStringLiteral("day"); }
    bool darkMode() const { return false; }
};

// The Games tab: GamesScreen.qml and every game, loaded from a copy laid out
// like the app's resources (qrc:/HomeOS/...), so the relative paths between
// them are the ones the app uses. Fails on any QML error or warning.
class TestGames : public QObject
{
    Q_OBJECT

    FakeDevice m_device;
    QTemporaryDir m_storage;
    QQmlEngine *m_engine = nullptr;
    QQuickWindow *m_window = nullptr;
    QList<QQmlError> m_warnings;

    static QUrl url(const QString &path)
    {
        return QUrl::fromLocalFile(QStringLiteral(HOMEOS_GAMES_QML_DIR "/HomeOS/") + path);
    }

    QQuickItem *create(const QString &path, QSize size = {})
    {
        QQmlComponent component(m_engine, url(path));
        QObject *object = component.create();
        if (!object) {
            qWarning().noquote() << component.errorString();
            return nullptr;
        }
        auto *item = qobject_cast<QQuickItem *>(object);
        item->setParentItem(m_window->contentItem());
        if (size.isValid())
            item->setSize(size);
        return item;
    }

    QVariant eval(QObject *scope, const QString &js)
    {
        QQmlExpression expression(qmlContext(scope), scope, js);
        const QVariant result = expression.evaluate();
        if (expression.hasError())
            qWarning().noquote() << expression.error().toString();
        return result;
    }

    static QString winner(const QStringList &b)
    {
        static const int lines[8][3] = {{0, 1, 2}, {3, 4, 5}, {6, 7, 8}, {0, 3, 6},
                                        {1, 4, 7}, {2, 5, 8}, {0, 4, 8}, {2, 4, 6}};
        for (const auto &l : lines) {
            if (!b[l[0]].isEmpty() && b[l[0]] == b[l[1]] && b[l[0]] == b[l[2]])
                return b[l[0]];
        }
        return {};
    }

    // Every game X can play against Hard Ohana: X never gets three in a row.
    void explore(QObject *game, QStringList board, bool xToMove, int &games)
    {
        const QString won = winner(board);
        QVERIFY2(won != QLatin1String("X"), qPrintable(board.join(QLatin1Char(','))));
        if (!won.isEmpty() || !board.contains(QString())) {
            ++games;
            return;
        }
        if (xToMove) {
            for (int i = 0; i < 9; ++i) {
                if (!board[i].isEmpty())
                    continue;
                QStringList next = board;
                next[i] = QStringLiteral("X");
                explore(game, next, false, games);
                if (QTest::currentTestFailed())
                    return;
            }
            return;
        }
        QVariant move;
        QVERIFY(QMetaObject::invokeMethod(game, "bestMove", Q_RETURN_ARG(QVariant, move),
                                          Q_ARG(QVariant, QVariant(board)),
                                          Q_ARG(QVariant, QStringLiteral("O"))));
        const int i = move.toInt();
        QVERIFY(i >= 0 && i < 9 && board[i].isEmpty());
        board[i] = QStringLiteral("O");
        explore(game, board, true, games);
    }

    // Seeds 2048 with one row of tiles (left to right) and the given score.
    void seed2048(QObject *game, const QList<int> &row)
    {
        QStringList columns;
        for (int x = 0; x < 4; ++x) {
            const QString tile = x < row.size() && row[x]
                ? QStringLiteral("{position:{x:%1,y:0},value:%2}").arg(x).arg(row[x])
                : QStringLiteral("null");
            columns << QStringLiteral("[%1,null,null,null]").arg(tile);
        }
        eval(game, QStringLiteral("saved.gameState = JSON.stringify({grid:{size:4,cells:[%1]},"
                                  "score:0,over:false,won:false,keepPlaying:false}); manager.setup()")
                       .arg(columns.join(QLatin1Char(','))));
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_storage.isValid());
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_GAMES_QML_DIR));
        m_engine->setOfflineStoragePath(m_storage.path());
        connect(m_engine, &QQmlEngine::warnings, this,
                [this](const QList<QQmlError> &warnings) { m_warnings << warnings; });
        m_window = new QQuickWindow;
        m_window->resize(1280, 800);
        m_window->show();
        QVERIFY(QTest::qWaitForWindowExposed(m_window));
    }

    void cleanupTestCase() { delete m_window; }

    void init() { m_warnings.clear(); }

    void cleanup()
    {
        for (const QQmlError &warning : std::as_const(m_warnings))
            qWarning().noquote() << warning.toString();
        QVERIFY2(m_warnings.isEmpty(), "QML warnings");
    }

    void screenOpensEveryGame()
    {
        QScopedPointer<QQuickItem> screen(create(QStringLiteral("qml/screens/GamesScreen.qml"), {1180, 800}));
        QVERIFY(screen);
        const int count = eval(screen.get(), QStringLiteral("catalog.length")).toInt();
        QCOMPARE(count, 5);
        for (int i = 0; i < count; ++i) {
            QVERIFY(QMetaObject::invokeMethod(screen.get(), "open", Q_ARG(QVariant, i)));
            QTRY_VERIFY2(eval(screen.get(), QStringLiteral("game !== null")).toBool(),
                         qPrintable(eval(screen.get(), QStringLiteral("openGame.title")).toString()));
            QTest::qWait(200);
            QVERIFY(QMetaObject::invokeMethod(screen.get(), "close"));
            QTRY_VERIFY(eval(screen.get(), QStringLiteral("game === null")).toBool());
        }
        // Leaving the tab closes the game.
        QVERIFY(QMetaObject::invokeMethod(screen.get(), "open", Q_ARG(QVariant, 0)));
        QTRY_VERIFY(eval(screen.get(), QStringLiteral("game !== null")).toBool());
        screen->setProperty("shown", false);
        QTRY_VERIFY(eval(screen.get(), QStringLiteral("game === null")).toBool());
    }

    void game2048MergesScoresAndRemembers()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("qml/games/Game2048.qml"), {800, 760}));
        QVERIFY(game);
        QCOMPARE(eval(game.get(), QStringLiteral("tiles.length")).toInt(), 2); // a new game
        seed2048(game.get(), {2, 2, 4, 4});
        QVERIFY(QMetaObject::invokeMethod(game.get(), "move", Q_ARG(QVariant, 3))); // left
        QCOMPARE(game->property("score").toInt(), 12);
        QCOMPARE(game->property("best").toInt(), 12);
        QCOMPARE(eval(game.get(), QStringLiteral("manager.grid.cells[0][0].value")).toInt(), 4);
        QCOMPARE(eval(game.get(), QStringLiteral("manager.grid.cells[1][0].value")).toInt(), 8);
        QCOMPARE(eval(game.get(), QStringLiteral("manager.grid.availableCells().length")).toInt(), 13);

        // Closing saves the game; opening it again carries on.
        game.reset();
        game.reset(create(QStringLiteral("qml/games/Game2048.qml"), {800, 760}));
        QVERIFY(game);
        QCOMPARE(game->property("score").toInt(), 12);
        QCOMPARE(game->property("best").toInt(), 12);
        QCOMPARE(eval(game.get(), QStringLiteral("manager.grid.cells[1][0].value")).toInt(), 8);

        QVERIFY(QMetaObject::invokeMethod(game.get(), "restart"));
        QCOMPARE(game->property("score").toInt(), 0);
        QCOMPARE(game->property("best").toInt(), 12);
    }

    void game2048WinThenKeepGoing()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("qml/games/Game2048.qml"), {800, 760}));
        QVERIFY(game);
        seed2048(game.get(), {1024, 1024});
        QVERIFY(QMetaObject::invokeMethod(game.get(), "move", Q_ARG(QVariant, 3)));
        QVERIFY(game->property("won").toBool());
        QVERIFY(game->property("terminated").toBool());
        QVERIFY(QMetaObject::invokeMethod(game.get(), "keepPlaying"));
        QVERIFY(!game->property("terminated").toBool());
        QVERIFY(QMetaObject::invokeMethod(game.get(), "restart"));
    }

    void ticTacToeTwoPlayers()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("qml/games/TicTacToe.qml"), {900, 760}));
        QVERIFY(game);
        auto play = [&](int cell) {
            QVariant ok;
            QMetaObject::invokeMethod(game.get(), "play", Q_RETURN_ARG(QVariant, ok), Q_ARG(QVariant, cell));
            return ok.toBool();
        };
        // X: 0 1 2 across the top; O: 3 4.
        for (int cell : {0, 3, 1, 4, 2})
            QVERIFY(play(cell));
        QCOMPARE(game->property("winner").toString(), QStringLiteral("X"));
        QCOMPARE(eval(game.get(), QStringLiteral("winLine.join(',')")).toString(), QStringLiteral("0,1,2"));
        QCOMPARE(eval(game.get(), QStringLiteral("score.X")).toInt(), 1);
        QVERIFY(!play(5)); // the round is over

        // O starts the next round. A full board with no line is a draw.
        QVERIFY(QMetaObject::invokeMethod(game.get(), "newRound"));
        QCOMPARE(game->property("turn").toString(), QStringLiteral("O"));
        for (int cell : {1, 0, 4, 2, 5, 3, 6, 7, 8})
            QVERIFY(play(cell));
        QVERIFY(game->property("draw").toBool());
        QCOMPARE(eval(game.get(), QStringLiteral("score.draw")).toInt(), 1);
    }

    void ticTacToeHardNeverLoses()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("qml/games/TicTacToe.qml"), {900, 760}));
        QVERIFY(game);
        int games = 0;
        explore(game.get(), QStringList(9, QString()), true, games);   // X first
        explore(game.get(), QStringList(9, QString()), false, games);  // Ohana first
        QVERIFY(games > 100);

        // Easy Ohana answers a move.
        game->setProperty("vsComputer", true);
        game->setProperty("thinkMs", 10);
        QVERIFY(QMetaObject::invokeMethod(game.get(), "play", Q_ARG(QVariant, 4)));
        QTRY_COMPARE(game->property("turn").toString(), QStringLiteral("X"));
        QCOMPARE(eval(game.get(), QStringLiteral("cells.filter(c => c === 'O').length")).toInt(), 1);
    }

    void trafficJamLevelsAreRightAndSolvable()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("qml/games/TrafficJam.qml"), {900, 760}));
        QVERIFY(game);
        const int count = game->property("levelCount").toInt();
        QVERIFY(count >= 30);

        // A breadth-first search with the upstream Board's moves() finds the
        // fewest moves: it has to match each level's par. Returns the moves.
        const QString solve = QStringLiteral(R"(
            (function () {
                const pieces = board.pieces
                const start = pieces.map(p => p.position)
                const solved = s => s[0] % board.size + pieces[0].size === board.size
                const parent = new Map([[start.join(","), null]])
                let frontier = [start], found = null
                while (frontier.length && !found) {
                    const next = []
                    for (const state of frontier) {
                        state.forEach((p, i) => pieces[i].position = p)
                        for (const m of board.moves()) {
                            const s = state.slice()
                            s[m.piece] += m.steps * pieces[m.piece].stride
                            const k = s.join(",")
                            if (parent.has(k))
                                continue
                            parent.set(k, [state.join(","), m.piece, m.steps])
                            next.push(s)
                            if (solved(s)) {
                                found = k
                                break
                            }
                        }
                        if (found)
                            break
                    }
                    frontier = next
                }
                start.forEach((p, i) => pieces[i].position = p)
                const path = []
                for (let k = found; k && parent.get(k); k = parent.get(k)[0])
                    path.unshift([parent.get(k)[1], parent.get(k)[2]])
                return path
            })())");

        int previous = 0;
        for (int i = 0; i < count; ++i) {
            QVERIFY(QMetaObject::invokeMethod(game.get(), "load", Q_ARG(QVariant, i)));
            const int par = game->property("par").toInt();
            QVERIFY2(par >= previous, "levels get harder");
            previous = par;
            QVERIFY(!eval(game.get(), QStringLiteral("board.isSolved()")).toBool());
            QCOMPARE(eval(game.get(), QStringLiteral("board.primaryRow")).toInt(), 2);
            if (par <= 8) { // the rest take long here; make-puzzles.py solved them
                const QVariantList path = eval(game.get(), solve).toList();
                QCOMPARE(path.size(), par);
            }
        }

        // Solve level 1 by sliding the cars, then reopen: progress is kept.
        QVERIFY(QMetaObject::invokeMethod(game.get(), "load", Q_ARG(QVariant, 0)));
        const QVariantList path = eval(game.get(), solve).toList();
        QVERIFY(!path.isEmpty());
        QVariant ok;
        QVERIFY(QMetaObject::invokeMethod(game.get(), "slide", Q_RETURN_ARG(QVariant, ok),
                                          Q_ARG(QVariant, 0), Q_ARG(QVariant, -99)));
        QVERIFY(!ok.toBool()); // not a legal move
        for (const QVariant &step : path) {
            const QVariantList move = step.toList();
            QVERIFY(QMetaObject::invokeMethod(game.get(), "slide", Q_RETURN_ARG(QVariant, ok),
                                              Q_ARG(QVariant, move[0]), Q_ARG(QVariant, move[1])));
            QVERIFY(ok.toBool());
        }
        QVERIFY(game->property("solved").toBool());
        QCOMPARE(game->property("moves").toInt(), path.size());
        QVERIFY(QMetaObject::invokeMethod(game.get(), "load", Q_ARG(QVariant, 1)));
        game.reset();
        game.reset(create(QStringLiteral("qml/games/TrafficJam.qml"), {900, 760}));
        QVERIFY(game);
        QCOMPARE(game->property("level").toInt(), 1);
        QCOMPARE(eval(game.get(), QStringLiteral("best[0]")).toInt(), path.size());

        // Undo walks a move back.
        QVERIFY(QMetaObject::invokeMethod(game.get(), "load", Q_ARG(QVariant, 0)));
        const QString before = eval(game.get(), QStringLiteral("positions.join(',')")).toString();
        const QVariantList first = path.first().toList();
        QVERIFY(QMetaObject::invokeMethod(game.get(), "slide", Q_RETURN_ARG(QVariant, ok),
                                          Q_ARG(QVariant, first[0]), Q_ARG(QVariant, first[1])));
        QVERIFY(QMetaObject::invokeMethod(game.get(), "undo"));
        QCOMPARE(eval(game.get(), QStringLiteral("positions.join(',')")).toString(), before);
        QCOMPARE(game->property("moves").toInt(), 0);
    }

    void sameGamePlaysAndQuitsToTheList()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("games/samegame/samegame.qml")));
        QVERIFY(game);
        QSignalSpy quit(game.get(), SIGNAL(quitRequested()));
        QTest::mouseClick(m_window, Qt::LeftButton, {}, QPoint(160, 157)); // "1 Player"
        QTRY_COMPARE(game->property("state").toString(), QStringLiteral("in-game"));
        QTest::qWait(1200); // the board fills in, the bars settle
        QTest::mouseClick(m_window, Qt::LeftButton, {}, QPoint(120, 300));
        QTest::qWait(300);
        QTest::mouseClick(m_window, Qt::LeftButton, {}, QPoint(20, 458)); // Quit
        QTRY_COMPARE(quit.count(), 1);
    }

    void maroonStartsAWave()
    {
        QScopedPointer<QQuickItem> game(create(QStringLiteral("games/maroon/maroon.qml")));
        QVERIFY(game);
        game->setProperty("passedSplash", true); // the Play button
        QTRY_VERIFY_WITH_TIMEOUT(eval(game.get(), QStringLiteral("gameState.gameRunning")).toBool(), 8000);
        QTest::mouseClick(m_window, Qt::LeftButton, {}, QPoint(100, 300)); // build menu
        QTest::qWait(1500);
    }
};

QTEST_MAIN(TestGames)
#include "tst_games.moc"
