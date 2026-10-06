#include "hardware/DisplayController.h"

#include <QSettings>
#include <QtTest>

// Display preferences remembered in QSettings. The settings sheet binds the
// Dark mode toggle to DisplayController::darkMode.
class tst_Display : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("homeOS-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_display"));
        QSettings().clear();
    }

    void cleanupTestCase() { QSettings().clear(); }

    void darkModeDefaultsOffAndIsRemembered()
    {
        {
            DisplayController device;
            QVERIFY(!device.darkMode());
            device.setDarkMode(true);
            QVERIFY(device.darkMode());
            QCOMPARE(QSettings().value(QStringLiteral("display/darkMode")).toBool(), true);
        }
        {
            DisplayController again;
            QVERIFY(again.darkMode());
            again.setDarkMode(false);
        }
        DisplayController third;
        QVERIFY(!third.darkMode());
    }
};

QTEST_GUILESS_MAIN(tst_Display)
#include "tst_display.moc"
