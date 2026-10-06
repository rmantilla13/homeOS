#include <QtTest>

#include <QSettings>
#include <QSignalSpy>

#include "backend/SupabaseClient.h"
#include "models/FamilyStore.h"

// Demo-mode create flows used by the wall + buttons.
class tst_FamilyStore : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("homeOS-tests"));
        QCoreApplication::setApplicationName(QStringLiteral("tst_familystore"));
        QSettings().clear();
    }

    void cleanupTestCase() { QSettings().clear(); }

    void demoCreatesEventTaskAndReward()
    {
        SupabaseClient client{QUrl(), QString()};
        FamilyStore store(&client, true);
        store.start();
        QVERIFY(store.mode() == QLatin1String("demo"));
        QVERIFY(!store.members().isEmpty());

        const int eventsBefore = store.events().size();
        const int tasksBefore = store.tasks().size();
        const int rewardsBefore = store.rewards().size();
        const QString assignee = store.members().first().toMap().value(QStringLiteral("id")).toString();
        QVERIFY(!assignee.isEmpty());

        QSignalSpy notify(&store, &FamilyStore::notify);
        QSignalSpy changed(&store, &FamilyStore::dataChanged);

        store.addEvent(QStringLiteral("Wall test event"), QStringLiteral("Kitchen"),
                       QStringLiteral("2026-10-06T15:00:00"), QStringLiteral("2026-10-06T16:00:00"),
                       false, QVariantList{assignee});
        QVERIFY(changed.wait(1000) || changed.size() > 0);
        QCOMPARE(store.events().size(), eventsBefore + 1);
        bool foundEvent = false;
        for (const QVariant &v : store.events()) {
            if (v.toMap().value(QStringLiteral("title")).toString() == QLatin1String("Wall test event")) {
                foundEvent = true;
                break;
            }
        }
        QVERIFY(foundEvent);

        store.addTask(QStringLiteral("Wall test chore"), QStringLiteral("🧹"), assignee, 10, true,
                      QStringLiteral("FREQ=DAILY"));
        QCOMPARE(store.tasks().size(), tasksBefore + 1);
        bool foundTask = false;
        for (const QVariant &v : store.tasks()) {
            if (v.toMap().value(QStringLiteral("title")).toString() == QLatin1String("Wall test chore")) {
                foundTask = true;
                QCOMPARE(v.toMap().value(QStringLiteral("requires_approval")).toBool(), true);
                break;
            }
        }
        QVERIFY(foundTask);

        store.addReward(QStringLiteral("Wall test reward"), QStringLiteral("🎁"), 45);
        QCOMPARE(store.rewards().size(), rewardsBefore + 1);
        bool foundReward = false;
        for (const QVariant &v : store.rewards()) {
            if (v.toMap().value(QStringLiteral("title")).toString() == QLatin1String("Wall test reward")) {
                foundReward = true;
                QCOMPARE(v.toMap().value(QStringLiteral("cost")).toInt(), 45);
                break;
            }
        }
        QVERIFY(foundReward);
        QVERIFY(notify.size() >= 3);
    }

    void deviceForcesApprovalWhenPointsPositive()
    {
        SupabaseClient client{QUrl(), QString()};
        FamilyStore store(&client, true);
        store.start();
        const QString assignee = store.members().first().toMap().value(QStringLiteral("id")).toString();
        store.addTask(QStringLiteral("Needs OK"), QStringLiteral("✔️"), assignee, 15, false,
                      QStringLiteral("FREQ=DAILY"));
        for (const QVariant &v : store.tasks()) {
            if (v.toMap().value(QStringLiteral("title")).toString() == QLatin1String("Needs OK")) {
                QCOMPARE(v.toMap().value(QStringLiteral("requires_approval")).toBool(), true);
                return;
            }
        }
        QFAIL("chore not found");
    }
};

QTEST_GUILESS_MAIN(tst_FamilyStore)
#include "tst_familystore.moc"
