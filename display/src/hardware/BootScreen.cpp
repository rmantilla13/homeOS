#include "BootScreen.h"

#include <QFile>
#include <QFileInfo>

namespace {
constexpr int kDefaultHoldSec = 5;
constexpr int kMaxHoldSec = 60;

QString pathFromEnv(const char *name, const char *fallback)
{
    const QString value = qEnvironmentVariable(name);
    return value.isEmpty() ? QString::fromLatin1(fallback) : value;
}
} // namespace

BootScreen::BootScreen(bool backendConfigured, QObject *parent)
    : QObject(parent), m_holdSeconds(holdSecondsFromEnvironment())
{
    const QString path = videoPath(backendConfigured);
    if (!path.isEmpty())
        m_video = QUrl::fromLocalFile(QFileInfo(path).absoluteFilePath());
}

QString BootScreen::videoPath(bool backendConfigured)
{
    const QString named = qEnvironmentVariable("HOMEOS_BOOT_VIDEO");
    if (!named.isEmpty())
        return QFileInfo(named).isFile() ? named : QString();

    const QString custom = pathFromEnv("HOMEOS_BOOT_CUSTOM", "/etc/homeos/boot.mp4");
    if (QFileInfo(custom).isFile())
        return custom;

    // The admin's video is only for a display that talks to that backend.
    const QString cache = pathFromEnv("HOMEOS_BOOT_CACHE", "/var/lib/homeos/boot.mp4");
    if (backendConfigured && isMp4(cache))
        return cache;
    return QString();
}

int BootScreen::holdSecondsFromEnvironment()
{
    const QString value = qEnvironmentVariable("HOMEOS_BOOT_SECONDS").trimmed();
    if (value.isEmpty())
        return kDefaultHoldSec;
    bool ok = false;
    const int seconds = value.toInt(&ok);
    if (!ok || seconds < 0)
        return kDefaultHoldSec;
    return qMin(seconds, kMaxHoldSec);
}

bool BootScreen::isMp4(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return false;
    const QByteArray head = file.read(8);
    return head.size() == 8 && head.mid(4, 4) == "ftyp";
}
