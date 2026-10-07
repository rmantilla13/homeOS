#include "PanelPower.h"

#include "DisplayController.h"

#include <QGuiApplication>
#include <QScreen>
#ifdef HOMEOS_PANEL_POWER
#include <qpa/qplatformscreen.h>
#endif

namespace {
// Lets the fade to black reach the panel before the signal stops.
constexpr int kOffDelayMs = 1500;
} // namespace

PanelPower::PanelPower(DisplayController *display, QObject *parent)
    : QObject(parent), m_display(display)
{
    if (QGuiApplication::platformName() != QLatin1String("eglfs"))
        return;
#ifndef HOMEOS_PANEL_POWER
    qWarning("homeOS display: built without Qt's private headers (qt6-base-private-dev), "
             "so an HDMI panel stays lit while the screen is off. Run install-pi.sh again.");
#else
    if (qEnvironmentVariable("HOMEOS_PANEL_POWER") == QLatin1String("off")) {
        qInfo("homeOS display: HOMEOS_PANEL_POWER=off, the panel stays powered while the screen is off");
        return;
    }
    m_offDelay.setSingleShot(true);
    m_offDelay.setInterval(kOffDelayMs);
    connect(&m_offDelay, &QTimer::timeout, this, [this]() { setPanelOn(false); });
    connect(display, &DisplayController::screenOffChanged, this, [this]() {
        if (m_display->screenOff()) {
            m_offDelay.start();
        } else {
            m_offDelay.stop();
            setPanelOn(true);
        }
    });
#endif
}

void PanelPower::setPanelOn(bool on)
{
#ifdef HOMEOS_PANEL_POWER
    if (on == m_on)
        return;
    m_on = on;
    // eglfs_kms sets the connector's DPMS property; the panel sleeps as it
    // would with its source switched off, and wakes when the signal returns.
    const auto state = on ? QPlatformScreen::PowerStateOn : QPlatformScreen::PowerStateOff;
    const auto screens = QGuiApplication::screens();
    for (QScreen *screen : screens) {
        if (QPlatformScreen *platform = screen->handle())
            platform->setPowerState(state);
    }
    qInfo("homeOS display: panel %s", on ? "on" : "off");
#else
    Q_UNUSED(on);
#endif
}
