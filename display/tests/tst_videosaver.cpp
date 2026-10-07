#include <QtTest>

#include <QMediaPlayer>
#include <QQmlComponent>
#include <QQmlEngine>

// Stands in for FamilyStore: the screensaver reads Store.media.
class FakeStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList media READ media NOTIFY mediaChanged)
public:
    QVariantList media() const { return m_media; }
    void setMedia(const QVariantList &media)
    {
        m_media = media;
        emit mediaChanged();
    }
signals:
    void mediaChanged();

private:
    QVariantList m_media;
};

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

// The video screensaver (VideoSaver.qml). Its player must keep the clip on
// screen when the list is rebuilt or its URL is signed again, move on when
// the clip is removed, and recover from clips that fail to load. The files
// don't exist, so every load fails the same way on GStreamer (Qt 6.4) and
// FFmpeg (Qt 6.8); the first checks run before that failure arrives.
class TestVideoSaver : public QObject
{
    Q_OBJECT

    FakeStore m_store;
    FakeDevice m_device;
    QQmlEngine *m_engine = nullptr;
    std::unique_ptr<QObject> m_saver;
    QObject *m_player = nullptr;

    // A video row as FamilyStore shows it; `signature` stands for a URL
    // signed again.
    static QVariantMap video(const QString &id, int signature = 1)
    {
        return {{"id", id},
                {"kind", "video"},
                {"url", QStringLiteral("file:///nonexistent/sig%1/%2.mp4").arg(signature).arg(id)},
                {"imageUrl", QString()},
                {"caption", id}};
    }
    QString source() const { return m_player->property("source").toUrl().toString(); }
    QString shownId() const { return m_saver->property("shown").toMap().value("id").toString(); }

    void create(const QVariantList &media)
    {
        m_store.setMedia(media);
        QQmlComponent component(m_engine);
        component.setData("import HomeOS\nVideoSaver { width: 1280; height: 800 }", QUrl());
        m_saver.reset(component.create());
        QVERIFY2(m_saver, qPrintable(component.errorString()));
        m_player = m_saver->findChild<QObject *>("saverPlayer");
        QVERIFY(m_player);
    }
    bool playerAvailable() const
    {
        auto *player = qobject_cast<QMediaPlayer *>(m_player);
        return player && player->isAvailable();
    }

private slots:
    void initTestCase()
    {
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Store", &m_store);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_TEST_QML_DIR));
    }

    void cleanup()
    {
        m_saver.reset();
        m_player = nullptr;
    }

    void firstVideoPlays()
    {
        create({video("a"), video("b")});
        QCOMPARE(source(), video("a").value("url").toString());
        QCOMPARE(shownId(), QStringLiteral("a"));
    }

    void signedAgainKeepsPlaying()
    {
        create({video("a"), video("b")});
        const QString playing = source();
        m_store.setMedia({video("a", 2), video("b", 2)});
        QCOMPARE(source(), playing);
        QCOMPARE(shownId(), QStringLiteral("a"));
        // A rebuild with the same rows doesn't touch the player either.
        m_store.setMedia({video("a", 2), video("b", 2)});
        QCOMPARE(source(), playing);
        // Nor does a new video at the front of the list.
        m_store.setMedia({video("c"), video("a", 2), video("b", 2)});
        QCOMPARE(source(), playing);
        QCOMPARE(shownId(), QStringLiteral("a"));
        QCOMPARE(m_saver->property("index").toInt(), 1);
    }

    void removingThePlayingVideoMovesOn()
    {
        create({video("a"), video("b"), video("c")});
        m_store.setMedia({video("b"), video("c")});
        QCOMPARE(source(), video("b").value("url").toString());
        QCOMPARE(shownId(), QStringLiteral("b"));
    }

    void emptyListClearsTheSource()
    {
        create({video("a")});
        m_store.setMedia({});
        QCOMPARE(source(), QString());
        QVERIFY(!m_saver->property("shown").isValid() || m_saver->property("shown").isNull());
    }

    void oneVideoLoops()
    {
        create({video("a")});
        QCOMPARE(m_player->property("loops").toInt(), int(QMediaPlayer::Infinite));
        m_store.setMedia({video("a"), video("b")});
        QCOMPARE(m_player->property("loops").toInt(), 1);
    }

    void oneVideoSignedAgainEndsItsLoop()
    {
        create({video("a")});
        QCOMPARE(m_player->property("loops").toInt(), int(QMediaPlayer::Infinite));
        // The URL in the player will expire: this pass is its last.
        m_store.setMedia({video("a", 2)});
        QCOMPARE(source(), video("a").value("url").toString());
        QCOMPARE(m_player->property("loops").toInt(), 1);
        // What the end of that pass does: the new URL loads and loops.
        m_saver->setProperty("playingKey", QString());
        QMetaObject::invokeMethod(m_saver.get(), "show", Q_ARG(QVariant, 1));
        QCOMPARE(source(), video("a", 2).value("url").toString());
        QCOMPARE(m_player->property("loops").toInt(), int(QMediaPlayer::Infinite));
        QVERIFY(!m_saver->property("frameShown").toBool());
    }

    void stalledVideoMovesOn()
    {
        create({video("a"), video("b")});
        QObject *watchdog = m_saver->findChild<QObject *>("saverWatchdog");
        QObject *backoff = m_saver->findChild<QObject *>("saverBackoff");
        QVERIFY(watchdog && backoff);
        // Still moving: nothing happens.
        m_saver->setProperty("moved", true);
        QMetaObject::invokeMethod(watchdog, "triggered");
        QVERIFY(!m_saver->property("failed").toBool());
        QVERIFY(!backoff->property("running").toBool());
        QVERIFY(!m_saver->property("moved").toBool());
        // No position change since the last look: the clip froze.
        m_saver->setProperty("frameShown", true);
        QMetaObject::invokeMethod(watchdog, "triggered");
        QVERIFY(m_saver->property("failed").toBool());
        QVERIFY(!m_saver->property("frameShown").toBool());
        QVERIFY(backoff->property("running").toBool());
        QCOMPARE(m_saver->property("errors").toInt(), 0);
    }

    void failedVideoIsRetried()
    {
        create({video("a")});
        if (!playerAvailable())
            QSKIP("No multimedia backend here");
        m_saver->setProperty("retryMs", 300);
        QTRY_VERIFY_WITH_TIMEOUT(m_saver->property("failed").toBool(), 10000);
        // The retry loads the same URL again: cleared, then set.
        QSignalSpy sourceChanged(qobject_cast<QMediaPlayer *>(m_player), &QMediaPlayer::sourceChanged);
        QTRY_VERIFY_WITH_TIMEOUT(sourceChanged.size() >= 2, 5000);
        QCOMPARE(sourceChanged.at(0).at(0).toUrl(), QUrl());
        QCOMPARE(sourceChanged.at(1).at(0).toUrl(), QUrl(video("a").value("url").toString()));
    }

    void failedVideoTakesAFreshUrl()
    {
        create({video("a")});
        if (!playerAvailable())
            QSKIP("No multimedia backend here");
        QTRY_VERIFY_WITH_TIMEOUT(m_saver->property("failed").toBool(), 10000);
        // A list update (say, the URL signed again) tries it straight away.
        m_store.setMedia({video("a", 2)});
        QCOMPARE(source(), video("a", 2).value("url").toString());
        QVERIFY(!m_saver->property("failed").toBool());
    }

    void failuresMoveOnThenWait()
    {
        create({video("a"), video("b")});
        if (!playerAvailable())
            QSKIP("No multimedia backend here");
        m_saver->setProperty("backoffMs", 100);
        // a fails, then after a short pause b plays (and fails too).
        QTRY_COMPARE_WITH_TIMEOUT(shownId(), QStringLiteral("b"), 10000);
        QCOMPARE(source(), video("b").value("url").toString());
        QTRY_VERIFY_WITH_TIMEOUT(m_saver->property("failed").toBool(), 10000);
        // Every clip failed in a row: no spinning through them, it waits for
        // the slow retry (30 s by default).
        QSignalSpy sourceChanged(qobject_cast<QMediaPlayer *>(m_player), &QMediaPlayer::sourceChanged);
        QTest::qWait(1500);
        QCOMPARE(sourceChanged.size(), 0);
        QCOMPARE(shownId(), QStringLiteral("b"));
        QCOMPARE(m_saver->property("errors").toInt(), 2);
    }
};

QTEST_MAIN(TestVideoSaver)
#include "tst_videosaver.moc"
