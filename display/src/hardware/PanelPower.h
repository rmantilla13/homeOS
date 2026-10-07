#pragma once

#include <QObject>
#include <QTimer>

class DisplayController;

// Powers the panel down while the screen is off, and back up when it wakes.
//
// DisplayController already paints the screen black and zeroes a DSI or eDP
// backlight. An HDMI panel has no backlight control, so this sets its DPMS
// state instead. Only the process holding the DRM device can do that, which
// is Qt's eglfs_kms screen, through a private Qt API (qt6-base-private-dev).
// Without those headers, or on any other platform, the screen is only black.
//
// HOMEOS_PANEL_POWER=off keeps the panel powered, for a screen that shows
// "No signal" instead of going dark.
class PanelPower : public QObject
{
    Q_OBJECT

public:
    explicit PanelPower(DisplayController *display, QObject *parent = nullptr);

private:
    void setPanelOn(bool on);

    DisplayController *m_display;
    QTimer m_offDelay;
    bool m_on = true;
};
