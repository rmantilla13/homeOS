#!/bin/bash
# Runs the installed app with the device's settings, drawing to a virtual
# 1920x1200 screen (the 10.1" panel) served over VNC on port 5900.
set -e
set -a
. /etc/homeos/display.env
set +a
# The real device draws straight to the panel (eglfs); here Qt serves the screen over VNC.
export QT_QPA_PLATFORM="vnc:size=1920x1200:port=5900"
exec /usr/local/bin/homeos-display "$@"
