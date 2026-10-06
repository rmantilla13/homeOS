#include "DisplayController.h"

#include <QDir>
#include <QEvent>
#include <QFile>
#include <QTime>

namespace {
constexpr int kDefaultIdleSec = 120;
constexpr qreal kNightBrightness = 0.25;
const QTime kNightStart(21, 30);
const QTime kNightEnd(6, 30);
} // namespace

DisplayController::DisplayController(QObject *parent) : QObject(parent)
{
    const int idleSec = qEnvironmentVariableIntValue("HOMEOS_IDLE_SECONDS");
    m_idleTimer.setInterval((idleSec > 0 ? idleSec : kDefaultIdleSec) * 1000);
    m_idleTimer.setSingleShot(true);
    connect(&m_idleTimer, &QTimer::timeout, this, [this]() { setIdle(true); });
    m_idleTimer.start();

    m_clockTimer.setInterval(60 * 1000);
    connect(&m_clockTimer, &QTimer::timeout, this, &DisplayController::updateNightMode);
    m_clockTimer.start();

    if (qEnvironmentVariable("HOMEOS_MOOD") == "cycle") {
        m_moodCycle.setInterval(6000);
        connect(&m_moodCycle, &QTimer::timeout, this, [this]() {
            m_cycleIndex = (m_cycleIndex + 1) % 4;
            updateNightMode();
        });
        m_moodCycle.start();
    }

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
    setIdle(false);
    m_idleTimer.start();
}

void DisplayController::sleepNow()
{
    m_idleTimer.stop();
    setIdle(true);
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
        m_idleTimer.start();
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
    QFile out(m_backlightPath + "/brightness");
    if (out.open(QIODevice::WriteOnly))
        out.write(QByteArray::number(qRound(level * m_maxBacklight)));
}
