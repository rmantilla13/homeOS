#include <QtTest>

#include <QNetworkProxy>
#include <QNetworkReply>
#include <QTcpServer>
#include <QTcpSocket>

#include "backend/SupabaseClient.h"

// SupabaseClient::streamFunction against a tiny local HTTP server that sends
// the assistant's events in awkward pieces, as a real network would.
class TestStreamFunction : public QObject
{
    Q_OBJECT

    struct Response
    {
        QByteArray head;              // status line + headers, no blank line
        QList<QByteArray> chunks;     // body, written one per tick
        bool close = true;            // close the connection after the last chunk
    };

    QTcpServer m_server;
    Response m_response;
    QByteArray m_lastRequest;

    QUrl baseUrl() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_server.serverPort())); }

    struct Result
    {
        QList<QPair<QString, QJsonObject>> events;
        QString error;
        bool finished = false;
        int finishCount = 0;
    };

    void run(SupabaseClient &client, Result &r, std::function<void(QNetworkReply *, Result &)> onEvent = {})
    {
        QNetworkReply *reply = nullptr;
        reply = client.streamFunction(
            "assistant", {{"message", "What's for dinner?"}, {"mode", "quick"}, {"stream", true}},
            [&r, &reply, onEvent](const QString &event, const QJsonObject &data) {
                r.events.append({event, data});
                if (onEvent)
                    onEvent(reply, r);
            },
            [&r](const QString &error) {
                r.error = error;
                r.finished = true;
                ++r.finishCount;
            });
        QTRY_VERIFY_WITH_TIMEOUT(r.finished, 5000);
        QTest::qWait(50); // nothing may arrive after onFinished
    }

    void respond(QTcpSocket *socket)
    {
        socket->write(m_response.head + "\r\n\r\n");
        const QList<QByteArray> chunks = m_response.chunks;
        const bool close = m_response.close;
        for (int i = 0; i < chunks.size(); ++i) {
            QTimer::singleShot(15 * (i + 1), socket, [socket, chunk = chunks.at(i)]() { socket->write(chunk); });
        }
        QTimer::singleShot(15 * (chunks.size() + 1), socket, [socket, close]() {
            socket->flush();
            if (close)
                socket->disconnectFromHost();
        });
    }

private slots:
    void initTestCase()
    {
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
        QVERIFY(m_server.listen(QHostAddress::LocalHost));
        connect(&m_server, &QTcpServer::newConnection, this, [this]() {
            QTcpSocket *socket = m_server.nextPendingConnection();
            auto request = std::make_shared<QByteArray>();
            connect(socket, &QTcpSocket::readyRead, socket, [this, socket, request]() {
                request->append(socket->readAll());
                const qsizetype end = request->indexOf("\r\n\r\n");
                if (end < 0)
                    return;
                const QByteArray lengthHeader = "content-length:";
                const QByteArray lower = request->left(end).toLower();
                const qsizetype at = lower.indexOf(lengthHeader);
                const int length = at < 0 ? 0 : lower.mid(at + lengthHeader.size()).split('\r').first().trimmed().toInt();
                if (request->size() < end + 4 + length)
                    return;
                m_lastRequest = *request;
                disconnect(socket, &QTcpSocket::readyRead, socket, nullptr);
                respond(socket);
            });
        });
    }

    void streamsEventsAcrossOddChunks()
    {
        const QByteArray body =
            "event: thread\r\ndata: {\"thread_id\":\"t1\"}\r\n\r\n"
            ": ping\r\n\r\n"
            "event: delta\r\ndata: {\"text\":\"Tonight \"}\r\n\r\n"
            "event: delta\r\ndata: {\"text\":\"is tacos.\"}\r\n\r\n"
            "event: action\r\ndata: {\"type\":\"set_meal\",\"summary\":\"Set dinner to tacos\"}\r\n\r\n"
            "event: done\r\ndata: {\"reply\":\"Tonight is tacos.\",\"actions\":[{\"type\":\"set_meal\",\"summary\":\"Set dinner to tacos\"}],"
            "\"thread_id\":\"t1\",\"message_id\":9}\r\n\r\n";
        // Cut inside a field name, between CR and LF, and inside the JSON.
        const QList<qsizetype> cuts{3, 14, 15, 40, 41, 77, 120, 121, 200, 260, 330};
        QList<QByteArray> chunks;
        qsizetype from = 0;
        for (qsizetype cut : cuts) {
            chunks << body.mid(from, cut - from);
            from = cut;
        }
        chunks << body.mid(from);
        m_response = {"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close",
                      chunks};

        SupabaseClient client(baseUrl(), "anon-key");
        client.setSession("access-token", "refresh-token");
        Result r;
        run(client, r);

        QCOMPARE(r.error, QString());
        QCOMPARE(r.finishCount, 1);
        QCOMPARE(r.events.size(), 5);
        QCOMPARE(r.events.at(0).first, QStringLiteral("thread"));
        QCOMPARE(r.events.at(0).second.value("thread_id").toString(), QStringLiteral("t1"));
        QCOMPARE(r.events.at(1).second.value("text").toString() + r.events.at(2).second.value("text").toString(),
                 QStringLiteral("Tonight is tacos."));
        QCOMPARE(r.events.at(3).first, QStringLiteral("action"));
        QCOMPARE(r.events.at(4).first, QStringLiteral("done"));
        QCOMPARE(r.events.at(4).second.value("message_id").toInt(), 9);

        // The request: POST to the function, as the device, asking for a stream.
        QVERIFY(m_lastRequest.startsWith("POST /functions/v1/assistant HTTP/1.1"));
        const QByteArray lower = m_lastRequest.toLower();
        QVERIFY(lower.contains("accept: text/event-stream"));
        QVERIFY(m_lastRequest.contains("Bearer access-token"));
        QVERIFY(lower.contains("apikey: anon-key"));
        const QJsonObject sent = QJsonDocument::fromJson(m_lastRequest.mid(m_lastRequest.indexOf("\r\n\r\n") + 4)).object();
        QCOMPARE(sent.value("mode").toString(), QStringLiteral("quick"));
        QCOMPARE(sent.value("stream").toBool(), true);
    }

    void httpErrorReportsMessageAndStatus()
    {
        const QByteArray json = "{\"error\":\"thread not found\"}";
        m_response = {"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: "
                          + QByteArray::number(json.size()) + "\r\nConnection: close",
                      {json}};
        SupabaseClient client(baseUrl(), "anon-key");
        Result r;
        run(client, r);
        QCOMPARE(r.events.size(), 0);
        QCOMPARE(r.error, QStringLiteral("thread not found (HTTP 404)"));
    }

    void plainJsonReplyBecomesDone()
    {
        const QByteArray json = "{\"reply\":\"Hi!\",\"actions\":[],\"thread_id\":\"t2\",\"message_id\":3}";
        m_response = {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                          + QByteArray::number(json.size()) + "\r\nConnection: close",
                      {json.left(10), json.mid(10)}};
        SupabaseClient client(baseUrl(), "anon-key");
        Result r;
        run(client, r);
        QCOMPARE(r.error, QString());
        QCOMPARE(r.events.size(), 1);
        QCOMPARE(r.events.first().first, QStringLiteral("done"));
        QCOMPARE(r.events.first().second.value("reply").toString(), QStringLiteral("Hi!"));
    }

    void abortStopsDelivery()
    {
        // Several events in one chunk; the caller aborts on the first one.
        m_response = {"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close",
                      {"event: delta\ndata: {\"text\":\"a\"}\n\nevent: delta\ndata: {\"text\":\"b\"}\n\n",
                       "event: done\ndata: {\"reply\":\"ab\"}\n\n"},
                      false};
        SupabaseClient client(baseUrl(), "anon-key");
        Result r;
        run(client, r, [](QNetworkReply *reply, Result &) { reply->abort(); });
        QCOMPARE(r.events.size(), 1);
        QCOMPARE(r.finishCount, 1);
        QVERIFY(!r.error.isEmpty());
    }

    void connectionRefused()
    {
        QTcpServer probe;
        QVERIFY(probe.listen(QHostAddress::LocalHost));
        const quint16 port = probe.serverPort();
        probe.close();
        SupabaseClient client(QUrl(QStringLiteral("http://127.0.0.1:%1").arg(port)), "anon-key");
        Result r;
        run(client, r);
        QCOMPARE(r.events.size(), 0);
        QVERIFY(r.error.contains("(HTTP 0)"));
    }
};

QTEST_GUILESS_MAIN(TestStreamFunction)
#include "tst_streamfunction.moc"
