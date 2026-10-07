#include "hardware/DisplayController.h"

#include <QSettings>
#include <QtTest>

// Display preferences remembered in QSettings, and when the screen goes idle
// and off. The settings sheet binds its Dark mode and Sleep controls to
// DisplayController.
class tst_Display : public QObject
{
    Q_OBJECT

    // What a touch looks like to the event filter: only the type matters.
    static bool touch(QObject *target)
    {
        QEvent press(QEvent::MouseButtonPress);
        return QCoreApplication::sendEvent(target, &press);
    }

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("homeOS-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_display"));
    }

    // Each test starts from the defaults.
    void init() { QSettings().clear(); }

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

    void sleepIsOffByDefault()
    {
        DisplayController device;
        QCOMPARE(device.offAfterSec(), 0);
        QVERIFY(!device.offAtNight());
        QCOMPARE(device.bedtime(), 22 * 60);
        QCOMPARE(device.wakeTime(), 6 * 60 + 30);
        QVERIFY(!device.screenOff());
    }

    // Screen saver after the idle time, then off after the sleep time, both
    // counted from the last touch. The touch that wakes it is swallowed.
    void sleepTurnsTheScreenOffAndATouchWakesIt()
    {
        DisplayController device;
        QObject target;
        target.installEventFilter(&device);
        device.setIdleTimeoutSec(1);
        device.setOffAfterSec(2);
        QSignalSpy offChanged(&device, &DisplayController::screenOffChanged);

        QTRY_VERIFY_WITH_TIMEOUT(device.idle(), 2000);
        QVERIFY(!device.screenOff());
        QTRY_VERIFY_WITH_TIMEOUT(device.screenOff(), 3000);
        QVERIFY(device.idle());
        QCOMPARE(offChanged.count(), 1);

        QVERIFY(touch(&target)); // swallowed: it doesn't press what's underneath
        QVERIFY(!device.screenOff());
        QVERIFY(!device.idle());
        QVERIFY(!touch(&target)); // awake: touches go through

        // Touches keep it on.
        QElapsedTimer inUse;
        inUse.start();
        while (inUse.elapsed() < 3000) {
            touch(&target);
            QTest::qWait(200);
            QVERIFY(!device.screenOff());
        }

        // Never: the screen saver stays up.
        device.setOffAfterSec(0);
        QTRY_VERIFY_WITH_TIMEOUT(device.idle(), 2000);
        QTest::qWait(2500);
        QVERIFY(!device.screenOff());
    }

    void sleepSettingsAreRemembered()
    {
        {
            DisplayController device;
            device.setOffAfterSec(1800);
            device.setOffAtNight(true);
            device.setBedtime(-30);          // wraps to 11:30 PM
            device.setWakeTime(24 * 60 + 15); // wraps to 12:15 AM
            device.setOffAfterSec(-5);       // clamped to never
            device.setOffAfterSec(1800);
        }
        DisplayController again;
        QCOMPARE(again.offAfterSec(), 1800);
        QVERIFY(again.offAtNight());
        QCOMPARE(again.bedtime(), 23 * 60 + 30);
        QCOMPARE(again.wakeTime(), 15);
    }

    void turnOffNowUntilATouch()
    {
        DisplayController device;
        device.turnOffNow();
        QVERIFY(device.screenOff());
        QVERIFY(device.idle());
        // A playing video doesn't turn it back on.
        device.keepAwake();
        QVERIFY(device.screenOff());
        device.wake();
        QVERIFY(!device.screenOff());
        QVERIFY(!device.idle());
    }

    void windowWrapsPastMidnight()
    {
        QVERIFY(DisplayController::inWindow(23 * 60, 22 * 60, 6 * 60));
        QVERIFY(DisplayController::inWindow(0, 22 * 60, 6 * 60));
        QVERIFY(DisplayController::inWindow(22 * 60, 22 * 60, 6 * 60));
        QVERIFY(!DisplayController::inWindow(6 * 60, 22 * 60, 6 * 60));
        QVERIFY(!DisplayController::inWindow(12 * 60, 22 * 60, 6 * 60));
        QVERIFY(DisplayController::inWindow(14 * 60, 13 * 60, 15 * 60));
        QVERIFY(!DisplayController::inWindow(15 * 60, 13 * 60, 15 * 60));
        QVERIFY(!DisplayController::inWindow(12 * 60, 12 * 60, 12 * 60));
    }

    // Off overnight: the screen saver goes off at bedtime and comes back at
    // wake time. Someone using the screen at bedtime keeps it until they stop.
    void overnightScheduleTurnsOffAndBackOn()
    {
        DisplayController device;
        device.setOffAtNight(true); // 10:00 PM to 6:30 AM
        device.applySchedule(QTime(12, 0));

        device.sleepNow(); // the screen saver is up
        device.applySchedule(QTime(21, 59));
        QVERIFY(!device.screenOff());
        device.applySchedule(QTime(22, 0));
        QVERIFY(device.screenOff());
        device.applySchedule(QTime(3, 0));
        QVERIFY(device.screenOff());
        device.applySchedule(QTime(6, 30));
        QVERIFY(!device.screenOff());
        QVERIFY(device.idle()); // back to the screen saver

        // In use at bedtime: stays on, then goes straight off when left alone.
        device.setIdleTimeoutSec(1);
        device.wake();
        device.applySchedule(QTime(22, 0));
        QVERIFY(!device.screenOff());
        QTRY_VERIFY_WITH_TIMEOUT(device.screenOff(), 2000);

        // A tap at night wakes it; left alone, it goes off again.
        device.wake();
        QVERIFY(!device.screenOff());
        QTRY_VERIFY_WITH_TIMEOUT(device.screenOff(), 2000);

        // Turned off, the schedule leaves the screen alone.
        device.wake();
        device.setOffAtNight(false);
        device.applySchedule(QTime(23, 0));
        QTRY_VERIFY_WITH_TIMEOUT(device.idle(), 2000);
        QVERIFY(!device.screenOff());
    }

    // Wake time also brings back a screen the sleep timer turned off, and
    // the sleep timer then runs again.
    void wakeTimeRestartsTheSleepTimer()
    {
        DisplayController device;
        device.setOffAtNight(true);
        device.applySchedule(QTime(12, 0));
        device.applySchedule(QTime(23, 0));
        device.turnOffNow();
        device.setOffAfterSec(1);
        device.applySchedule(QTime(6, 30));
        QVERIFY(!device.screenOff());
        QTRY_VERIFY_WITH_TIMEOUT(device.screenOff(), 2000);
    }
};

QTEST_GUILESS_MAIN(tst_Display)
#include "tst_display.moc"
