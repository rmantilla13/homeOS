#pragma once

#include <QObject>
#include <QUrl>

// What qml/screens/BootScreen.qml shows while the app starts. The app draws
// the boot screen itself, from its first frame, so nothing hands the panel
// over mid-boot and no console shows in between.
//
// video: a boot video to play instead of the built-in logo, or empty. A file
// at /etc/homeos/boot.mp4 is a local override. Otherwise, when a backend is
// configured, the video set in the admin console, which
// homeos-boot-video-sync downloads to /var/lib/homeos/boot.mp4.
// HOMEOS_BOOT_VIDEO names a file outright; HOMEOS_BOOT_CUSTOM and
// HOMEOS_BOOT_CACHE move the two default paths.
//
// holdSeconds: the boot screen stays up at least this long once it shows
// (HOMEOS_BOOT_SECONDS, default 5). 0 turns it off.
class BootScreen : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QUrl video READ video CONSTANT)
    Q_PROPERTY(int holdSeconds READ holdSeconds CONSTANT)

public:
    explicit BootScreen(bool backendConfigured, QObject *parent = nullptr);

    QUrl video() const { return m_video; }
    int holdSeconds() const { return m_holdSeconds; }

    static QString videoPath(bool backendConfigured);
    static int holdSecondsFromEnvironment();
    // MP4 and QuickTime files carry 'ftyp' at byte 4. A half-written
    // download or an HTML error page does not.
    static bool isMp4(const QString &path);

private:
    QUrl m_video;
    int m_holdSeconds;
};
