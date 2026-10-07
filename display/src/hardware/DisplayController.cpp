#include "DisplayController.h"

#include <QDir>
#include <QEvent>
#include <QFile>
#include <QSettings>
#include <QTime>

namespace {
constexpr int kDefaultIdleSec = 120;
constexpr qreal kNightBrightness = 0.25;
const QTime kNightStart(21, 30);
const QTime kNightEnd(6, 30);
constexpr int kMinutesPerDay = 24 * 60;
constexpr int kSecondsPerDay = kMinutesPerDay * 60;
constexpr int kDefaultBedtime = 22 * 60;        // 10:00 PM
constexpr int kDefaultWakeTime = 6 * 60 + 30;   // 6:30 AM

int wrapMinute(int minute)
{
    return ((minute % kMinutesPerDay) + kMinutesPerDay) % kMinutesPerDay;
}
} // namespace

DisplayController::DisplayController(QObject *parent) : QObject(parent)
{
    const int idleSec = qEnvironmentVariableIntValue("HOMEOS_IDLE_SECONDS");
    m_idleTimer.setInterval((idleSec > 0 ? idleSec : kDefaultIdleSec) * 1000);
    m_idleTimer.setSingleShot(true);
    connect(&m_idleTimer, &QTimer::timeout, this, [this]() {
        // Overnight, a screen nobody is using goes off rather than to the screen saver.
        if (m_overnight)
            turnOffNow();
        else
            setIdle(true);
    });
    m_offTimer.setSingleShot(true);
    connect(&m_offTimer, &QTimer::timeout, this, &DisplayController::turnOffNow);

    m_clockTimer.setInterval(60 * 1000);
    connect(&m_clockTimer, &QTimer::timeout, this, [this]() {
        updateNightMode();
        applySchedule(QTime::currentTime());
    });
    m_clockTimer.start();

    if (qEnvironmentVariable("HOMEOS_MOOD") == "cycle") {
        m_moodCycle.setInterval(6000);
        connect(&m_moodCycle, &QTimer::timeout, this, [this]() {
            m_cycleIndex = (m_cycleIndex + 1) % 4;
            updateNightMode();
        });
        m_moodCycle.start();
    }

    // HOMEOS_SCREENSAVER overrides the saved choice (handy for demos).
    m_screensaver = qEnvironmentVariable("HOMEOS_SCREENSAVER");
    if (m_screensaver.isEmpty())
        m_screensaver = QSettings().value("display/screensaver", "photos").toString();
    m_animatedTiles = QSettings().value("display/animatedTiles", true).toBool();
    m_darkMode = QSettings().value("display/darkMode", false).toBool();
    m_offAfterSec = qBound(0, QSettings().value("display/offAfterSeconds", 0).toInt(), kSecondsPerDay);
    m_offAtNight = QSettings().value("display/offAtNight", false).toBool();
    m_bedtime = wrapMinute(QSettings().value("display/bedtime", kDefaultBedtime).toInt());
    m_wakeTime = wrapMinute(QSettings().value("display/wakeTime", kDefaultWakeTime).toInt());
    m_overnight = m_offAtNight && inWindow(QTime::currentTime().msecsSinceStartOfDay() / 60000, m_bedtime, m_wakeTime);
    restartTimers();

    const QDir backlights(QStringLiteral("/sys/class/backlight"));
    const QStringList devices = backlights.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    if (!devices.isEmpty()) {
        m_backlightPath = backlights.filePath(devices.first());
        QFile max(m_backlightPath + "/max_brightness");
        if (max.open(QIODevice::ReadOnly))
            m_maxBacklight = max.readAll().trimmed().toInt();
    }
    updateNightMode();
}

void DisplayController::setIdleTimeoutSec(int seconds)
{
    if (seconds <= 0 || seconds == idleTimeoutSec())
        return;
    m_idleTimer.setInterval(seconds * 1000);
    if (!m_idle)
        m_idleTimer.start();
    emit idleTimeoutChanged();
}

void DisplayController::setBrightness(qreal level)
{
    level = qBound<qreal>(0.05, level, 1.0);
    if (qFuzzyCompare(level, m_brightness))
        return;
    m_brightness = level;
    applyBacklight();
    emit brightnessChanged();
}

void DisplayController::wake()
{
    setScreenOff(false);
    setIdle(false);
    restartTimers();
}

void DisplayController::sleepNow()
{
    // Overnight, the preview goes off after the usual idle time. Otherwise
    // the timer finds the screen already idle and does nothing.
    m_idleTimer.start();
    setScreenOff(false);
    setIdle(true);
}

void DisplayController::keepAwake()
{
    if (!m_idle)
        restartTimers();
}

// Activity: the screen saver and sleep both count from now.
void DisplayController::restartTimers()
{
    m_idleTimer.start();
    if (m_offAfterSec > 0)
        m_offTimer.start(m_offAfterSec * 1000);
    else
        m_offTimer.stop();
}

void DisplayController::turnOffNow()
{
    m_idleTimer.stop();
    m_offTimer.stop();
    setIdle(true);
    setScreenOff(true);
}

void DisplayController::applySchedule(const QTime &now)
{
    const bool overnight = m_offAtNight && inWindow(now.msecsSinceStartOfDay() / 60000, m_bedtime, m_wakeTime);
    if (overnight == m_overnight)
        return;
    m_overnight = overnight;
    if (overnight) {
        // Bedtime: the screen saver goes off. Someone using the screen keeps
        // it; it goes off once they leave it (the idle timer).
        if (m_idle)
            turnOffNow();
    } else if (m_screenOff) {
        // Wake time: back to the screen saver, which sleeps again after the
        // usual time if nobody touches it.
        setScreenOff(false);
        if (m_offAfterSec > 0)
            m_offTimer.start(m_offAfterSec * 1000);
    }
}

bool DisplayController::inWindow(int minuteOfDay, int start, int end)
{
    if (start == end)
        return false;
    if (start < end)
        return minuteOfDay >= start && minuteOfDay < end;
    return minuteOfDay >= start || minuteOfDay < end;
}

bool DisplayController::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::TouchBegin:
    case QEvent::MouseButtonPress:
    case QEvent::KeyPress:
        if (m_idle) {
            wake();
            return true; // the wake-up tap shouldn't also press a button
        }
        restartTimers();
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

void DisplayController::setIdle(bool idle)
{
    if (m_idle == idle)
        return;
    m_idle = idle;
    applyBacklight();
    emit idleChanged();
}

void DisplayController::setScreenOff(bool off)
{
    if (m_screenOff == off)
        return;
    m_screenOff = off;
    applyBacklight();
    emit screenOffChanged();
}

void DisplayController::updateNightMode()
{
    // HOMEOS_NIGHT_MODE=on|off overrides the schedule (handy for development).
    const QString forced = qEnvironmentVariable("HOMEOS_NIGHT_MODE");
    const QTime now = QTime::currentTime();
    const bool night = forced == "on" || (forced != "off" && (now >= kNightStart || now < kNightEnd));

    // HOMEOS_MOOD=morning|day|evening|night pins the palette (development, demos).
    QString mood = qEnvironmentVariable("HOMEOS_MOOD");
    if (mood == "cycle")
        mood = QStringList{"day", "evening", "night", "morning"}.at(m_cycleIndex);
    if (mood.isEmpty())
        mood = night ? "night" : now.hour() < 11 ? "morning" : now.hour() < 17 ? "day" : "evening";
    if (mood != m_mood) {
        m_mood = mood;
        emit moodChanged();
    }

    if (night == m_nightMode)
        return;
    m_nightMode = night;
    applyBacklight();
    emit nightModeChanged();
}

void DisplayController::applyBacklight()
{
    if (m_backlightPath.isEmpty() || m_maxBacklight <= 0)
        return;
    // TODO(M2): scale by the VEML7700 ambient light reading.
    qreal level = m_brightness;
    if (m_nightMode)
        level = qMin(level, kNightBrightness);
    if (m_screenOff)
        level = 0;
    QFile out(m_backlightPath + "/brightness");
    if (out.open(QIODevice::WriteOnly))
        out.write(QByteArray::number(qRound(level * m_maxBacklight)));
}

void DisplayController::setScreensaver(const QString &style)
{
    static const QStringList styles{"photos", "collage", "video"};
    if (!styles.contains(style) || style == m_screensaver)
        return;
    m_screensaver = style;
    QSettings().setValue("display/screensaver", style);
    emit screensaverChanged();
}

void DisplayController::setAnimatedTiles(bool on)
{
    if (on == m_animatedTiles)
        return;
    m_animatedTiles = on;
    QSettings().setValue("display/animatedTiles", on);
    emit animatedTilesChanged();
}

void DisplayController::setDarkMode(bool on)
{
    if (on == m_darkMode)
        return;
    m_darkMode = on;
    QSettings().setValue("display/darkMode", on);
    emit darkModeChanged();
}

void DisplayController::setOffAfterSec(int seconds)
{
    seconds = qBound(0, seconds, kSecondsPerDay);
    if (seconds == m_offAfterSec)
        return;
    m_offAfterSec = seconds;
    QSettings().setValue("display/offAfterSeconds", seconds);
    // Counts from now, like a touch (it was one: this is set from Settings).
    if (seconds == 0)
        m_offTimer.stop();
    else if (!m_screenOff)
        m_offTimer.start(seconds * 1000);
    emit sleepSettingsChanged();
}

void DisplayController::setOffAtNight(bool on)
{
    if (on == m_offAtNight)
        return;
    m_offAtNight = on;
    QSettings().setValue("display/offAtNight", on);
    applySchedule(QTime::currentTime());
    emit sleepSettingsChanged();
}

void DisplayController::setBedtime(int minuteOfDay)
{
    minuteOfDay = wrapMinute(minuteOfDay);
    if (minuteOfDay == m_bedtime)
        return;
    m_bedtime = minuteOfDay;
    QSettings().setValue("display/bedtime", minuteOfDay);
    applySchedule(QTime::currentTime());
    emit sleepSettingsChanged();
}

void DisplayController::setWakeTime(int minuteOfDay)
{
    minuteOfDay = wrapMinute(minuteOfDay);
    if (minuteOfDay == m_wakeTime)
        return;
    m_wakeTime = minuteOfDay;
    QSettings().setValue("display/wakeTime", minuteOfDay);
    applySchedule(QTime::currentTime());
    emit sleepSettingsChanged();
}
