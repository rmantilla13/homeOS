#include <QtTest>

#include <QJsonArray>
#include <QNetworkProxy>
#include <QSettings>
#include <QTcpServer>
#include <QTcpSocket>

#include "backend/SupabaseClient.h"
#include "models/Assistant.h"
#include "models/FamilyStore.h"

// The assistant and the family store in live mode, against a small stand-in
// for Supabase (auth, PostgREST, the assistant and pair-device functions).
class TestAssistant : public QObject
{
    Q_OBJECT

    struct Request
    {
        QByteArray method;
        QByteArray path;  // with the query
        QByteArray auth;  // Authorization header
        QJsonObject body;
    };
    struct Reply
    {
        int status = 200;
        QByteArray type = "application/json";
        QList<QByteArray> chunks; // written ~10 ms apart
        int delayMs = 0;          // before the first byte
    };
    using Route = std::function<Reply(const Request &)>;

    QTcpServer m_server;
    QList<QPair<QByteArray, Route>> m_routes; // path prefix -> handler (first match wins)
    QList<Request> m_requests;

    QUrl baseUrl() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_server.serverPort())); }

    static Reply json(const QByteArray &body, int status = 200, int delayMs = 0)
    {
        return {status, "application/json", {body}, delayMs};
    }
    static QByteArray event(const char *name, const QJsonObject &data)
    {
        return QByteArray("event: ") + name + "\ndata: " + QJsonDocument(data).toJson(QJsonDocument::Compact) + "\n\n";
    }
    static Reply stream(const QList<QByteArray> &events) { return {200, "text/event-stream", events, 0}; }

    void route(const QByteArray &prefix, Route handler) { m_routes.prepend({prefix, handler}); }

    QList<Request> requestsTo(const QByteArray &prefix) const
    {
        QList<Request> out;
        for (const Request &r : m_requests)
            if (r.path.startsWith(prefix))
                out << r;
        return out;
    }

    void serve(QTcpSocket *socket, const Request &request)
    {
        m_requests << request;
        Reply reply = json("[]");
        for (const auto &[prefix, handler] : std::as_const(m_routes)) {
            if (request.path.startsWith(prefix)) {
                reply = handler(request);
                break;
            }
        }
        QTimer::singleShot(reply.delayMs, socket, [socket, reply]() {
            QByteArray head = "HTTP/1.1 " + QByteArray::number(reply.status) + " X\r\nContent-Type: " + reply.type
                              + "\r\nConnection: close\r\n";
            if (reply.type != "text/event-stream")
                head += "Content-Length: " + QByteArray::number(reply.chunks.join().size()) + "\r\n";
            socket->write(head + "\r\n");
            for (int i = 0; i < reply.chunks.size(); ++i)
                QTimer::singleShot(10 * (i + 1), socket, [socket, c = reply.chunks.at(i)]() { socket->write(c); });
            QTimer::singleShot(10 * (reply.chunks.size() + 1), socket, [socket]() {
                socket->flush();
                socket->disconnectFromHost();
            });
        });
    }

    // A display signed in to "Test Family", with the assistant on top.
    struct Rig
    {
        explicit Rig(const QUrl &url) : client(url, "anon-key"), store(&client, false), ai(&client, &store, nullptr) {}
        SupabaseClient client;
        FamilyStore store;
        Assistant ai;
    };
    std::unique_ptr<Rig> signedIn()
    {
        auto rig = std::make_unique<Rig>(baseUrl());
        rig->client.setRefreshToken("refresh-0");
        rig->store.start();
        if (!QTest::qWaitFor([&]() { return rig->store.online() && rig->store.familyName() == "Test Family"; }, 5000))
            qWarning() << "the store never came online";
        return rig;
    }

    // Asks and waits for the turn to end.
    static bool askAndWait(Assistant &ai, const QString &text)
    {
        QSignalSpy finished(&ai, &Assistant::replyFinished);
        ai.ask(text);
        return finished.wait(5000) || finished.size() > 0;
    }

    static QByteArray okStream(const QString &reply, const QString &thread = "t1")
    {
        return event("thread", {{"thread_id", thread}}) + event("delta", {{"text", reply}})
               + event("done", {{"reply", reply}, {"actions", QJsonArray()}, {"thread_id", thread}, {"message_id", 1}});
    }

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName("homeOS-tests");
        QCoreApplication::setApplicationName("tst_assistant");
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
        connect(&m_server, &QTcpServer::newConnection, this, [this]() {
            while (QTcpSocket *socket = m_server.nextPendingConnection()) {
                auto buffer = std::make_shared<QByteArray>();
                connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer]() {
                    buffer->append(socket->readAll());
                    const qsizetype end = buffer->indexOf("\r\n\r\n");
                    if (end < 0)
                        return;
                    const QList<QByteArray> lines = buffer->left(end).split('\n');
                    Request r;
                    const QList<QByteArray> first = lines.first().trimmed().split(' ');
                    r.method = first.value(0);
                    r.path = first.value(1);
                    int length = 0;
                    for (const QByteArray &line : lines.mid(1)) {
                        const qsizetype colon = line.indexOf(':');
                        const QByteArray name = line.left(colon).trimmed().toLower();
                        const QByteArray value = line.mid(colon + 1).trimmed();
                        if (name == "content-length")
                            length = value.toInt();
                        else if (name == "authorization")
                            r.auth = value;
                    }
                    if (buffer->size() < end + 4 + length)
                        return;
                    r.body = QJsonDocument::fromJson(buffer->mid(end + 4, length)).object();
                    disconnect(socket, &QTcpSocket::readyRead, socket, nullptr);
                    serve(socket, r);
                });
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            }
        });
    }

    void init()
    {
        QSettings().clear();
        m_requests.clear();
        m_routes.clear();
        route("/auth/v1/token", [](const Request &) {
            return json("{\"access_token\":\"access-1\",\"refresh_token\":\"refresh-1\"}");
        });
        route("/rest/v1/families", [](const Request &) { return json("[{\"name\":\"Test Family\"}]"); });
        route("/functions/v1/pair-device", [](const Request &) { return json("{\"code\":\"ABC123\"}"); });
        route("/storage/", [](const Request &) { return json("[]"); });
    }

    // Let requests a test left in flight reach the server before the next one.
    void cleanup() { QTest::qWait(100); }

    void cleanupTestCase() { QSettings().clear(); }

    // ── The assistant (PLATFORM_SPEC §2.1 stream, §5 display) ──

    void doneReplyIsFinal()
    {
        // After a refusal the function's `done` reply replaces what streamed.
        const QString refusal = QStringLiteral("Sorry, I can't help with that one.");
        route("/functions/v1/assistant", [refusal](const Request &) {
            return stream({event("thread", {{"thread_id", "t1"}}), event("delta", {{"text", "Let me look "}}),
                           event("delta", {{"text", "into that"}}),
                           event("done", {{"reply", refusal}, {"actions", QJsonArray()}, {"thread_id", "t1"},
                                          {"message_id", 7}})});
        });
        auto rig = signedIn();
        QVERIFY(askAndWait(rig->ai, "Tell me a secret"));

        QCOMPARE(rig->ai.messages()->count(), 2);
        const ChatModel::Message &m = rig->ai.messages()->at(1);
        QCOMPARE(m.text, refusal);
        QVERIFY(!m.failed);
        QVERIFY(!m.streaming);
        QCOMPARE(rig->ai.replyText(), refusal);
        QVERIFY(!rig->ai.busy());

        const QList<Request> sent = requestsTo("/functions/v1/assistant");
        QCOMPARE(sent.size(), 1);
        QCOMPARE(sent.first().body.value("message").toString(), QStringLiteral("Tell me a secret"));
        QCOMPARE(sent.first().body.value("mode").toString(), QStringLiteral("chat"));
        QCOMPARE(sent.first().body.value("stream").toBool(), true);
        QVERIFY(!sent.first().body.contains("thread_id"));
        QCOMPARE(sent.first().auth, QByteArray("Bearer access-1"));
    }

    void errorEventEndsTheTurn_data()
    {
        QTest::addColumn<QString>("partial");
        QTest::newRow("after some text") << QStringLiteral("Tonight we");
        QTest::newRow("before any text") << QString();
    }
    void errorEventEndsTheTurn()
    {
        QFETCH(QString, partial);
        const QString message = QStringLiteral("The assistant isn't available right now. Please try again in a bit.");
        route("/functions/v1/assistant", [partial, message](const Request &) {
            QList<QByteArray> events{event("thread", {{"thread_id", "t1"}})};
            if (!partial.isEmpty())
                events << event("delta", {{"text", partial}});
            events << event("error", {{"message", message}});
            return stream(events);
        });
        auto rig = signedIn();
        QSignalSpy finished(&rig->ai, &Assistant::replyFinished);
        QVERIFY(askAndWait(rig->ai, "What's for dinner?"));
        QTest::qWait(100); // the stream's own end must not finish the turn again
        QCOMPARE(finished.size(), 1);
        QVERIFY(!rig->ai.busy());
        const ChatModel::Message &m = rig->ai.messages()->at(1);
        // A partial answer is kept and marked cut short; otherwise the message shows.
        QCOMPARE(m.text, partial.isEmpty() ? message : partial);
        QCOMPARE(m.failed, !partial.isEmpty());
    }

    void threadContinuesUntilNewChat()
    {
        route("/functions/v1/assistant", [](const Request &) { return stream({okStream("Sure.", "t1")}); });
        auto rig = signedIn();
        QVERIFY(askAndWait(rig->ai, "one"));
        QCOMPARE(rig->ai.threadId(), QStringLiteral("t1"));
        QCOMPARE(QSettings().value("assistant/threadId").toString(), QStringLiteral("t1"));

        QVERIFY(askAndWait(rig->ai, "two"));
        QCOMPARE(requestsTo("/functions/v1/assistant").last().body.value("thread_id").toString(), QStringLiteral("t1"));

        // "New chat" forgets the thread, here and in the settings.
        rig->ai.reset();
        QCOMPARE(rig->ai.messages()->count(), 0);
        QCOMPARE(rig->ai.threadId(), QString());
        QVERIFY(!QSettings().contains("assistant/threadId"));
        QVERIFY(askAndWait(rig->ai, "three"));
        QVERIFY(!requestsTo("/functions/v1/assistant").last().body.contains("thread_id"));
    }

    void deletedThreadStartsOver()
    {
        QSettings().setValue("assistant/threadId", "gone");
        route("/rest/v1/assistant_messages", [](const Request &) {
            return json("[{\"role\":\"assistant\",\"content\":\"Earlier answer\",\"actions\":[],\"mode\":\"chat\"}]");
        });
        route("/functions/v1/assistant", [](const Request &r) {
            if (r.body.contains("thread_id"))
                return json("{\"error\":\"thread not found\"}", 404);
            return stream({okStream("Fresh start.", "t2")});
        });
        auto rig = signedIn();
        QTRY_COMPARE(rig->ai.messages()->count(), 1); // restored on start-up
        QVERIFY(askAndWait(rig->ai, "hello again"));
        const QList<Request> sent = requestsTo("/functions/v1/assistant");
        QCOMPARE(sent.size(), 2);
        QCOMPARE(sent.at(0).body.value("thread_id").toString(), QStringLiteral("gone"));
        QVERIFY(!sent.at(1).body.contains("thread_id"));
        QCOMPARE(rig->ai.replyText(), QStringLiteral("Fresh start."));
        QCOMPARE(rig->ai.threadId(), QStringLiteral("t2"));
    }

    void expiredTokenIsRefreshedOnce()
    {
        int tokens = 0;
        route("/auth/v1/token", [&tokens](const Request &) {
            ++tokens;
            return json(QStringLiteral("{\"access_token\":\"access-%1\",\"refresh_token\":\"refresh-%1\"}")
                            .arg(tokens).toUtf8());
        });
        route("/functions/v1/assistant", [](const Request &r) {
            if (r.auth == "Bearer access-1")
                return json("{\"message\":\"JWT expired\"}", 401);
            return stream({okStream("Hi!")});
        });
        auto rig = signedIn();
        QVERIFY(askAndWait(rig->ai, "hi"));
        QCOMPARE(rig->ai.replyText(), QStringLiteral("Hi!"));
        QCOMPARE(requestsTo("/functions/v1/assistant").last().auth, QByteArray("Bearer access-2"));
    }

    void refreshOutageIsNotAPairingProblem()
    {
        // The token endpoint is down (5xx/network), not rejecting the token:
        // the display is still paired and must not say otherwise.
        auto rig = signedIn();
        route("/auth/v1/token", [](const Request &) { return json("{\"message\":\"upstream timeout\"}", 503); });
        route("/functions/v1/assistant", [](const Request &) { return json("{\"message\":\"JWT expired\"}", 401); });
        QVERIFY(askAndWait(rig->ai, "hi"));
        QCOMPARE(rig->store.mode(), QStringLiteral("live"));
        const QString text = rig->ai.messages()->at(1).text;
        QVERIFY2(!text.contains("pair"), qPrintable(text));
        QCOMPARE(text, QStringLiteral("I couldn't reach homeOS cloud just now. Try again in a moment."));
    }

    void refreshTokenIsSavedPrivately()
    {
        auto rig = signedIn();
        QSettings settings;
        QCOMPARE(settings.value("device/refreshToken").toString(), QStringLiteral("refresh-1"));
        const QFileDevice::Permissions perms = QFileInfo(settings.fileName()).permissions();
        QVERIFY(!(perms & (QFileDevice::ReadGroup | QFileDevice::ReadOther)));
    }

    void displayChecksIn()
    {
        // devices.last_seen_at, which the iOS app and the admin console show.
        QSettings().setValue("device/id", "dev-1");
        auto rig = signedIn();
        QTRY_COMPARE(requestsTo("/rest/v1/devices").size(), 1);
        const Request r = requestsTo("/rest/v1/devices").first();
        QCOMPARE(r.method, QByteArray("PATCH"));
        QCOMPARE(r.path, QByteArray("/rest/v1/devices?id=eq.dev-1"));
        QCOMPARE(r.auth, QByteArray("Bearer access-1"));
        const QDateTime seen = QDateTime::fromString(r.body.value("last_seen_at").toString(), Qt::ISODateWithMs);
        QVERIFY(seen.isValid());
        QVERIFY(qAbs(seen.secsTo(QDateTime::currentDateTimeUtc())) < 60);

        // Not on every sync: at most every few minutes.
        rig->store.refresh();
        QTRY_VERIFY(requestsTo("/rest/v1/families").size() >= 2);
        QTest::qWait(100);
        QCOMPARE(requestsTo("/rest/v1/devices").size(), 1);
    }

    // ── Re-pairing (Settings → Re-pair this display) ──

    void unpairDuringRefreshForgetsTheSession()
    {
        // The refresh answers only after the display was told to re-pair.
        route("/auth/v1/token", [](const Request &) {
            return json("{\"access_token\":\"old-access\",\"refresh_token\":\"old-refresh\"}", 200, 300);
        });
        Rig rig(baseUrl());
        rig.client.setRefreshToken("refresh-0");
        QSettings().setValue("device/refreshToken", "refresh-0");
        rig.store.start();
        QTRY_VERIFY(!requestsTo("/auth/v1/token").isEmpty());
        rig.store.unpair();
        QCOMPARE(rig.store.mode(), QStringLiteral("pairing"));
        QTest::qWait(600);

        QVERIFY(!rig.client.hasSession());
        QCOMPARE(rig.client.refreshToken(), QString());
        QVERIFY(!QSettings().contains("device/refreshToken")); // would sign back in after a restart
        QCOMPARE(rig.store.familyName(), QString());
        for (const Request &r : requestsTo("/rest/v1/"))
            QVERIFY(r.auth != "Bearer old-access"); // no loads as the old display
        QCOMPARE(rig.store.lastError(), QString());
    }

    void unpairDropsLoadsInFlight()
    {
        // The old family's rows arrive after re-pairing started.
        route("/rest/v1/families", [](const Request &) { return json("[{\"name\":\"Old Family\"}]", 200, 300); });
        route("/rest/v1/members", [](const Request &) {
            return json("[{\"id\":\"m1\",\"display_name\":\"Mom\",\"color\":\"#ff0000\"}]", 200, 300);
        });
        Rig rig(baseUrl());
        rig.client.setSession("access-1", "refresh-1");
        rig.store.start();
        QTRY_VERIFY(!requestsTo("/rest/v1/families").isEmpty() && !requestsTo("/rest/v1/members").isEmpty());
        rig.store.unpair();
        QTest::qWait(600);
        QCOMPARE(rig.store.familyName(), QString());
        QCOMPARE(rig.store.members().size(), 0);
    }
};

QTEST_MAIN(TestAssistant)
#include "tst_assistant.moc"
