#include <QtTest>

#include <functional>

#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

// Stands in for FamilyStore: today, and no members or events.
class FakeStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString today READ today NOTIFY todayChanged)
    Q_PROPERTY(QVariantList members READ none CONSTANT)
    Q_PROPERTY(QVariantList events READ none CONSTANT)
public:
    QString today() const { return QDate::currentDate().toString(Qt::ISODate); }
    QVariantList none() const { return {}; }

signals:
    void todayChanged();
};

// Stands in for DisplayController: idle, and what the theme reads.
class FakeDevice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    Q_PROPERTY(QString mood READ mood CONSTANT)
    Q_PROPERTY(bool darkMode READ darkMode CONSTANT)
public:
    bool idle() const { return false; }
    QString mood() const { return QStringLiteral("day"); }
    bool darkMode() const { return false; }

signals:
    void idleChanged();
};

static const char *kScene = R"(
import QtQuick
import HomeOS

Window {
    width: 1280
    height: 800
    property alias cal: cal
    CalendarScreen { id: cal; anchors.fill: parent }
}
)";

// The calendar's New event dialog: which day and time it starts on, and its
// time and day steppers.
class TestCalendar : public QObject
{
    Q_OBJECT

    FakeStore m_store;
    FakeDevice m_device;
    QQmlEngine *m_engine = nullptr;
    QScopedPointer<QQuickWindow> m_window;
    QObject *m_cal = nullptr;

    QDateTime eventStart() const { return m_cal->property("eventStart").toDateTime(); }
    QDateTime eventEnd() const { return m_cal->property("eventEnd").toDateTime(); }
    // Invalid if the call fails.
    QDateTime newEventStart(const QDate &day, const QDateTime &now) const
    {
        QVariant start;
        QMetaObject::invokeMethod(m_cal, "newEventStart", Q_RETURN_ARG(QVariant, start),
                                  Q_ARG(QVariant, QDateTime(day, QTime(0, 0))), Q_ARG(QVariant, now));
        return start.toDateTime();
    }
    void step(int dir) { QVERIFY(QMetaObject::invokeMethod(m_cal, "step", Q_ARG(QVariant, dir))); }
    QObject *dialog() const
    {
        for (QObject *o : m_cal->findChildren<QObject *>())
            if (o->inherits("QQuickDialog"))
                return o;
        return nullptr;
    }
    // The dialog's visible › buttons, top to bottom.
    QList<QObject *> forwardButtons() const
    {
        QList<QObject *> found;
        std::function<void(QQuickItem *)> walk = [&](QQuickItem *item) {
            if (item->isVisible() && item->property("icon").toString() == QLatin1String("right"))
                found << item;
            for (QQuickItem *child : item->childItems())
                walk(child);
        };
        walk(dialog()->property("contentItem").value<QQuickItem *>());
        return found;
    }

private slots:
    void initTestCase()
    {
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Store", &m_store);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_TEST_QML_DIR));
    }

    void init()
    {
        QQmlComponent component(m_engine);
        component.setData(kScene, QUrl());
        m_window.reset(qobject_cast<QQuickWindow *>(component.create()));
        QVERIFY2(m_window, qPrintable(component.errorString()));
        m_window->show();
        QVERIFY(QTest::qWaitForWindowExposed(m_window.data()));
        m_cal = m_window->property("cal").value<QObject *>();
        QVERIFY(m_cal);
    }

    void cleanup() { m_window.reset(); }

    // 9:00 on another day. Today, the next whole hour, from 9 AM to 11 PM.
    void startTime_data()
    {
        const QDate day(2026, 10, 7);
        QTest::addColumn<QDate>("day");
        QTest::addColumn<QDateTime>("now");
        QTest::addColumn<QTime>("start");
        QTest::newRow("early morning") << day << QDateTime(day, QTime(7, 15)) << QTime(9, 0);
        QTest::newRow("on the hour before 9") << day << QDateTime(day, QTime(8, 0)) << QTime(9, 0);
        QTest::newRow("on the hour") << day << QDateTime(day, QTime(14, 0)) << QTime(14, 0);
        QTest::newRow("past the hour") << day << QDateTime(day, QTime(14, 20)) << QTime(15, 0);
        QTest::newRow("seconds past") << day << QDateTime(day, QTime(14, 0, 30)) << QTime(15, 0);
        QTest::newRow("late evening") << day << QDateTime(day, QTime(22, 59)) << QTime(23, 0);
        QTest::newRow("before midnight") << day << QDateTime(day, QTime(23, 30)) << QTime(23, 0);
        QTest::newRow("tomorrow") << day.addDays(1) << QDateTime(day, QTime(14, 20)) << QTime(9, 0);
        QTest::newRow("yesterday") << day.addDays(-1) << QDateTime(day, QTime(14, 20)) << QTime(9, 0);
    }
    void startTime()
    {
        QFETCH(QDate, day);
        QFETCH(QDateTime, now);
        QFETCH(QTime, start);
        QCOMPARE(newEventStart(day, now), QDateTime(day, start));
    }

    // + starts the event on the day in focus, in every view: today (not the
    // Monday of the week), or the day, week or month someone stepped to.
    void startsOnTheDayInFocus_data()
    {
        const QDate today = QDate::currentDate();
        QTest::addColumn<int>("view");
        QTest::addColumn<int>("steps");
        QTest::addColumn<QDate>("day");
        QTest::newRow("week") << 1 << 0 << today;
        QTest::newRow("next week") << 1 << 1 << today.addDays(7);
        QTest::newRow("last week") << 1 << -1 << today.addDays(-7);
        QTest::newRow("day") << 0 << 0 << today;
        QTest::newRow("tomorrow") << 0 << 1 << today.addDays(1);
        QTest::newRow("month") << 2 << 0 << today;
        QTest::newRow("next month") << 2 << 1 << QDate(today.year(), today.month(), 1).addMonths(1);
    }
    void startsOnTheDayInFocus()
    {
        QFETCH(int, view);
        QFETCH(int, steps);
        QFETCH(QDate, day);
        m_cal->setProperty("view", view);
        for (int i = 0; i < qAbs(steps); ++i)
            step(steps > 0 ? 1 : -1);

        const QDateTime before = QDateTime::currentDateTime();
        QVERIFY(QMetaObject::invokeMethod(m_cal, "openAdd"));
        const QDateTime after = QDateTime::currentDateTime();
        QTRY_VERIFY(dialog()->property("opened").toBool());

        QCOMPARE(eventStart().date(), day);
        QVERIFY(eventStart() == newEventStart(day, before) || eventStart() == newEventStart(day, after));
        if (day != QDate::currentDate())
            QCOMPARE(eventStart().time(), QTime(9, 0));
        QCOMPARE(eventEnd(), eventStart().addSecs(60 * 60));
    }

    // Starts › and Ends › move the times half an hour; all day, Day › moves the day.
    void steppers()
    {
        step(1);
        QVERIFY(QMetaObject::invokeMethod(m_cal, "openAdd"));
        QTRY_VERIFY(dialog()->property("opened").toBool());
        const QDateTime start = eventStart();
        QCOMPARE(start, QDateTime(QDate::currentDate().addDays(7), QTime(9, 0)));

        QList<QObject *> buttons = forwardButtons();
        QCOMPARE(buttons.size(), 2);
        QVERIFY(QMetaObject::invokeMethod(buttons[0], "clicked"));
        QCOMPARE(eventStart(), start.addSecs(30 * 60));
        QCOMPARE(eventEnd(), start.addSecs(90 * 60));
        QVERIFY(QMetaObject::invokeMethod(buttons[1], "clicked"));
        QCOMPARE(eventStart(), start.addSecs(30 * 60));
        QCOMPARE(eventEnd(), start.addSecs(120 * 60));

        m_cal->setProperty("eventAllDay", true);
        buttons = forwardButtons();
        QCOMPARE(buttons.size(), 1);
        QVERIFY(QMetaObject::invokeMethod(buttons[0], "clicked"));
        QCOMPARE(eventStart().date(), start.date().addDays(1));
    }
};

QTEST_MAIN(TestCalendar)
#include "tst_calendar.moc"
