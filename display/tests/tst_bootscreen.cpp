#include "hardware/BootScreen.h"

#include <QAnimationDriver>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QTemporaryDir>
#include <QtTest>

// Animation time three times faster than the wall clock. On a screen
// without vsync the render loop does this: it steps one frame per swap.
// QML Timers and animations run on this clock.
class FastAnimationDriver : public QAnimationDriver
{
public:
    FastAnimationDriver()
    {
        m_tick.setInterval(5);
        connect(&m_tick, &QTimer::timeout, this, [this]() { advance(); });
    }
    qint64 elapsed() const override { return m_clock.isValid() ? m_clock.elapsed() * 3 : 0; }

protected:
    void start() override
    {
        m_clock.start();
        m_tick.start();
        QAnimationDriver::start();
    }
    void stop() override
    {
        m_tick.stop();
        QAnimationDriver::stop();
    }

private:
    QElapsedTimer m_clock;
    QTimer m_tick;
};

// The boot screen: which video it plays (BootScreen), and how long
// BootScreen.qml stays up before it fades into the app.
class tst_BootScreen : public QObject
{
    Q_OBJECT

    QTemporaryDir m_dir;
    QString m_custom;
    QString m_cache;
    BootScreen *m_boot = nullptr;
    QQmlEngine *m_engine = nullptr;

    void write(const QString &path, const QByteArray &bytes)
    {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        file.write(bytes);
    }

    // BootScreen.qml with the given properties, outside any window (so it
    // starts on its timer, as on a platform that does not report frames).
    QObject *create(const QVariantMap &properties)
    {
        QQmlComponent component(m_engine, QUrl::fromLocalFile(QStringLiteral(HOMEOS_TEST_QML_DIR "/screens/BootScreen.qml")));
        QObject *screen = component.createWithInitialProperties(properties);
        if (!screen)
            qWarning() << component.errors();
        return screen;
    }
    static bool shown(QObject *screen) { return screen->property("visible").toBool(); }

private slots:
    void initTestCase()
    {
        QVERIFY(m_dir.isValid());
        m_custom = m_dir.filePath(QStringLiteral("custom.mp4"));
        m_cache = m_dir.filePath(QStringLiteral("cache.mp4"));
        qputenv("HOMEOS_BOOT_CUSTOM", m_custom.toUtf8());
        qputenv("HOMEOS_BOOT_CACHE", m_cache.toUtf8());
        qunsetenv("HOMEOS_BOOT_VIDEO");
        qunsetenv("HOMEOS_BOOT_SECONDS");

        m_boot = new BootScreen(false, this);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Boot", m_boot);
        m_engine = new QQmlEngine(this);
    }

    void cleanup()
    {
        QFile::remove(m_custom);
        QFile::remove(m_cache);
        qunsetenv("HOMEOS_BOOT_VIDEO");
        qunsetenv("HOMEOS_BOOT_SECONDS");
    }

    void builtInLogoByDefault()
    {
        QVERIFY(BootScreen::videoPath(true).isEmpty());
        QVERIFY(m_boot->video().isEmpty());
        QCOMPARE(m_boot->holdSeconds(), 5);
    }

    void localOverrideWins()
    {
        write(m_custom, "anything");
        write(m_cache, "xxxxftypisom");
        QCOMPARE(BootScreen::videoPath(true), m_custom);
        QCOMPARE(BootScreen::videoPath(false), m_custom);
        QCOMPARE(BootScreen(true).video(), QUrl::fromLocalFile(m_custom));
    }

    void adminVideoNeedsBackendAndMp4()
    {
        write(m_cache, "xxxxftypisom");
        QCOMPARE(BootScreen::videoPath(true), m_cache);
        // Not this display's backend: the built-in logo.
        QVERIFY(BootScreen::videoPath(false).isEmpty());
        // A captive-portal page saved as the video is not played.
        write(m_cache, "<html>captive portal</html>");
        QVERIFY(BootScreen::videoPath(true).isEmpty());
        write(m_cache, "ftyp");
        QVERIFY(BootScreen::videoPath(true).isEmpty());
    }

    void namedVideo()
    {
        const QString named = m_dir.filePath(QStringLiteral("my video.mp4"));
        write(named, "x");
        write(m_custom, "anything");
        qputenv("HOMEOS_BOOT_VIDEO", named.toUtf8());
        QCOMPARE(BootScreen::videoPath(false), named);
        qputenv("HOMEOS_BOOT_VIDEO", m_dir.filePath(QStringLiteral("missing.mp4")).toUtf8());
        QVERIFY(BootScreen::videoPath(false).isEmpty());
    }

    void holdSeconds_data()
    {
        QTest::addColumn<QByteArray>("value");
        QTest::addColumn<int>("seconds");
        QTest::newRow("default") << QByteArray() << 5;
        QTest::newRow("longer") << QByteArray("8") << 8;
        QTest::newRow("off") << QByteArray("0") << 0;
        QTest::newRow("negative") << QByteArray("-3") << 5;
        QTest::newRow("garbage") << QByteArray("soon") << 5;
        QTest::newRow("capped") << QByteArray("600") << 60;
    }

    void holdSeconds()
    {
        QFETCH(QByteArray, value);
        QFETCH(int, seconds);
        if (value.isNull())
            qunsetenv("HOMEOS_BOOT_SECONDS");
        else
            qputenv("HOMEOS_BOOT_SECONDS", value);
        QCOMPARE(BootScreen::holdSecondsFromEnvironment(), seconds);
    }

    // Up for the whole hold even when the app is ready at once, then gone.
    void holdsThenFadesIntoTheApp()
    {
        QScopedPointer<QObject> screen(create({{"holdSeconds", 1}, {"appReady", true}}));
        QVERIFY(screen);
        QVERIFY(shown(screen.data()));
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("contentShown").toBool(), 2000);
        QElapsedTimer clock;
        clock.start();
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("leaving").toBool(), 3000);
        QVERIFY2(clock.elapsed() >= 1550, "left before the hold was up");
        QVERIFY(shown(screen.data()));
        QTRY_VERIFY_WITH_TIMEOUT(!shown(screen.data()), 2000);

        // Gone for good, even if the app has nothing to show for a moment.
        screen->setProperty("appReady", false);
        QTest::qWait(1000);
        QVERIFY(!shown(screen.data()));
        QCOMPARE(screen->property("opacity").toReal(), 0.0);
    }

    // The hold is a promise in real seconds, whatever the animation clock does.
    void holdIsWallClock()
    {
        FastAnimationDriver fast;
        fast.install();
        QScopedPointer<QObject> screen(create({{"holdSeconds", 1}, {"appReady", true}}));
        QVERIFY(screen);
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("contentShown").toBool(), 2000);
        QElapsedTimer clock;
        clock.start();
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("leaving").toBool(), 4000);
        // fadeIn (600 ms) + 1 s, less the 50 ms QTRY polling step.
        QVERIFY2(clock.elapsed() >= 1550, qPrintable(QStringLiteral("left after %1 ms").arg(clock.elapsed())));
        QTRY_VERIFY_WITH_TIMEOUT(!shown(screen.data()), 2000);
        fast.uninstall();
    }

    // Held past the minimum while the app has nothing to show yet.
    void waitsForTheApp()
    {
        QScopedPointer<QObject> screen(create({{"holdSeconds", 1}, {"appReady", false}}));
        QVERIFY(screen);
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("held").toBool(), 4000);
        QTest::qWait(500);
        QVERIFY(shown(screen.data()));
        QVERIFY(!screen->property("leaving").toBool());
        screen->setProperty("appReady", true);
        QTRY_VERIFY_WITH_TIMEOUT(!shown(screen.data()), 2000);
    }

    // No network at boot: it gives up waiting and shows the app.
    void givesUpWaiting()
    {
        QScopedPointer<QObject> screen(create({{"holdSeconds", 1}, {"maxSeconds", 2}, {"appReady", false}}));
        QVERIFY(screen);
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("timedOut").toBool(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(!shown(screen.data()), 2000);
    }

    void offWithZeroSeconds()
    {
        QScopedPointer<QObject> screen(create({{"holdSeconds", 0}}));
        QVERIFY(screen);
        QVERIFY(!shown(screen.data()));
    }

    // A file that is not a video: the logo shows instead, and the hold still runs.
    void badVideoFallsBackToTheLogo()
    {
        write(m_custom, "not a video");
        QScopedPointer<QObject> screen(create({{"holdSeconds", 1}, {"appReady", true},
                                               {"video", QUrl::fromLocalFile(m_custom)}}));
        QVERIFY(screen);
        QVERIFY(screen->property("useVideo").toBool());
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("videoFailed").toBool(), 6000);
        QVERIFY(!screen->property("useVideo").toBool());
        QTRY_VERIFY_WITH_TIMEOUT(screen->property("contentShown").toBool(), 2000);
        QTRY_VERIFY_WITH_TIMEOUT(!shown(screen.data()), 4000);
    }
};

QTEST_MAIN(tst_BootScreen)
#include "tst_bootscreen.moc"
