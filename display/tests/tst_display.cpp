#include "hardware/DisplayController.h"

#include <QSettings>
#include <QtTest>

// Display preferences remembered in QSettings. The settings sheet binds the
// Dark mode toggle to DisplayController::darkMode.
class tst_Display : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("homeOS-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_display"));
        QSettings().clear();
    }

    void cleanupTestCase() { QSettings().clear(); }

    void darkModeDefaultsOffAndIsRemembered()
    {
        {
            DisplayController device;
            QVERIFY(!device.darkMode());
            device.setDarkMode(true);
            QVERIFY(device.darkMode());
            QCOMPARE(QSettings().value(QStringLiteral("display/darkMode")).toBool(), true);
        }
        {
            DisplayController again;
            QVERIFY(again.darkMode());
            again.setDarkMode(false);
        }
        DisplayController third;
        QVERIFY(!third.darkMode());
    }

    // A playing video calls keepAwake(): it holds off the photo frame like a
    // touch would, but never wakes a screen that has already gone idle.
    void keepAwakeOnlyWhileAwake()
    {
        DisplayController device;
        device.setIdleTimeoutSec(1);
        QVERIFY(!device.idle());
        QElapsedTimer playing;
        playing.start();
        while (playing.elapsed() < 2500) {
            device.keepAwake();
            QTest::qWait(200);
            QVERIFY(!device.idle());
        }
        // Stopped: idle a second later.
        QTRY_VERIFY_WITH_TIMEOUT(device.idle(), 3000);
        device.keepAwake();
        QVERIFY(device.idle());
        QTest::qWait(100);
        QVERIFY(device.idle());
        // A touch still wakes it.
        device.wake();
        QVERIFY(!device.idle());
    }
};

QTEST_GUILESS_MAIN(tst_Display)
#include "tst_display.moc"
