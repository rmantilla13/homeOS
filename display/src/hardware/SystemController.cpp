#include "SystemController.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QHostAddress>
#include <QNetworkInterface>
#include <QSettings>
#include <QStandardPaths>

namespace {
constexpr auto kHelper = "/usr/local/libexec/homeos-system";

bool isOpenSecurity(const QString &security)
{
    const QString s = security.trimmed();
    return s.isEmpty() || s == QLatin1String("--");
}

QVariantMap toMap(const WifiNetwork &network)
{
    return {
        {QStringLiteral("ssid"), network.ssid},
        {QStringLiteral("signal"), network.signal},
        {QStringLiteral("secure"), network.secure},
        {QStringLiteral("inUse"), network.inUse},
        {QStringLiteral("saved"), network.saved},
    };
}
} // namespace

SystemController::SystemController(QObject *parent) : QObject(parent)
{
    m_timeout.setSingleShot(true);
    connect(&m_proc, &QProcess::finished, this, &SystemController::onFinished);
    connect(&m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            onStartFailed();
    });
    connect(&m_timeout, &QTimer::timeout, this, [this]() { m_proc.kill(); });
}

void SystemController::start()
{
    const QString overrideHelper = qEnvironmentVariable("HOMEOS_SYSTEM_HELPER");
    m_haveHelper = QFileInfo(overrideHelper.isEmpty() ? QString::fromLatin1(kHelper) : overrideHelper).isExecutable();
    m_haveNmcli = !QStandardPaths::findExecutable(QStringLiteral("nmcli")).isEmpty();
    m_wpctl = QStandardPaths::findExecutable(QStringLiteral("wpctl"));
    m_wifiAvailable = m_haveHelper || m_haveNmcli;
    m_canManageWifi = m_wifiAvailable;
    m_canReboot = m_haveHelper;
    emit availabilityChanged();
    refresh();
}

QString SystemController::helperPath() const
{
    const QString overrideHelper = qEnvironmentVariable("HOMEOS_SYSTEM_HELPER");
    return overrideHelper.isEmpty() ? QString::fromLatin1(kHelper) : overrideHelper;
}

bool SystemController::helperReady() const
{
    return m_haveHelper;
}

void SystemController::setMessage(const QString &text)
{
    if (m_message == text)
        return;
    m_message = text;
    emit messageChanged();
}

void SystemController::updateIp()
{
    QString wifiIp;
    QString otherIp;
    const auto ifaces = QNetworkInterface::allInterfaces();
    for (const QNetworkInterface &iface : ifaces) {
        if (!(iface.flags() & QNetworkInterface::IsUp) || (iface.flags() & QNetworkInterface::IsLoopBack))
            continue;
        const QString name = iface.name();
        if (name.startsWith(QLatin1String("docker")) || name.startsWith(QLatin1String("veth"))
            || name.startsWith(QLatin1String("br-")))
            continue;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            const QHostAddress address = entry.ip();
            if (address.protocol() != QAbstractSocket::IPv4Protocol || address.isLoopback())
                continue;
            if (name.startsWith(QLatin1String("wl")))
                wifiIp = address.toString();
            else if (otherIp.isEmpty())
                otherIp = address.toString();
        }
    }
    const QString ip = wifiIp.isEmpty() ? otherIp : wifiIp;
    if (ip == m_ipAddress)
        return;
    m_ipAddress = ip;
    emit ipChanged();
}

void SystemController::refresh()
{
    updateIp();
    if (m_busy)
        return;
    if (m_wifiAvailable) {
        if (helperReady())
            begin(QStringLiteral("status"), QStringLiteral("sudo"), {QStringLiteral("-n"), helperPath(), QStringLiteral("wifi-status")}, {}, 8000);
        else
            begin(QStringLiteral("status"), QStringLiteral("sh"),
                  {QStringLiteral("-c"),
                   QStringLiteral("nmcli -t -f WIFI radio; echo ---; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status")},
                  {}, 8000);
    } else if (!m_wpctl.isEmpty()) {
        begin(QStringLiteral("volume"), m_wpctl, {QStringLiteral("get-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@")}, {}, 4000);
    }
}

void SystemController::scanWifi()
{
    setMessage({});
    rescanWifi();
}

void SystemController::rescanWifi()
{
    if (!m_canManageWifi || m_busy)
        return;
    if (helperReady())
        begin(QStringLiteral("scan"), QStringLiteral("sudo"), {QStringLiteral("-n"), helperPath(), QStringLiteral("wifi-scan")}, {}, 30000);
    else
        begin(QStringLiteral("scan"), QStringLiteral("sh"),
              {QStringLiteral("-c"),
               QStringLiteral("nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan yes; echo ---; nmcli -t -f NAME,TYPE connection show")},
              {}, 30000);
}

void SystemController::connectWifi(const QString &ssid, const QString &password, bool saved)
{
    if (!m_canManageWifi || m_busy)
        return;
    if (!validSsid(ssid)) {
        setMessage(QStringLiteral("That network name isn't usable."));
        return;
    }
    QString mode = QStringLiteral("open");
    if (!password.isEmpty()) {
        if (!validPassword(password)) {
            setMessage(QStringLiteral("That password isn't usable."));
            return;
        }
        mode = QStringLiteral("psk");
    } else if (saved) {
        mode = QStringLiteral("saved");
    }
    setMessage({});
    const QByteArray input = password.toUtf8() + '\n';
    if (helperReady()) {
        begin(QStringLiteral("connect"), QStringLiteral("sudo"),
              {QStringLiteral("-n"), helperPath(), QStringLiteral("wifi-connect"), ssid, mode}, input, 40000);
    } else if (mode == QLatin1String("psk")) {
        delete m_secret;
        m_secret = new QTemporaryFile(this);
        if (!m_secret->open()) {
            setMessage(QStringLiteral("Couldn't store that password."));
            return;
        }
        m_secret->write(password.toUtf8());
        m_secret->flush();
        begin(QStringLiteral("connect"), QStringLiteral("nmcli"),
              {QStringLiteral("--wait"), QStringLiteral("25"), QStringLiteral("device"), QStringLiteral("wifi"),
               QStringLiteral("connect"), ssid, QStringLiteral("password-file"), m_secret->fileName()},
              {}, 40000);
    } else if (mode == QLatin1String("saved")) {
        begin(QStringLiteral("connect"), QStringLiteral("nmcli"),
              {QStringLiteral("--wait"), QStringLiteral("25"), QStringLiteral("connection"), QStringLiteral("up"),
               QStringLiteral("id"), ssid},
              {}, 40000);
    } else {
        begin(QStringLiteral("connect"), QStringLiteral("nmcli"),
              {QStringLiteral("--wait"), QStringLiteral("25"), QStringLiteral("device"), QStringLiteral("wifi"),
               QStringLiteral("connect"), ssid},
              {}, 40000);
    }
}

void SystemController::setWifiEnabled(bool on)
{
    if (!m_canManageWifi || m_busy)
        return;
    setMessage({});
    m_radioGoal = on;
    const QString flag = on ? QStringLiteral("on") : QStringLiteral("off");
    if (helperReady())
        begin(QStringLiteral("radio"), QStringLiteral("sudo"),
              {QStringLiteral("-n"), helperPath(), QStringLiteral("wifi-radio"), flag}, {}, 8000);
    else
        begin(QStringLiteral("radio"), QStringLiteral("nmcli"), {QStringLiteral("radio"), QStringLiteral("wifi"), flag}, {}, 8000);
}

void SystemController::setVolume(int percent)
{
    if (m_wpctl.isEmpty() || m_busy)
        return;
    m_volumeGoal = qBound(0, percent, 100);
    begin(QStringLiteral("volume-set"), m_wpctl,
          {QStringLiteral("set-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), QStringLiteral("%1%").arg(m_volumeGoal)}, {}, 4000);
}

void SystemController::setMuted(bool on)
{
    QSettings().setValue(QStringLiteral("audio/muted"), on);
    if (m_wpctl.isEmpty() || m_busy)
        return;
    m_muteGoal = on;
    begin(QStringLiteral("mute"), m_wpctl,
          {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), on ? QStringLiteral("1") : QStringLiteral("0")}, {}, 4000);
}

void SystemController::restartApp()
{
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
}

void SystemController::reboot()
{
    if (!m_canReboot || m_busy)
        return;
    setMessage(QStringLiteral("Rebooting the Pi…"));
    begin(QStringLiteral("reboot"), QStringLiteral("sudo"), {QStringLiteral("-n"), helperPath(), QStringLiteral("reboot")}, {}, 8000);
}

void SystemController::begin(const QString &action, const QString &program, const QStringList &args, const QByteArray &input, int timeoutMs)
{
    if (m_proc.state() != QProcess::NotRunning)
        return;
    m_action = action;
    m_busy = true;
    emit busyChanged();
    m_proc.start(program, args);
    if (!input.isNull()) {
        m_proc.write(input);
        m_proc.closeWriteChannel();
    }
    m_timeout.start(timeoutMs);
}

void SystemController::onStartFailed()
{
    if (m_action.isEmpty())
        return;
    m_timeout.stop();
    const QString action = m_action;
    m_action.clear();
    m_busy = false;
    finish(action, false, {}, QStringLiteral("couldn't start %1").arg(m_proc.program()));
}

void SystemController::onFinished(int code, QProcess::ExitStatus status)
{
    if (m_action.isEmpty())
        return;
    m_timeout.stop();
    const QString out = QString::fromUtf8(m_proc.readAllStandardOutput());
    const QString err = QString::fromUtf8(m_proc.readAllStandardError());
    const QString action = m_action;
    m_action.clear();
    m_busy = false;
    const bool ok = status == QProcess::NormalExit && code == 0;
    finish(action, ok, out, err);
}

void SystemController::finish(const QString &action, bool ok, const QString &out, const QString &err)
{
    if (action == QLatin1String("connect")) {
        delete m_secret;
        m_secret = nullptr;
    }
    m_lastAction = action;
    if (!ok && action != QLatin1String("volume") && action != QLatin1String("status"))
        qWarning().noquote() << "homeos system" << action << "failed:" << err.trimmed();

    if (action == QLatin1String("status")) {
        bool enabled = false;
        QString ssid;
        if (ok && parseWifiStatus(out, &enabled, &ssid)) {
            m_wifiEnabled = enabled;
            m_wifiSsid = ssid;
            emit wifiChanged();
        }
        if (!m_wpctl.isEmpty()) {
            begin(QStringLiteral("volume"), m_wpctl, {QStringLiteral("get-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@")}, {}, 4000);
            return;
        }
    } else if (action == QLatin1String("volume")) {
        const int percent = ok ? parseVolumePercent(out) : -1;
        const bool muted = ok && parseMuted(out);
        m_volumeAvailable = percent >= 0;
        if (percent >= 0)
            m_volume = percent;
        m_muted = muted;
        emit volumeChanged();
        if (m_volumeAvailable && !m_audioApplied) {
            m_audioApplied = true;
            QSettings settings;
            const bool wantMuted = settings.value(QStringLiteral("audio/muted"), false).toBool();
            // The installer used to leave HDMI at full volume, which makes the
            // panel's speakers hiss. Ease that off once.
            if (!settings.value(QStringLiteral("audio/tamed")).toBool()) {
                settings.setValue(QStringLiteral("audio/tamed"), true);
                if (percent >= 90) {
                    m_volumeGoal = 50;
                    m_muteAfter = wantMuted;
                    begin(QStringLiteral("volume-set"), m_wpctl,
                          {QStringLiteral("set-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), QStringLiteral("50%")}, {}, 4000);
                    return;
                }
            }
            if (wantMuted != muted) {
                m_muteGoal = wantMuted;
                begin(QStringLiteral("mute"), m_wpctl,
                      {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), wantMuted ? QStringLiteral("1") : QStringLiteral("0")}, {},
                      4000);
                return;
            }
        }
    } else if (action == QLatin1String("volume-set")) {
        if (ok) {
            m_volume = m_volumeGoal;
            m_volumeAvailable = true;
            emit volumeChanged();
            if (m_muteAfter) {
                m_muteAfter = false;
                m_muteGoal = true;
                begin(QStringLiteral("mute"), m_wpctl,
                      {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), QStringLiteral("1")}, {}, 4000);
                return;
            }
        } else {
            setMessage(QStringLiteral("Couldn't change the volume."));
        }
    } else if (action == QLatin1String("mute")) {
        if (ok) {
            m_muted = m_muteGoal;
            emit volumeChanged();
        } else {
            setMessage(QStringLiteral("Couldn't change the speakers."));
        }
    } else if (action == QLatin1String("scan")) {
        if (ok) {
            m_networks.clear();
            int signal = -1;
            QString inUse;
            for (const WifiNetwork &network : parseWifiScan(out)) {
                m_networks.append(toMap(network));
                if (network.inUse) {
                    inUse = network.ssid;
                    signal = network.signal;
                }
            }
            emit networksChanged();
            if (!inUse.isEmpty()) {
                m_wifiSsid = inUse;
                m_wifiSignal = signal;
                m_wifiEnabled = true;
                emit wifiChanged();
            }
        } else {
            setMessage(friendlyWifiError(err));
        }
    } else if (action == QLatin1String("connect")) {
        if (ok) {
            setMessage(QStringLiteral("Connected."));
            m_busy = false;
            rescanWifi();
            if (!m_busy)
                emit busyChanged();
            emit actionFinished(true);
            return;
        }
        setMessage(friendlyWifiError(err));
    } else if (action == QLatin1String("radio")) {
        if (ok) {
            m_wifiEnabled = m_radioGoal;
            if (!m_wifiEnabled) {
                m_wifiSsid.clear();
                m_wifiSignal = -1;
                m_networks.clear();
                emit networksChanged();
            }
            emit wifiChanged();
            setMessage(m_wifiEnabled ? QStringLiteral("Wi-Fi is on.") : QStringLiteral("Wi-Fi is off."));
            if (m_wifiEnabled) {
                m_busy = false;
                rescanWifi();
                if (!m_busy)
                    emit busyChanged();
                emit actionFinished(true);
                return;
            }
        } else {
            setMessage(friendlyWifiError(err));
        }
    } else if (action == QLatin1String("reboot")) {
        if (!ok)
            setMessage(friendlyWifiError(err.isEmpty() ? QStringLiteral("reboot failed") : err));
    }

    emit busyChanged();
    if (!action.isEmpty() && action != QLatin1String("volume-mute"))
        emit actionFinished(ok);
}

QStringList SystemController::splitNmcli(const QString &line)
{
    QStringList parts;
    QString current;
    for (int i = 0; i < line.size(); ++i) {
        const QChar ch = line.at(i);
        if (ch == QLatin1Char('\\') && i + 1 < line.size()) {
            current += line.at(++i);
        } else if (ch == QLatin1Char(':')) {
            parts.append(current);
            current.clear();
        } else {
            current += ch;
        }
    }
    parts.append(current);
    return parts;
}

QVector<WifiNetwork> SystemController::parseWifiScan(const QString &text)
{
    const QStringList lines = text.split(QLatin1Char('\n'));
    int divider = lines.size();
    for (int i = 0; i < lines.size(); ++i) {
        if (lines.at(i).trimmed() == QLatin1String("---")) {
            divider = i;
            break;
        }
    }

    QStringList saved;
    for (int i = divider + 1; i < lines.size(); ++i) {
        const QString line = lines.at(i).trimmed();
        if (line.isEmpty())
            continue;
        const QStringList parts = splitNmcli(line);
        if (parts.size() < 2)
            continue;
        if (parts.last() != QLatin1String("802-11-wireless"))
            continue;
        saved.append(parts.mid(0, parts.size() - 1).join(QLatin1Char(':')));
    }

    QVector<WifiNetwork> networks;
    for (int i = 0; i < divider; ++i) {
        const QString line = lines.at(i).trimmed();
        if (line.isEmpty() || line == QLatin1String("---"))
            continue;
        const QStringList parts = splitNmcli(line);
        if (parts.size() < 3)
            continue;
        WifiNetwork network;
        network.inUse = parts.at(0).trimmed() == QLatin1String("*");
        network.ssid = parts.at(1).trimmed();
        if (network.ssid.isEmpty())
            continue;
        network.signal = qBound(0, parts.at(2).trimmed().toInt(), 100);
        const QString security = parts.mid(3).join(QLatin1Char(':'));
        network.secure = !isOpenSecurity(security);
        network.saved = saved.contains(network.ssid);
        int existing = -1;
        for (int n = 0; n < networks.size(); ++n) {
            if (networks.at(n).ssid == network.ssid) {
                existing = n;
                break;
            }
        }
        if (existing < 0) {
            networks.append(network);
        } else if (network.inUse || (!networks.at(existing).inUse && network.signal > networks.at(existing).signal)) {
            networks[existing] = network;
        }
    }
    return networks;
}

bool SystemController::parseWifiStatus(const QString &text, bool *enabled, QString *ssid)
{
    const QStringList lines = text.split(QLatin1Char('\n'));
    if (lines.isEmpty() || lines.first().trimmed().isEmpty())
        return false;
    const QString radio = lines.first().trimmed().toLower();
    if (radio != QLatin1String("enabled") && radio != QLatin1String("disabled"))
        return false;
    *enabled = radio == QLatin1String("enabled");
    ssid->clear();
    bool after = false;
    for (const QString &raw : lines) {
        const QString line = raw.trimmed();
        if (line == QLatin1String("---")) {
            after = true;
            continue;
        }
        if (!after)
            continue;
        const QStringList parts = splitNmcli(line);
        if (parts.size() < 4)
            continue;
        if (parts.at(1) == QLatin1String("wifi") && parts.at(2) == QLatin1String("connected")) {
            *ssid = parts.mid(3).join(QLatin1Char(':'));
            break;
        }
    }
    return true;
}

bool SystemController::parseMuted(const QString &text)
{
    return text.contains(QLatin1String("[MUTED]"));
}

int SystemController::parseVolumePercent(const QString &text)
{
    const int mark = text.indexOf(QLatin1String("Volume:"));
    if (mark < 0)
        return -1;
    const QString rest = text.mid(mark + 7).trimmed();
    bool ok = false;
    const double level = rest.section(QLatin1Char(' '), 0, 0).toDouble(&ok);
    if (!ok)
        return -1;
    return qBound(0, qRound(level * 100.0), 100);
}

bool SystemController::validSsid(const QString &ssid)
{
    if (ssid.isEmpty() || ssid.startsWith(QLatin1Char('-')))
        return false;
    const QByteArray bytes = ssid.toUtf8();
    if (bytes.size() > 32)
        return false;
    for (unsigned char c : bytes) {
        if (c < 0x20 || c == 0x7f)
            return false;
    }
    return true;
}

bool SystemController::validPassword(const QString &password)
{
    if (password.isEmpty())
        return true;
    const QByteArray bytes = password.toUtf8();
    if (bytes.size() > 64)
        return false;
    for (unsigned char c : bytes) {
        if (c < 0x20 || c == 0x7f)
            return false;
    }
    return true;
}

QString SystemController::friendlyWifiError(const QString &stderrText)
{
    const QString text = stderrText.toLower();
    if (text.contains(QLatin1String("password is required")) || text.contains(QLatin1String("a password is required"))
        || text.contains(QLatin1String("not authorized")) || text.contains(QLatin1String("sudo:")))
        return QStringLiteral("This display isn't allowed to change Wi-Fi yet. Run the display install again.");
    if (text.contains(QLatin1String("password")) || text.contains(QLatin1String("secret"))
        || text.contains(QLatin1String("802-11-wireless-security")))
        return QStringLiteral("That password didn't work.");
    if (text.contains(QLatin1String("no network with ssid")) || text.contains(QLatin1String("not found")))
        return QStringLiteral("That network isn't in range.");
    if (text.contains(QLatin1String("nmcli")) && text.contains(QLatin1String("not found")))
        return QStringLiteral("Wi-Fi isn't available on this computer.");
    if (text.contains(QLatin1String("that password isn't usable")) || text.contains(QLatin1String("that network name isn't usable")))
        return QStringLiteral("That network name or password isn't usable.");
    return QStringLiteral("Couldn't change Wi-Fi.");
}
