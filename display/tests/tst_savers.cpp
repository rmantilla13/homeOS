#include <QtTest>

#include <QDir>
#include <QImageReader>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>

// Stands in for FamilyStore: the screen savers read photos, media, events
// and members.
class FakeStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList photos READ photos NOTIFY mediaChanged)
    Q_PROPERTY(QVariantList media READ media NOTIFY mediaChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY dataChanged)
    Q_PROPERTY(QVariantList members READ members NOTIFY dataChanged)
public:
    QVariantList photos() const { return m_photos; }
    QVariantList media() const { return m_photos; }
    QVariantList events() const { return m_events; }
    QVariantList members() const { return m_members; }
    void setPhotos(const QVariantList &photos)
    {
        m_photos = photos;
        emit mediaChanged();
    }
    void setData(const QVariantList &events, const QVariantList &members)
    {
        m_events = events;
        m_members = members;
        emit dataChanged();
    }
signals:
    void mediaChanged();
    void dataChanged();

private:
    QVariantList m_photos, m_events, m_members;
};

// Stands in for DisplayController: the theme, the gradient and the host.
class FakeDevice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mood READ mood CONSTANT)
    Q_PROPERTY(bool darkMode READ darkMode CONSTANT)
    Q_PROPERTY(bool animatedTiles READ animatedTiles CONSTANT)
    Q_PROPERTY(bool idle READ idle CONSTANT)
    Q_PROPERTY(QString screensaver MEMBER m_screensaver NOTIFY screensaverChanged)
public:
    QString mood() const { return QStringLiteral("evening"); }
    bool darkMode() const { return false; }
    bool animatedTiles() const { return true; }
    bool idle() const { return true; }
    QString m_screensaver = QStringLiteral("collage");
signals:
    void screensaverChanged();
};

// The screen savers: which photos go where (Picks.js), the collage's
// layouts and tiles, the host taking collage turns, and every style loading
// with and without data. With HOMEOS_SAVER_SHOTS=<dir> it also renders each
// style with the demo photos into that folder.
class TestSavers : public QObject
{
    Q_OBJECT

    FakeStore m_store;
    FakeDevice m_device;
    QQmlEngine *m_engine = nullptr;
    std::unique_ptr<QObject> m_helper;

    static QString moduleDir() { return QStringLiteral(HOMEOS_SAVERS_QML_DIR) + QStringLiteral("/HomeOS/"); }

    static QVariantMap photo(const QString &id, double aspect, qint64 takenMs = 0)
    {
        return {{"id", id}, {"kind", "photo"}, {"aspect", aspect}, {"takenMs", takenMs}, {"caption", id},
                {"url", QString()}, {"imageUrl", QString()}, {"tileUrl", QString()}};
    }
    static QVariantList landscapes(int count, const QString &prefix = QStringLiteral("l"))
    {
        QVariantList out;
        for (int i = 0; i < count; ++i)
            out << photo(prefix + QString::number(i), 1.5);
        return out;
    }
    static qint64 ms(int y, int m, int d) { return QDateTime(QDate(y, m, d), QTime(12, 0)).toMSecsSinceEpoch(); }

    // Picks.<name>(args...) through a QML object that imports the library.
    // null and undefined come back as an invalid QVariant.
    QVariant picks(const QString &name, const QVariantList &args)
    {
        QVariant result;
        QMetaObject::invokeMethod(m_helper.get(), "call", Q_RETURN_ARG(QVariant, result), Q_ARG(QVariant, name),
                                  Q_ARG(QVariant, args));
        if (result.typeId() == QMetaType::Nullptr)
            return {};
        if (result.typeId() != qMetaTypeId<QJSValue>())
            return result;
        const QJSValue js = result.value<QJSValue>();
        return js.isUndefined() || js.isNull() ? QVariant() : js.toVariant();
    }
    static QVariantMap map(const QVariant &v) { return v.toMap(); }
    static QVariantList list(const QVariant &v) { return v.toList(); }
    static QString id(const QVariant &v) { return v.toMap().value("id").toString(); }

    std::unique_ptr<QObject> create(const QByteArray &qml)
    {
        QQmlComponent component(m_engine);
        component.setData("import HomeOS\n" + qml, QUrl::fromLocalFile(moduleDir() + "test.qml"));
        std::unique_ptr<QObject> object(component.create());
        if (!object)
            qWarning().noquote() << component.errorString();
        return object;
    }
    // The ids in the collage's tiles, in tile order.
    static QStringList tiles(QObject *collage)
    {
        QStringList ids;
        for (const QVariant &v : collage->property("slots").toList())
            ids << id(v.value<QObject *>()->property("current"));
        return ids;
    }
    static bool distinct(const QStringList &ids)
    {
        return QSet<QString>(ids.cbegin(), ids.cend()).size() == ids.size() && !ids.contains(QString());
    }

private slots:
    void initTestCase()
    {
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Store", &m_store);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_SAVERS_QML_DIR));
        QQmlComponent helper(m_engine);
        helper.setData("import QtQuick\nimport \"screensaver/Picks.js\" as Picks\n"
                       "QtObject { function call(name, args) { return Picks[name].apply(null, args) } }",
                       QUrl::fromLocalFile(moduleDir() + "helper.qml"));
        m_helper.reset(helper.create());
        QVERIFY2(m_helper, qPrintable(helper.errorString()));
    }

    void init()
    {
        m_store.setPhotos({});
        m_store.setData({}, {});
        m_device.m_screensaver = QStringLiteral("collage");
    }

    // ── Picks.js ──

    void layoutsHaveATileForEachPhoto()
    {
        const QHash<QString, int> full{{"classic", 5}, {"grid", 6}, {"mosaic", 7}, {"trio", 3}, {"columns", 4}};
        for (auto it = full.cbegin(); it != full.cend(); ++it) {
            QVERIFY(!picks("layout", {it.key(), 0}).isValid());
            for (int n = 1; n <= 10; ++n) {
                const int count = map(picks("layout", {it.key(), n})).value("tiles").toList().size();
                QVERIFY2(count >= 1 && count <= n, qPrintable(QString("%1 with %2 photos: %3 tiles").arg(it.key()).arg(n).arg(count)));
                if (n >= it.value())
                    QCOMPARE(count, it.value());
            }
        }
        QCOMPARE(map(picks("layout", {"mosaic", 2})).value("name").toString(), QStringLiteral("duo"));
        QCOMPARE(map(picks("layout", {"grid", 4})).value("name").toString(), QStringLiteral("grid4"));
        QCOMPARE(map(picks("layout", {"columns", 3})).value("name").toString(), QStringLiteral("columns3"));
    }

    // Every cell of every layout belongs to exactly one tile.
    void layoutsCoverTheirGrid()
    {
        for (const char *turn : {"classic", "grid", "mosaic", "trio", "columns"}) {
            for (int n = 1; n <= 8; ++n) {
                const QVariantMap lay = map(picks("layout", {turn, n}));
                const int cols = lay.value("cols").toInt(), rows = lay.value("rows").toInt();
                QVector<int> cover(cols * rows, 0);
                for (const QVariant &v : lay.value("tiles").toList()) {
                    const QVariantMap t = v.toMap();
                    for (int r = t["r"].toInt(); r < t["r"].toInt() + t["h"].toInt(); ++r)
                        for (int c = t["c"].toInt(); c < t["c"].toInt() + t["w"].toInt(); ++c)
                            cover[r * cols + c] += 1;
                }
                QVERIFY2(std::all_of(cover.cbegin(), cover.cend(), [](int k) { return k == 1; }),
                         qPrintable(lay.value("name").toString()));
            }
        }
    }

    void pickSkipsPhotosShowingOrJustGone()
    {
        const QVariantList photos{photo("a", 1.5), photo("b", 1.5), photo("c", 1.5)};
        const double now = 1e6;
        // a is showing, b left a second ago: c.
        QCOMPARE(id(picks("pick", {photos, 1.5, QStringList{"a"}, QVariantMap{{"b", now - 1000}}, now, 60000})), QStringLiteral("c"));
        // b has rested long enough, but c was never shown: c first.
        QCOMPARE(id(picks("pick", {photos, 1.5, QStringList{"a"}, QVariantMap{{"b", now - 90000}}, now, 60000})), QStringLiteral("c"));
        // Both shown before: the one off screen longest.
        QCOMPARE(id(picks("pick", {photos, 1.5, QStringList{"a"}, QVariantMap{{"b", now - 90000}, {"c", now - 70000}}, now, 60000})),
                 QStringLiteral("b"));
        // Nothing may go there yet.
        QVERIFY(!picks("pick", {photos, 1.5, QStringList{"a", "c"}, QVariantMap{{"b", now - 1000}}, now, 60000}).isValid());
    }

    void pickPrefersTheTilesShape()
    {
        const QVariantList photos{photo("wide", 1.6), photo("tall", 0.66), photo("unknown", 0)};
        QCOMPARE(id(picks("pick", {photos, 0.6, QStringList{}, QVariantMap{}, 0, 0})), QStringLiteral("tall"));
        QCOMPARE(id(picks("pick", {photos, 1.8, QStringList{}, QVariantMap{}, 0, 0})), QStringLiteral("wide"));
        // A photo of unknown size fits anywhere; the newest goes first.
        QCOMPARE(id(picks("pick", {photos, 0.6, QStringList{"tall"}, QVariantMap{}, 0, 0})), QStringLiteral("unknown"));
        // No photo of the shape: still filled.
        QCOMPARE(id(picks("pick", {QVariantList{photo("wide", 1.6)}, 0.6, QStringList{}, QVariantMap{}, 0, 0})), QStringLiteral("wide"));
    }

    void chosenTileIsNeverTheLastOne()
    {
        const QVariantList tiles = map(picks("layout", {"classic", 9})).value("tiles").toList();
        QSet<int> chosen;
        for (int i = 0; i < 100; ++i) {
            const int tile = picks("chooseTile", {tiles, 2, i / 100.0}).toInt();
            QVERIFY(tile != 2);
            chosen.insert(tile);
        }
        QCOMPARE(chosen, (QSet<int>{0, 1, 3, 4}));
    }

    void framesPairPortraits()
    {
        const QVariantList photos{photo("p1", 0.75), photo("l1", 1.5), photo("p2", 0.66), photo("p3", 0.8), photo("u", 0)};
        QStringList shapes;
        for (const QVariant &f : list(picks("frames", {QVariant(photos)}))) {
            QStringList ids;
            for (const QVariant &p : f.toList())
                ids << id(p);
            shapes << ids.join('+');
        }
        QCOMPARE(shapes, (QStringList{"p1+p2", "l1", "p3", "u"}));
    }

    void memoriesAreFromThisDayInPastYears()
    {
        const QDateTime now(QDate(2026, 10, 7), QTime(9, 0));
        const QVariantList photos{photo("this-year", 1.5, ms(2026, 10, 7)),
                                  photo("week-1y", 1.5, ms(2025, 10, 9)),
                                  photo("today-2y", 1.5, ms(2024, 10, 7)),
                                  photo("today-5y", 1.5, ms(2021, 10, 7)),
                                  photo("march", 1.5, ms(2020, 3, 1)),
                                  photo("no-date", 1.5, 0)};
        QStringList found;
        for (const QVariant &m : list(picks("memories", {photos, now})))
            found << id(m.toMap().value("photo"))
                         + QStringLiteral(":%1:%2").arg(m.toMap().value("years").toInt()).arg(m.toMap().value("sameDay").toBool() ? "true" : "false");
        QCOMPARE(found, (QStringList{"today-5y:5:true", "today-2y:2:true", "week-1y:1:false"}));

        // Around New Year the anniversary can fall in the next year.
        const QDateTime newYearsEve(QDate(2026, 12, 30), QTime(9, 0));
        const QVariantList jan{photo("jan-1", 1.5, ms(2025, 1, 1))};
        const QVariantList hits = list(picks("memories", {jan, newYearsEve}));
        QCOMPARE(hits.size(), 1);
        QCOMPARE(hits.first().toMap().value("years").toInt(), 2);
    }

    // ── The collage ──

    void collageShowsEachPhotoOnceAndKeepsThemPut()
    {
        m_store.setPhotos(landscapes(10));
        auto collage = create("CollageSaver { width: 1280; height: 800; layoutName: \"mosaic\" }");
        QVERIFY(collage);
        QTRY_COMPARE(collage->property("slots").toList().size(), 7);
        QVERIFY(distinct(tiles(collage.get())));

        // Three spare photos: each step brings one in, and a photo that left
        // doesn't come back within the rest time (so nothing hops tiles).
        QSet<QString> left;
        for (int step = 0; step < 20; ++step) {
            const QStringList before = tiles(collage.get());
            QMetaObject::invokeMethod(collage.get(), "step");
            const QStringList after = tiles(collage.get());
            QVERIFY(distinct(after));
            for (const QString &k : after)
                QVERIFY2(!left.contains(k), qPrintable(k + " came back to another tile"));
            for (const QString &k : before)
                if (!after.contains(k))
                    left.insert(k);
        }
        // 10 photos, 7 tiles: after the 3 spares went up, nothing else may yet.
        QCOMPARE(left.size(), 3);
    }

    void collageWithFewPhotosUsesFewerTiles()
    {
        m_store.setPhotos(landscapes(3));
        auto collage = create("CollageSaver { width: 1280; height: 800; layoutName: \"classic\" }");
        QVERIFY(collage);
        QTRY_COMPARE(collage->property("slots").toList().size(), 3);
        QVERIFY(distinct(tiles(collage.get())));
        QCOMPARE(collage->property("layout").value<QJSValue>().property("name").toString(), QStringLiteral("trio"));

        // A fourth photo arrives: laid out again for four.
        m_store.setPhotos(landscapes(4));
        QTRY_COMPARE(collage->property("slots").toList().size(), 4);
        QVERIFY(distinct(tiles(collage.get())));
    }

    void collagePutsPortraitsInTallTiles()
    {
        QVariantList photos = landscapes(7);
        photos.insert(3, photo("portrait", 0.75));
        m_store.setPhotos(photos);
        auto collage = create("CollageSaver { width: 1280; height: 800; layoutName: \"mosaic\" }");
        QVERIFY(collage);
        QTRY_COMPARE(collage->property("slots").toList().size(), 7);
        // Mosaic's second tile is the tall one.
        QCOMPARE(tiles(collage.get()).at(1), QStringLiteral("portrait"));
    }

    void collageReplacesDeletedPhotos()
    {
        m_store.setPhotos(landscapes(8));
        auto collage = create("CollageSaver { width: 1280; height: 800; layoutName: \"classic\" }");
        QVERIFY(collage);
        QTRY_COMPARE(collage->property("slots").toList().size(), 5);
        const QString gone = tiles(collage.get()).at(2);
        QVariantList rest;
        for (const QVariant &p : landscapes(8))
            if (id(p) != gone)
                rest << p;
        m_store.setPhotos(rest);
        QVERIFY(!tiles(collage.get()).contains(gone));
        QVERIFY(distinct(tiles(collage.get())));
    }

    void hostTakesCollageTurns()
    {
        m_store.setPhotos(landscapes(10));
        auto host = create("ScreenSaver { width: 1280; height: 800 }");
        QVERIFY(host);
        QStringList turns;
        for (int i = 0; i < 6; ++i) {
            QObject *loader = host->findChild<QObject *>("saverContent");
            QVERIFY(loader);
            QObject *item = loader->property("item").value<QObject *>();
            QVERIFY(item);
            turns << item->property("layoutName").toString();
            host->setProperty("visible", false);
            host->setProperty("visible", true);
        }
        QCOMPARE(turns, (QStringList{"classic", "grid", "mosaic", "trio", "columns", "classic"}));
    }

    // ── Every style ──

    void stylesLoad_data()
    {
        QTest::addColumn<QString>("type");
        QTest::addColumn<bool>("withData");
        for (const char *type : {"CollageSaver", "SmartFrameSaver", "MemoriesSaver", "ClockSaver", "TodaySaver", "SlideshowSaver"}) {
            QTest::addRow("%s empty", type) << QString(type) << false;
            QTest::addRow("%s", type) << QString(type) << true;
        }
    }
    void stylesLoad()
    {
        QFETCH(QString, type);
        QFETCH(bool, withData);
        QTest::failOnWarning(QRegularExpression(QStringLiteral("qml|TypeError|ReferenceError|Unable to assign")));
        if (withData) {
            QVariantList photos = landscapes(5);
            photos << photo("p1", 0.75) << photo("p2", 0.7);
            m_store.setPhotos(photos);
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            const QString day = QDate::currentDate().toString(Qt::ISODate);
            m_store.setData({QVariantMap{{"title", "Soccer"}, {"day", day}, {"startMs", now + 3600000}, {"timeLabel", "5:00 pm – 6:00 pm"},
                             {"displayColor", "#7A64E8"}, {"all_day", false}}},
                            {QVariantMap{{"id", "m1"}, {"display_name", "Mia"}, {"initial", "M"}, {"color", "#EF8A6F"},
                                         {"tasksTotal", 3}, {"tasksDone", 1}}});
        }
        auto saver = create(type.toUtf8() + " { width: 1280; height: 800 }");
        QVERIFY(saver);
        QTest::qWait(50); // the collage fills on the next turn of the event loop
    }

    void smartFrameShowsPortraitsInPairs()
    {
        m_store.setPhotos({photo("p1", 0.75), photo("l1", 1.5), photo("p2", 0.7)});
        auto frame = create("SmartFrameSaver { width: 1280; height: 800 }");
        QVERIFY(frame);
        QCOMPARE(frame->property("frames").value<QJSValue>().property("length").toInt(), 2);
        QCOMPARE(id(frame->property("shown")), QStringLiteral("p1"));
    }

    // ── Screenshots (only with HOMEOS_SAVER_SHOTS) ──

    void renders()
    {
        const QString out = qEnvironmentVariable("HOMEOS_SAVER_SHOTS");
        if (out.isEmpty())
            QSKIP("set HOMEOS_SAVER_SHOTS=<dir> to render the screen savers");
        QDir().mkpath(out);
        const QDir media(QStringLiteral(HOMEOS_DEMO_MEDIA_DIR));
        const QStringList captions{"Beach day", "First day of school", "Camping trip", "Birthday party", "Snow day",
                                   "Sunday pancakes", "Grandma's garden", "Fireworks", "Aquarium", "Pumpkin patch",
                                   "Lemonade stand", "First steps", "Apple picking"};
        QVariantList photos;
        const QDateTime now = QDateTime::currentDateTime();
        for (int i = 1; i <= 13; ++i) {
            const QString file = media.filePath(QStringLiteral("photo%1.jpg").arg(i, 2, 10, QChar('0')));
            const QSize size = QImageReader(file).size();
            const QString url = QUrl::fromLocalFile(file).toString();
            const QDateTime taken = i == 12 ? now.addYears(-2) : i == 13 ? now.addYears(-1).addDays(-2) : now.addSecs(-3600 * 20 * i);
            photos << QVariantMap{{"id", QStringLiteral("photo%1").arg(i)}, {"kind", "photo"}, {"url", url}, {"imageUrl", url},
                                  {"tileUrl", url}, {"aspect", double(size.width()) / size.height()}, {"caption", captions.at(i - 1)},
                                  {"takenMs", taken.toMSecsSinceEpoch()}, {"dateLabel", QLocale().toString(taken.date(), "dddd, MMMM d")},
                                  {"tint", "#3A5A78"}, {"tintDeep", "#16222E"}};
        }
        // Portraits up front so the smart frame opens on a pair.
        std::stable_sort(photos.begin(), photos.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value("aspect").toDouble() < b.toMap().value("aspect").toDouble();
        });
        m_store.setPhotos(photos);
        const QDate today = QDate::currentDate();
        auto event = [&](const char *title, int hour, int minutes, const char *color, const char *who) {
            const QDateTime start(today, QTime(hour, minutes));
            return QVariantMap{{"title", title}, {"day", today.toString(Qt::ISODate)}, {"startMs", start.toMSecsSinceEpoch()},
                               {"timeLabel", QLocale().toString(start.time(), "h:mm ap") + " – " + QLocale().toString(start.time().addSecs(3600), "h:mm ap")},
                               {"displayColor", color}, {"all_day", false}, {"memberNames", who}};
        };
        m_store.setData({event("School drop-off", 7, 45, "#5B7CF5", "Emma, Leo"), event("Piano lesson", 16, 0, "#7A64E8", "Emma"),
                         event("Soccer practice", 17, 30, "#3DB37A", "Leo"), event("Family dinner", 19, 0, "#EF8A6F", "")},
                        {QVariantMap{{"display_name", "Emma"}, {"initial", "E"}, {"color", "#7A64E8"}, {"tasksTotal", 3}, {"tasksDone", 1}},
                         QVariantMap{{"display_name", "Leo"}, {"initial", "L"}, {"color", "#3DB37A"}, {"tasksTotal", 2}, {"tasksDone", 2}}});

        const QList<QPair<QString, QString>> shots{{"collage-classic", "collage"}, {"collage-grid", "collage"},
                                                    {"collage-mosaic", "collage"}, {"collage-trio", "collage"},
                                                    {"collage-columns", "collage"}, {"frame", "frame"},
                                                    {"memories", "memories"}, {"clock", "clock"}, {"today", "today"}};
        int turn = 0;
        for (const auto &[name, style] : shots) {
            m_device.m_screensaver = style;
            QQmlComponent component(m_engine);
            component.setData(QStringLiteral("import QtQuick\nimport HomeOS\nWindow { width: 1280; height: 800; visible: true; color: \"black\"\n"
                                             "ScreenSaver { anchors.fill: parent; collageTurn: %1 } }")
                                  .arg(style == "collage" ? turn++ : 0)
                                  .toUtf8(),
                              QUrl::fromLocalFile(moduleDir() + "shot.qml"));
            std::unique_ptr<QObject> object(component.create());
            QVERIFY2(object, qPrintable(component.errorString()));
            auto *window = qobject_cast<QQuickWindow *>(object.get());
            QVERIFY(window);
            QTest::qWait(2500); // images load and cross-fades settle
            const QImage image = window->grabWindow();
            QVERIFY(!image.isNull());
            QVERIFY(image.save(QDir(out).filePath(name + ".png")));
        }

        // The style cards: the Media page's picker, then Settings (compact).
        m_device.m_screensaver = QStringLiteral("collage");
        for (const auto &[name, size] : QList<QPair<QString, QString>>{{"picker", "836; cardHeight: 230"}, {"settings", "600; cardHeight: 132; gap: 12"}}) {
            QQmlComponent component(m_engine);
            component.setData(QStringLiteral("import QtQuick\nimport HomeOS\nWindow { width: 900; height: 560; visible: true; color: Theme.surface\n"
                                             "ScreenSaverOptions { x: 32; y: 32; width: %1 } }")
                                  .arg(size)
                                  .toUtf8(),
                              QUrl::fromLocalFile(moduleDir() + "shot.qml"));
            std::unique_ptr<QObject> object(component.create());
            QVERIFY2(object, qPrintable(component.errorString()));
            auto *window = qobject_cast<QQuickWindow *>(object.get());
            QVERIFY(window);
            QTest::qWait(500);
            QVERIFY(window->grabWindow().save(QDir(out).filePath(name + ".png")));
        }
    }
};

QTEST_MAIN(TestSavers)
#include "tst_savers.moc"
