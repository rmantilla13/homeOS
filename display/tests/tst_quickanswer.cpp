#include <QtTest>

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkProxy>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QWebSocket>
#include <QWebSocketServer>

#include "backend/SupabaseClient.h"
#include "models/Assistant.h"
#include "models/FamilyStore.h"
#include "voice/VoiceClient.h"

// Stands in for DisplayController: the theme only reads the mood.
class FakeDevice : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mood READ mood CONSTANT)
public:
    QString mood() const { return QStringLiteral("day"); }
};

// The wake-word card (QuickAnswer.qml) driven the way Main.qml drives it,
// with the real assistant (demo answers) and voice client, against an
// in-process voice service that records what the display asks it to say.
class TestQuickAnswer : public QObject
{
    Q_OBJECT

    QWebSocketServer *m_server = nullptr;
    QPointer<QWebSocket> m_peer;
    QList<QJsonObject> m_received;

    SupabaseClient *m_client = nullptr;
    FamilyStore *m_store = nullptr;
    VoiceClient *m_voice = nullptr;
    Assistant *m_ai = nullptr;
    FakeDevice m_device;
    QQmlEngine *m_engine = nullptr;
    QObject *m_quick = nullptr;

    QString phase() const { return m_quick->property("phase").toString(); }
    void call(const char *function, const QVariant &arg = {})
    {
        if (arg.isValid())
            QVERIFY(QMetaObject::invokeMethod(m_quick, function, Q_ARG(QVariant, arg)));
        else
            QVERIFY(QMetaObject::invokeMethod(m_quick, function));
    }
    QStringList spokenTexts() const
    {
        QStringList out;
        for (const QJsonObject &m : m_received)
            if (m.value("type").toString() == "speak")
                out << m.value("text").toString();
        return out;
    }

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName("homeOS-tests");
        QCoreApplication::setApplicationName("tst_quickanswer");
        QSettings().clear();
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);

        m_server = new QWebSocketServer("fake-voice", QWebSocketServer::NonSecureMode, this);
        QVERIFY(m_server->listen(QHostAddress::LocalHost));
        connect(m_server, &QWebSocketServer::newConnection, this, [this]() {
            m_peer = m_server->nextPendingConnection();
            connect(m_peer, &QWebSocket::textMessageReceived, this, [this](const QString &t) {
                const QJsonObject m = QJsonDocument::fromJson(t.toUtf8()).object();
                m_received << m;
                if (m.value("type").toString() == "speak") // "said" at once
                    m_peer->sendTextMessage(QStringLiteral("{\"type\":\"spoken\",\"id\":\"%1\"}")
                                                .arg(m.value("id").toString()));
            });
            m_peer->sendTextMessage(R"({"type":"hello","version":"1","wakeword":true,"wakeword_name":"hey_jarvis","tts":true,"stt":true})");
            m_peer->sendTextMessage(R"({"type":"state","state":"idle"})");
        });

        m_client = new SupabaseClient(QUrl(), QString(), this);
        m_store = new FamilyStore(m_client, true, this);
        m_store->start(); // demo mode
        m_voice = new VoiceClient(QUrl(QStringLiteral("ws://127.0.0.1:%1").arg(m_server->serverPort())), this);
        m_voice->start();
        QTRY_VERIFY(m_voice->available());
        QTRY_VERIFY(m_voice->canSpeak());
        m_ai = new Assistant(m_client, m_store, m_voice, this);

        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "AI", m_ai);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Voice", m_voice);
        qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &m_device);
        m_engine = new QQmlEngine(this);
        m_engine->addImportPath(QStringLiteral(HOMEOS_TEST_QML_DIR));
        QQmlComponent component(m_engine);
        component.setData("import HomeOS\nQuickAnswer { width: 1280; height: 800 }", QUrl());
        m_quick = component.create();
        QVERIFY2(m_quick, qPrintable(component.errorString()));
        m_quick->setParent(this);
    }

    void init()
    {
        call("dismiss", false);
        m_ai->reset();
        QTest::qWait(50);
        m_received.clear();
    }

    void cleanupTestCase() { QSettings().clear(); }

    void answersAndSpeaks()
    {
        call("start");
        QCOMPARE(phase(), QStringLiteral("listening"));
        call("hear", QStringLiteral("what's for dinner"));
        QCOMPARE(phase(), QStringLiteral("thinking"));
        QTRY_COMPARE(phase(), QStringLiteral("done"));
        QTRY_COMPARE(spokenTexts(), QStringList{m_ai->replyText()});
        // Dismissed 6 s after `spoken`, not before.
        QTest::qWait(4500);
        QCOMPARE(phase(), QStringLiteral("done"));
        QTRY_COMPARE_WITH_TIMEOUT(phase(), QStringLiteral("hidden"), 4000);
    }

    void nothingHeard()
    {
        call("start");
        call("miss");
        QCOMPARE(phase(), QStringLiteral("missed"));
        QTRY_COMPARE_WITH_TIMEOUT(phase(), QStringLiteral("hidden"), 4000);
    }

    void dismissWhileThinkingStopsTheAnswer()
    {
        // Tapping outside dismisses the card and stops speech: the answer
        // still on its way must not be read out a moment later.
        call("start");
        call("hear", QStringLiteral("what's for dinner"));
        QVERIFY(m_ai->busy());
        call("dismiss", true);
        QCOMPARE(phase(), QStringLiteral("hidden"));
        QTest::qWait(1500); // a demo answer takes about one second
        QVERIFY(!m_ai->busy());
        QCOMPARE(spokenTexts(), QStringList());
    }

    void secondWakeDropsTheEarlierAnswer()
    {
        call("start");
        call("hear", QStringLiteral("what's for dinner"));
        call("start"); // the wake word again while the first answer is coming
        QTest::qWait(1500);
        QCOMPARE(phase(), QStringLiteral("listening"));
        QCOMPARE(spokenTexts(), QStringList()); // not read out over the new question
        call("hear", QStringLiteral("what's on today"));
        QTRY_COMPARE(phase(), QStringLiteral("done"));
        QTRY_COMPARE(spokenTexts().size(), 1);
        QVERIFY2(spokenTexts().first().contains("calendar") || spokenTexts().first().startsWith("Today"),
                 qPrintable(spokenTexts().first()));
    }

    void newQuestionWhileOldAnswerStreams()
    {
        // The second question is heard before the first answer arrived: the
        // card shows "Thinking…" for the new one, not the old turn's ending.
        call("start");
        call("hear", QStringLiteral("what's for dinner"));
        call("start");
        call("hear", QStringLiteral("what's on today"));
        QCOMPARE(phase(), QStringLiteral("thinking"));
        QCOMPARE(m_quick->property("stateLabel").toString(), QStringLiteral("Thinking…"));
        QTRY_COMPARE(phase(), QStringLiteral("done"));
        QTRY_COMPARE(spokenTexts().size(), 1);
    }
};

QTEST_MAIN(TestQuickAnswer)
#include "tst_quickanswer.moc"
