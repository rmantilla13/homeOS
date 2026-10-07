#include <QtTest>

#include <algorithm>

#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

// Stands in for DisplayController: idle, and what the theme reads.
class FakeDevice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    Q_PROPERTY(QString mood READ mood CONSTANT)
    Q_PROPERTY(bool darkMode READ darkMode CONSTANT)
public:
    bool idle() const { return m_idle; }
    void setIdle(bool idle)
    {
        if (idle == m_idle)
            return;
        m_idle = idle;
        emit idleChanged();
    }
    QString mood() const { return QStringLiteral("day"); }
    bool darkMode() const { return false; }

signals:
    void idleChanged();

private:
    bool m_idle = false;
};

// The wall dialogs' shell (FormDialog.qml) with a Layer where Main.qml puts
// the on-screen keyboard: over the dialogs, along the bottom of the window.
static const char *kScene = R"(
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HomeOS

Window {
    id: window
    width: 1280
    height: 800
    property alias dialog: dialog
    property alias field: field
    property alias layer: layer
    property int keyTaps: 0
    // More body than fits in the window.
    property real extraBody: 0

    // Declared in a screen, as the app's are.
    Item {
        anchors.fill: parent
        FormDialog {
            id: dialog
            titleText: "New event"
            FormField { id: field }
            Item { visible: window.extraBody > 0; Layout.preferredHeight: window.extraBody }
        }
    }
    Layer {
        id: layer
        z: 2
        y: 500
        width: 1280
        height: 300
        // Takes mouse and touch, like the keyboard's keys.
        MultiPointTouchArea { anchors.fill: parent; onPressed: keyTaps++ }
    }
}
)";

class TestDialogs : public QObject
{
    Q_OBJECT

    FakeDevice m_device;
    QPointingDevice *m_touchscreen = nullptr;
    QQmlEngine *m_engine = nullptr;
    QScopedPointer<QQuickWindow> m_window;

    QObject *child(const char *name) const { return m_window->property(name).value<QObject *>(); }
    bool isOpen(const char *name) const { return child(name)->property("opened").toBool(); }
    // The dialog's scrolling body (FocusFlickable).
    QQuickItem *body() const
    {
        const auto items = child("dialog")->property("contentItem").value<QQuickItem *>()->findChildren<QQuickItem *>();
        for (QQuickItem *item : items)
            if (item->inherits("QQuickFlickable"))
                return item;
        return nullptr;
    }
    // Its edge fades, top then bottom: over the body, not scrolled with it.
    QList<QQuickItem *> fades() const
    {
        QList<QQuickItem *> out = body()->childItems();
        out.removeOne(body()->property("contentItem").value<QQuickItem *>());
        std::sort(out.begin(), out.end(), [](QQuickItem *a, QQuickItem *b) { return a->y() < b->y(); });
        return out;
    }
    void open(const char *name)
    {
        QVERIFY(QMetaObject::invokeMethod(child(name), "open"));
        QTRY_VERIFY(isOpen(name));
    }

private slots:
    void initTestCase()
    {
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_touchscreen = QTest::createTouchDevice();
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_TEST_QML_DIR));
    }

    void init()
    {
        m_device.setIdle(false);
        QQmlComponent component(m_engine);
        component.setData(kScene, QUrl());
        m_window.reset(qobject_cast<QQuickWindow *>(component.create()));
        QVERIFY2(m_window, qPrintable(component.errorString()));
        m_window->show();
        QVERIFY(QTest::qWaitForWindowExposed(m_window.data()));
    }

    void cleanup() { m_window.reset(); }

    // Typing on the keyboard while a modal dialog is open: a click or a touch
    // reaches the Layer even though it's outside the dialog, the dialog stays
    // open and the field keeps focus. The Layer is opened first, as the app
    // does at start-up.
    void layerOverModalDialogTakesItsPresses()
    {
        open("layer");
        open("dialog");
        auto *field = qobject_cast<QQuickItem *>(child("field"));
        field->forceActiveFocus();
        QTRY_VERIFY(field->hasActiveFocus());

        QTest::mouseClick(m_window.data(), Qt::LeftButton, {}, QPoint(640, 760));
        QTRY_COMPARE(m_window->property("keyTaps").toInt(), 1);
        QTest::touchEvent(m_window.data(), m_touchscreen).press(0, QPoint(100, 700));
        QTest::touchEvent(m_window.data(), m_touchscreen).release(0, QPoint(100, 700));
        QTRY_COMPARE(m_window->property("keyTaps").toInt(), 2);
        QVERIFY(isOpen("dialog"));
        QVERIFY(field->hasActiveFocus());

        // A press outside both still closes the dialog, as before.
        QTest::mouseClick(m_window.data(), Qt::LeftButton, {}, QPoint(20, 20));
        QTRY_VERIFY(!child("dialog")->property("visible").toBool());
        QCOMPARE(m_window->property("keyTaps").toInt(), 2);
    }

    void dialogClosesWhenIdle()
    {
        open("dialog");
        m_device.setIdle(true);
        QTRY_VERIFY(!child("dialog")->property("visible").toBool());
    }

    // Without an on-screen keyboard it is as tall as its content, centred,
    // and it opens right there rather than sliding into place.
    void dialogFitsItsContent()
    {
        open("dialog");
        QObject *dialog = child("dialog");
        const qreal height = dialog->property("height").toReal();
        QCOMPARE(height, dialog->property("implicitHeight").toReal());
        QVERIFY(height > 100);
        QCOMPARE(dialog->property("y").toReal(), qreal(qRound((800 - height) / 2)));
        // Nothing more to scroll to, so no edge fades.
        QCOMPARE(fades().size(), 2);
        QCOMPARE(fades()[0]->opacity(), 0.0);
        QCOMPARE(fades()[1]->opacity(), 0.0);
    }

    // A body taller than the room scrolls, and an edge fades where there's
    // more to scroll to that way.
    void bodyFadesWhereThereIsMore()
    {
        m_window->setProperty("extraBody", 1200);
        open("dialog");
        QQuickItem *flick = body();
        QVERIFY(flick);
        QTRY_VERIFY(flick->property("contentHeight").toReal() > flick->height() + 300);
        QCOMPARE(fades().size(), 2);
        QQuickItem *top = fades()[0];
        QQuickItem *bottom = fades()[1];
        QCOMPARE(top->y(), 0.0);
        QCOMPARE(bottom->y() + bottom->height(), flick->height());
        QTRY_COMPARE(bottom->opacity(), 1.0);
        QCOMPARE(top->opacity(), 0.0);

        flick->setProperty("contentY", flick->property("contentHeight").toReal() - flick->height());
        QTRY_COMPARE(top->opacity(), 1.0);
        QTRY_COMPARE(bottom->opacity(), 0.0);
        QCOMPARE(top->y(), 0.0);

        flick->setProperty("contentY", 300);
        QTRY_COMPARE(top->opacity(), 1.0);
        QTRY_COMPARE(bottom->opacity(), 1.0);
    }
};

QTEST_MAIN(TestDialogs)
#include "tst_dialogs.moc"
