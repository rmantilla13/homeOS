# Simulated homeOS device: Debian Trixie (the base of Raspberry Pi OS) on arm64,
# set up with the real install script, showing the app on a virtual 1920x1200
# screen you open with a VNC viewer. See docs/PI_SETUP.md → "Try it without a Pi".
#
#   docker build --platform linux/arm64 -f display/deploy/pi-sim/Dockerfile -t homeos-pi-sim .
#   docker run --rm -p 5900:5900 homeos-pi-sim
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends sudo ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# A normal sudo user, like the first user on a fresh Pi.
RUN useradd -m -s /bin/bash pi && echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/pi
# No systemd in a container; the stub records what the installer would enable.
COPY display/deploy/pi-sim/systemctl-stub /usr/local/bin/systemctl

COPY --chown=pi:pi . /home/pi/homeOS
USER pi
WORKDIR /home/pi/homeOS
RUN rm -rf build && ./display/deploy/install-pi.sh

COPY display/deploy/pi-sim/start.sh /usr/local/bin/start-sim
EXPOSE 5900
CMD ["start-sim"]
