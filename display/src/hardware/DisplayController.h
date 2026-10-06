#pragma once

#include <QObject>
#include <QTimer>

// Owns the physical screen: idle → photo-frame mode, backlight level, night
// dimming, and (later) wake-on-presence from the mmWave radar.
//
// Installed as an application event filter so any touch resets the idle
// timer. A touch that wakes the screen is swallowed so it doesn't also press
// whatever button sits under the photo frame.
class DisplayController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    Q_PROPERTY(bool nightMode READ nightMode NOTIFY nightModeChanged)
    Q_PROPERTY(int idleTimeoutSec READ idleTimeoutSec WRITE setIdleTimeoutSec NOTIFY idleTimeoutChanged)
    Q_PROPERTY(qreal brightness READ brightness WRITE setBrightness NOTIFY brightnessChanged)
    Q_PROPERTY(bool hasBacklight READ hasBacklight CONSTANT)

public:
    explicit DisplayController(QObject *parent = nullptr);

    bool idle() const { return m_idle; }
    bool nightMode() const { return m_nightMode; }
    int idleTimeoutSec() const { return m_idleTimer.interval() / 1000; }
    void setIdleTimeoutSec(int seconds);
    qreal brightness() const { return m_brightness; }
    void setBrightness(qreal level);
    bool hasBacklight() const { return !m_backlightPath.isEmpty(); }

    Q_INVOKABLE void wake();
    Q_INVOKABLE void sleepNow();

    // Hook for the presence sensor (LD2410 over UART, M2).
    Q_INVOKABLE void presenceDetected() { wake(); }

signals:
    void idleChanged();
    void nightModeChanged();
    void idleTimeoutChanged();
    void brightnessChanged();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void setIdle(bool idle);
    void updateNightMode();
    void applyBacklight();

    QTimer m_idleTimer;
    QTimer m_clockTimer;
    bool m_idle = false;
    bool m_nightMode = false;
    qreal m_brightness = 1.0;
    QString m_backlightPath; // /sys/class/backlight/<dev>
    int m_maxBacklight = 0;
};
