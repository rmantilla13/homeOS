#pragma once

#include <QObject>
#include <QTime>
#include <QTimer>

// Owns the physical screen: idle → photo-frame mode, sleep (screen off),
// backlight level, night dimming, and (later) wake-on-presence from the
// mmWave radar.
//
// Installed as an application event filter so any touch resets the idle and
// sleep timers. A touch that wakes the screen is swallowed so it doesn't also
// press whatever button sits under the photo frame.
class DisplayController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    Q_PROPERTY(bool nightMode READ nightMode NOTIFY nightModeChanged)
    // Time-of-day mood that drives the dynamic palette: morning | day | evening | night.
    Q_PROPERTY(QString mood READ mood NOTIFY moodChanged)
    Q_PROPERTY(int idleTimeoutSec READ idleTimeoutSec WRITE setIdleTimeoutSec NOTIFY idleTimeoutChanged)
    Q_PROPERTY(qreal brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)
    Q_PROPERTY(bool hasBacklight READ hasBacklight CONSTANT)
    // Idle screen style: photos | collage | frame | memories | video | clock |
    // today. Remembered across restarts.
    Q_PROPERTY(QString screensaver READ screensaver WRITE setScreensaver NOTIFY screensaverChanged)
    // The collage's layout: auto (the next one each time the screen saver
    // starts) | classic | grid | mosaic | trio | columns. Remembered.
    Q_PROPERTY(QString collageLayout READ collageLayout WRITE setCollageLayout NOTIFY collageLayoutChanged)
    // Slow drift on the gradient tiles (Settings → Animated tiles). Remembered across restarts.
    Q_PROPERTY(bool animatedTiles READ animatedTiles WRITE setAnimatedTiles NOTIFY animatedTilesChanged)
    // Settings → Dark mode. Off keeps the time-of-day palette. Remembered across restarts.
    Q_PROPERTY(bool darkMode READ darkMode WRITE setDarkMode NOTIFY darkModeChanged)
    // Sleep: the screen turns off after this many seconds without a touch,
    // screen saver included. 0 = never. Remembered across restarts.
    Q_PROPERTY(int offAfterSec READ offAfterSec WRITE setOffAfterSec NOTIFY sleepSettingsChanged)
    // Off overnight: from bedtime to wakeTime (minutes after midnight) the
    // screen goes off instead of to the screen saver, and comes back on to the
    // screen saver at wakeTime. A touch still wakes it. Remembered across restarts.
    Q_PROPERTY(bool offAtNight READ offAtNight WRITE setOffAtNight NOTIFY sleepSettingsChanged)
    Q_PROPERTY(int bedtime READ bedtime WRITE setBedtime NOTIFY sleepSettingsChanged)
    Q_PROPERTY(int wakeTime READ wakeTime WRITE setWakeTime NOTIFY sleepSettingsChanged)
    // The screen is off: black, with the backlight or the panel itself powered
    // down where the hardware allows (see PanelPower). Off implies idle.
    Q_PROPERTY(bool screenOff READ screenOff NOTIFY screenOffChanged)

public:
    explicit DisplayController(QObject *parent = nullptr);

    bool idle() const { return m_idle; }
    bool nightMode() const { return m_nightMode; }
    QString mood() const { return m_mood; }
    int idleTimeoutSec() const { return m_idleTimer.interval() / 1000; }
    void setIdleTimeoutSec(int seconds);
    qreal brightness() const { return m_brightness; }
    void setBrightness(qreal level);
    bool hasBacklight() const { return !m_backlightPath.isEmpty(); }
    QString screensaver() const { return m_screensaver; }
    void setScreensaver(const QString &style);
    QString collageLayout() const { return m_collageLayout; }
    void setCollageLayout(const QString &layout);
    bool animatedTiles() const { return m_animatedTiles; }
    void setAnimatedTiles(bool on);
    bool darkMode() const { return m_darkMode; }
    void setDarkMode(bool on);
    int offAfterSec() const { return m_offAfterSec; }
    void setOffAfterSec(int seconds);
    bool offAtNight() const { return m_offAtNight; }
    void setOffAtNight(bool on);
    int bedtime() const { return m_bedtime; }
    void setBedtime(int minuteOfDay);   // wraps, so bedtime ± 30 is always valid
    int wakeTime() const { return m_wakeTime; }
    void setWakeTime(int minuteOfDay);
    bool screenOff() const { return m_screenOff; }

    Q_INVOKABLE void wake();
    // Shows the screen saver now (Preview on the Media page).
    Q_INVOKABLE void sleepNow();
    // Turns the screen off now, until a touch.
    Q_INVOKABLE void turnOffNow();
    // Counts as a touch while the screen is awake (a video playing in the
    // viewer). Never wakes a sleeping screen.
    Q_INVOKABLE void keepAwake();

    // Hook for the presence sensor (LD2410 over UART, M2).
    Q_INVOKABLE void presenceDetected() { wake(); }

    // Applies the overnight schedule for this time of day: off at bedtime if
    // nobody is using the screen, back on at wake time. Runs every minute;
    // public so tests can choose the time.
    void applySchedule(const QTime &now);
    // Whether minuteOfDay falls in [start, end), a window that may wrap past
    // midnight. An empty window (start == end) holds nothing.
    static bool inWindow(int minuteOfDay, int start, int end);

signals:
    void idleChanged();
    void nightModeChanged();
    void moodChanged();
    void idleTimeoutChanged();
    void brightnessChanged();
    void screensaverChanged();
    void collageLayoutChanged();
    void animatedTilesChanged();
    void darkModeChanged();
    void sleepSettingsChanged();
    void screenOffChanged();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void setIdle(bool idle);
    void setScreenOff(bool off);
    void restartTimers();
    void updateNightMode();
    void applyBacklight();

    QTimer m_idleTimer;
    QTimer m_offTimer;      // sleep: screen off after offAfterSec
    QTimer m_clockTimer;
    QTimer m_moodCycle;     // HOMEOS_MOOD=cycle: rotate moods for demos
    int m_cycleIndex = 0;
    bool m_idle = false;
    bool m_nightMode = false;
    QString m_mood = QStringLiteral("day");
    qreal m_brightness = 1.0;
    QString m_backlightPath; // /sys/class/backlight/<dev>
    int m_maxBacklight = 0;
    QString m_screensaver;
    QString m_collageLayout;
    bool m_animatedTiles = true;
    bool m_darkMode = false;
    int m_offAfterSec = 0;
    bool m_offAtNight = false;
    int m_bedtime = 0;        // minutes after midnight
    int m_wakeTime = 0;
    bool m_overnight = false; // offAtNight and between bedtime and wake time
    bool m_screenOff = false;
};
