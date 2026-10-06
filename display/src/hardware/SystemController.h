#pragma once

#include <QObject>
#include <QProcess>
#include <QTemporaryFile>
#include <QTimer>
#include <QVariantList>
#include <QVector>

// One nearby network, parsed from `nmcli -t` output.
struct WifiNetwork
{
    QString ssid;
    int signal = 0;
    bool secure = false;
    bool inUse = false;
    bool saved = false;
};

// The wall panel's own machine: Wi-Fi, speaker volume, restart and reboot.
//
// Changing Wi-Fi or rebooting goes through /usr/local/libexec/homeos-system
// (root, via a narrow sudoers rule) because a kiosk has no password prompt.
// Volume talks to the signed-in user's PipeWire directly. Reads still work
// when the helper isn't installed, so a development machine can show status.
class SystemController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool wifiAvailable READ wifiAvailable NOTIFY availabilityChanged)
    Q_PROPERTY(bool canManageWifi READ canManageWifi NOTIFY availabilityChanged)
    Q_PROPERTY(bool canReboot READ canReboot NOTIFY availabilityChanged)
    Q_PROPERTY(bool wifiEnabled READ wifiEnabled NOTIFY wifiChanged)
    Q_PROPERTY(QString wifiSsid READ wifiSsid NOTIFY wifiChanged)
    Q_PROPERTY(int wifiSignal READ wifiSignal NOTIFY wifiChanged)
    Q_PROPERTY(QString ipAddress READ ipAddress NOTIFY ipChanged)
    Q_PROPERTY(bool volumeAvailable READ volumeAvailable NOTIFY volumeChanged)
    Q_PROPERTY(int volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)
    Q_PROPERTY(QString lastAction READ lastAction NOTIFY actionFinished)
    Q_PROPERTY(QVariantList networks READ networks NOTIFY networksChanged)

public:
    explicit SystemController(QObject *parent = nullptr);

    // Looks up nmcli, wpctl and the helper, then refreshes status.
    void start();

    bool wifiAvailable() const { return m_wifiAvailable; }
    bool canManageWifi() const { return m_canManageWifi; }
    bool canReboot() const { return m_canReboot; }
    bool wifiEnabled() const { return m_wifiEnabled; }
    QString wifiSsid() const { return m_wifiSsid; }
    int wifiSignal() const { return m_wifiSignal; }
    QString ipAddress() const { return m_ipAddress; }
    bool volumeAvailable() const { return m_volumeAvailable; }
    int volume() const { return m_volume; }
    bool busy() const { return m_busy; }
    QString message() const { return m_message; }
    QString lastAction() const { return m_lastAction; }
    QVariantList networks() const { return m_networks; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void scanWifi();
    Q_INVOKABLE void connectWifi(const QString &ssid, const QString &password, bool saved);
    Q_INVOKABLE void setWifiEnabled(bool on);
    Q_INVOKABLE void setVolume(int percent);
    Q_INVOKABLE void restartApp();
    Q_INVOKABLE void reboot();

    static QStringList splitNmcli(const QString &line);
    static QVector<WifiNetwork> parseWifiScan(const QString &text);
    static bool parseWifiStatus(const QString &text, bool *enabled, QString *ssid);
    static int parseVolumePercent(const QString &text);
    static bool validSsid(const QString &ssid);
    static bool validPassword(const QString &password);
    static QString friendlyWifiError(const QString &stderrText);

signals:
    void availabilityChanged();
    void wifiChanged();
    void ipChanged();
    void volumeChanged();
    void busyChanged();
    void messageChanged();
    void networksChanged();
    void actionFinished(bool ok);

private:
    void rescanWifi();
    void begin(const QString &action, const QString &program, const QStringList &args, const QByteArray &input, int timeoutMs);
    void onFinished(int code, QProcess::ExitStatus status);
    void onStartFailed();
    void finish(const QString &action, bool ok, const QString &out, const QString &err);
    void setMessage(const QString &text);
    void updateIp();
    bool helperReady() const;
    QString helperPath() const;

    QProcess m_proc;
    QTimer m_timeout;
    QString m_action;
    QString m_lastAction;
    QString m_message;
    QString m_ipAddress;
    QString m_wifiSsid;
    QVariantList m_networks;
    int m_wifiSignal = -1;
    int m_volume = -1;
    int m_volumeGoal = -1;
    bool m_radioGoal = false;
    QTemporaryFile *m_secret = nullptr;
    bool m_wifiAvailable = false;
    bool m_canManageWifi = false;
    bool m_canReboot = false;
    bool m_wifiEnabled = false;
    bool m_volumeAvailable = false;
    bool m_busy = false;
    bool m_haveHelper = false;
    bool m_haveNmcli = false;
    QString m_wpctl;
};
