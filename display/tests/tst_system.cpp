#include "hardware/SystemController.h"

#include <QtTest>

class tst_System : public QObject
{
    Q_OBJECT

private slots:
    void split_escapesColons()
    {
        QCOMPARE(SystemController::splitNmcli("*:Cafe\\:Bar:40:WPA2"),
                 QStringList({QStringLiteral("*"), QStringLiteral("Cafe:Bar"), QStringLiteral("40"), QStringLiteral("WPA2")}));
    }

    void scan_parsesNetworks()
    {
        const QString text = QStringLiteral(
            "*:Home:80:WPA2\n"
            ":Cafe\\:Bar:40:\n"
            ":Home:20:WPA2\n"
            "::10:WPA2\n"
            "---\n"
            "Home:802-11-wireless\n"
            "Cafe\\:Bar:802-11-wireless\n"
            "Wired:802-3-ethernet\n");
        const QVector<WifiNetwork> networks = SystemController::parseWifiScan(text);
        QCOMPARE(networks.size(), 2);

        QCOMPARE(networks.at(0).ssid, QStringLiteral("Home"));
        QVERIFY(networks.at(0).inUse);
        QVERIFY(networks.at(0).secure);
        QVERIFY(networks.at(0).saved);
        QCOMPARE(networks.at(0).signal, 80);

        QCOMPARE(networks.at(1).ssid, QStringLiteral("Cafe:Bar"));
        QVERIFY(!networks.at(1).secure);
        QVERIFY(networks.at(1).saved);
        QCOMPARE(networks.at(1).signal, 40);
    }

    void scan_skipsBlankSsid()
    {
        const QVector<WifiNetwork> networks = SystemController::parseWifiScan(QStringLiteral(": :15:WPA2\n::15:WPA2\n"));
        QCOMPARE(networks.size(), 0);
    }

    void status_readsRadioAndSsid()
    {
        bool enabled = false;
        QString ssid;
        QVERIFY(SystemController::parseWifiStatus(
            QStringLiteral("enabled\n---\nwlan0:wifi:connected:Cafe\\:Bar\neth0:ethernet:connected:Wired\n"), &enabled, &ssid));
        QVERIFY(enabled);
        QCOMPARE(ssid, QStringLiteral("Cafe:Bar"));

        QVERIFY(SystemController::parseWifiStatus(QStringLiteral("disabled\n---\nwlan0:wifi:disconnected:\n"), &enabled, &ssid));
        QVERIFY(!enabled);
        QVERIFY(ssid.isEmpty());
        QVERIFY(!SystemController::parseWifiStatus(QStringLiteral("nope\n"), &enabled, &ssid));
    }

    void volume_parsesWpctl()
    {
        QCOMPARE(SystemController::parseVolumePercent(QStringLiteral("Volume: 0.42")), 42);
        QCOMPARE(SystemController::parseVolumePercent(QStringLiteral("Volume: 1.00 [MUTED]")), 100);
        QVERIFY(SystemController::parseMuted(QStringLiteral("Volume: 1.00 [MUTED]")));
        QVERIFY(!SystemController::parseMuted(QStringLiteral("Volume: 0.42")));
        QCOMPARE(SystemController::parseVolumePercent(QStringLiteral("Volume: 0.00")), 0);
        QCOMPARE(SystemController::parseVolumePercent(QStringLiteral("no sink")), -1);
    }

    void namesAndPasswords_rejectControlCharacters()
    {
        QVERIFY(SystemController::validSsid(QStringLiteral("Home Wi-Fi")));
        QVERIFY(!SystemController::validSsid(QString()));
        QVERIFY(!SystemController::validSsid(QStringLiteral("-hidden")));
        QVERIFY(!SystemController::validSsid(QStringLiteral("bad\nname")));
        QVERIFY(!SystemController::validSsid(QString(33, QLatin1Char('a'))));
        QVERIFY(SystemController::validPassword(QString()));
        QVERIFY(SystemController::validPassword(QStringLiteral("correct horse")));
        QVERIFY(!SystemController::validPassword(QStringLiteral("line\nbreak")));
        QVERIFY(!SystemController::validPassword(QString(65, QLatin1Char('x'))));
    }

    void errors_arePlainLanguage()
    {
        QCOMPARE(SystemController::friendlyWifiError(QStringLiteral("Error: Secrets were required")), QStringLiteral("That password didn't work."));
        QCOMPARE(SystemController::friendlyWifiError(QStringLiteral("sudo: a password is required")),
                 QStringLiteral("This display isn't allowed to change Wi-Fi yet. Run the display install again."));
        QCOMPARE(SystemController::friendlyWifiError(QStringLiteral("Error: No network with SSID x found")),
                 QStringLiteral("That network isn't in range."));
        QCOMPARE(SystemController::friendlyWifiError(QStringLiteral("something else")), QStringLiteral("Couldn't change Wi-Fi."));
    }
};

QTEST_GUILESS_MAIN(tst_System)
#include "tst_system.moc"
