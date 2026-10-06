#include <QtTest>

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkProxy>
#include <QWebSocket>
#include <QWebSocketServer>

#include "voice/VoiceClient.h"

// VoiceClient against an in-process stand-in for the voice service that
// speaks the PLATFORM_SPEC.md §4 protocol.
class TestVoiceClient : public QObject
{
    Q_OBJECT

    QWebSocketServer *m_server = nullptr;
    QPointer<QWebSocket> m_peer;
    QList<QJsonObject> m_received;
    int m_connections = 0;

    void serverSend(const QJsonObject &o)
    {
        QVERIFY(m_peer);
        m_peer->sendTextMessage(QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
    }

    QUrl url() const { return QUrl(QStringLiteral("ws://127.0.0.1:%1").arg(m_server->serverPort())); }

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName("homeOS-tests");
        QCoreApplication::setApplicationName("tst_voiceclient");
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
        m_server = new QWebSocketServer("fake-voice", QWebSocketServer::NonSecureMode, this);
        QVERIFY(m_server->listen(QHostAddress::LocalHost));
        connect(m_server, &QWebSocketServer::newConnection, this, [this]() {
            m_peer = m_server->nextPendingConnection();
            ++m_connections;
            connect(m_peer, &QWebSocket::textMessageReceived, this,
                    [this](const QString &t) { m_received << QJsonDocument::fromJson(t.toUtf8()).object(); });
            serverSend({{"type", "hello"}, {"version", "1"}, {"wakeword", true},
                        {"wakeword_name", "hey_jarvis_v0.1"}, {"tts", true}, {"stt", true}});
            serverSend({{"type", "state"}, {"state", "idle"}});
        });
    }

    void protocol()
    {
        VoiceClient voice(url());
        voice.setRetryInterval(200);
        QVERIFY(!voice.available());
        QCOMPARE(voice.speak("nobody is listening"), QString()); // not connected yet

        voice.start();
        QTRY_VERIFY(voice.available());
        QTRY_VERIFY(voice.wakewordEnabled());
        QCOMPARE(voice.wakewordName(), QStringLiteral("hey_jarvis_v0.1"));
        QCOMPARE(voice.wakewordLabel(), QStringLiteral("Hey Jarvis"));
        QVERIFY(voice.canSpeak());
        QCOMPARE(voice.state(), QStringLiteral("idle"));

        // A wake-word turn: wake, levels, transcript.
        QSignalSpy woke(&voice, &VoiceClient::woke);
        QSignalSpy heard(&voice, &VoiceClient::heard);
        QSignalSpy nothing(&voice, &VoiceClient::heardNothing);
        serverSend({{"type", "wake"}, {"source", "wakeword"}});
        serverSend({{"type", "state"}, {"state", "listening"}});
        serverSend({{"type", "level"}, {"rms", 0.42}});
        QTRY_COMPARE(woke.size(), 1);
        QCOMPARE(woke.first().first().toString(), QStringLiteral("wakeword"));
        QTRY_COMPARE(voice.level(), 0.42);
        QCOMPARE(voice.state(), QStringLiteral("listening"));
        serverSend({{"type", "level"}, {"rms", 7.0}});
        QTRY_COMPARE(voice.level(), 1.0); // clamped
        serverSend({{"type", "state"}, {"state", "transcribing"}});
        QTRY_COMPARE(voice.state(), QStringLiteral("transcribing"));
        QCOMPARE(voice.level(), 0.0); // only meaningful while listening
        serverSend({{"type", "transcript"}, {"text", " what's for dinner "}, {"final", true}});
        QTRY_COMPARE(heard.size(), 1);
        QCOMPARE(heard.first().first().toString(), QStringLiteral("what's for dinner"));
        QCOMPARE(voice.transcript(), QStringLiteral("what's for dinner"));
        QCOMPARE(nothing.size(), 0);

        // A new turn clears the transcript; an empty one means nothing was heard.
        serverSend({{"type", "wake"}, {"source", "button"}});
        QTRY_COMPARE(woke.size(), 2);
        QCOMPARE(voice.transcript(), QString());
        serverSend({{"type", "transcript"}, {"text", ""}, {"final", true}});
        QTRY_COMPARE(nothing.size(), 1);
        QCOMPARE(heard.size(), 1);

        // Client -> server messages.
        m_received.clear();
        voice.listen();
        voice.cancel();
        const QString id = voice.speak("Tonight is tacos.");
        QVERIFY(!id.isEmpty());
        voice.stopSpeaking();
        voice.setWakewordEnabled(false);
        QVERIFY(!voice.wakewordEnabled()); // optimistic until the service's next hello
        QTRY_COMPARE(m_received.size(), 5);
        QCOMPARE(m_received.at(0).value("type").toString(), QStringLiteral("listen"));
        QCOMPARE(m_received.at(1).value("type").toString(), QStringLiteral("cancel"));
        QCOMPARE(m_received.at(2).value("type").toString(), QStringLiteral("speak"));
        QCOMPARE(m_received.at(2).value("text").toString(), QStringLiteral("Tonight is tacos."));
        QCOMPARE(m_received.at(2).value("id").toString(), id);
        QCOMPARE(m_received.at(3).value("type").toString(), QStringLiteral("stop_speaking"));
        QCOMPARE(m_received.at(4).value("type").toString(), QStringLiteral("set"));
        QCOMPARE(m_received.at(4).value("wakeword_enabled").toBool(), false);

        // The service refuses (no model) and says so with a fresh hello.
        QSignalSpy errors(&voice, &VoiceClient::errorOccurred);
        serverSend({{"type", "error"}, {"message", "The wake word isn't available"}});
        serverSend({{"type", "hello"}, {"version", "1"}, {"wakeword", true},
                    {"wakeword_name", "hey_jarvis"}, {"tts", true}, {"stt", true}});
        QTRY_COMPARE(errors.size(), 1);
        QTRY_VERIFY(voice.wakewordEnabled());

        QSignalSpy spoken(&voice, &VoiceClient::spoken);
        serverSend({{"type", "spoken"}, {"id", id}});
        QTRY_COMPARE(spoken.size(), 1);
        QCOMPARE(spoken.first().first().toString(), id);

        // Junk and unknown messages are ignored.
        m_peer->sendTextMessage("not json");
        serverSend({{"type", "mystery"}});
        serverSend({{"type", "state"}, {"state", "dancing"}});
        QTest::qWait(50);
        QVERIFY(voice.available());
        QCOMPARE(voice.state(), QStringLiteral("transcribing"));
    }

    void helloAtAnyTime()
    {
        // The service re-sends hello after `set` and when the mic comes or
        // goes, mid-session included, followed by the current state.
        VoiceClient voice(url());
        voice.start();
        QTRY_VERIFY(voice.available());
        QTRY_VERIFY(voice.canTranscribe());
        serverSend({{"type", "wake"}, {"source", "wakeword"}});
        serverSend({{"type", "state"}, {"state", "listening"}});
        QTRY_COMPARE(voice.state(), QStringLiteral("listening"));

        QSignalSpy info(&voice, &VoiceClient::infoChanged);
        serverSend({{"type", "hello"}, {"version", "1"}, {"wakeword", false},
                    {"wakeword_name", "hey_homeos"}, {"tts", true}, {"stt", false}});
        serverSend({{"type", "state"}, {"state", "idle"}});
        QTRY_COMPARE(voice.state(), QStringLiteral("idle"));
        QVERIFY(info.size() >= 1);
        QVERIFY(voice.available());
        QVERIFY(!voice.wakewordEnabled());
        QVERIFY(!voice.canTranscribe());
        QVERIFY(voice.canSpeak());
        QCOMPARE(voice.wakewordLabel(), QStringLiteral("Hey Ohana"));

        serverSend({{"type", "hello"}, {"version", "1"}, {"wakeword", true},
                    {"wakeword_name", "hey_homeos"}, {"tts", true}, {"stt", true}});
        QTRY_VERIFY(voice.wakewordEnabled());
        QVERIFY(voice.canTranscribe());
    }

    void reconnects()
    {
        VoiceClient voice(url());
        voice.setRetryInterval(200);
        const int before = m_connections;
        voice.start();
        QTRY_VERIFY(voice.available());
        QCOMPARE(m_connections, before + 1);

        // Service restarts: the client notices, then comes back on its own.
        m_peer->close();
        QTRY_VERIFY(!voice.available());
        QCOMPARE(voice.state(), QStringLiteral("idle"));
        QTRY_VERIFY_WITH_TIMEOUT(voice.available(), 3000);
        QCOMPARE(m_connections, before + 2);

        // Service gone for a while: keeps trying, without errors.
        const quint16 port = m_server->serverPort();
        m_server->close();
        m_peer->close();
        QTRY_VERIFY(!voice.available());
        QTest::qWait(500);
        QVERIFY(!voice.available());
        QVERIFY(m_server->listen(QHostAddress::LocalHost, port));
        QTRY_VERIFY_WITH_TIMEOUT(voice.available(), 3000);
    }

    void speakRepliesIsRemembered()
    {
        {
            VoiceClient voice(QUrl{});
            voice.setSpeakReplies(false);
        }
        VoiceClient voice(QUrl{});
        QVERIFY(!voice.speakReplies());
        voice.setSpeakReplies(true);
        QVERIFY(voice.speakReplies());
    }

    void cleanupTestCase()
    {
        QSettings().clear();
    }
};

QTEST_GUILESS_MAIN(TestVoiceClient)
#include "tst_voiceclient.moc"
