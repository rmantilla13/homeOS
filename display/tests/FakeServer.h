#pragma once

#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QPair>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>
#include <functional>
#include <memory>

// A small HTTP/1.1 stand-in for Supabase and the admin app, for tests that
// run the real SupabaseClient (the same server as in tst_assistant.cpp).
// Routes match by path prefix, the newest first; anything else answers
// 200 "[]". Every request is recorded.
class FakeServer
{
public:
    struct Request
    {
        QByteArray method;
        QByteArray path; // with the query
        QByteArray auth; // Authorization header
        QJsonObject body;
        QByteArray pathOnly() const { return path.left(path.indexOf('?') < 0 ? path.size() : path.indexOf('?')); }
    };
    struct Reply
    {
        int status = 200;
        QByteArray type = "application/json";
        QByteArray body;
        int delayMs = 0; // before the answer
    };
    using Route = std::function<Reply(const Request &)>;

    static Reply json(const QByteArray &body, int status = 200, int delayMs = 0)
    {
        return {status, "application/json", body, delayMs};
    }
    static Reply json(const QJsonDocument &doc, int status = 200, int delayMs = 0)
    {
        return json(doc.toJson(QJsonDocument::Compact), status, delayMs);
    }

    bool listen()
    {
        if (!m_server.listen(QHostAddress::LocalHost))
            return false;
        QObject::connect(&m_server, &QTcpServer::newConnection, &m_server, [this]() {
            while (QTcpSocket *socket = m_server.nextPendingConnection())
                accept(socket);
        });
        return true;
    }
    QUrl baseUrl() const { return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(m_server.serverPort())); }

    void route(const QByteArray &prefix, Route handler) { m_routes.prepend({prefix, handler}); }
    void reset()
    {
        m_routes.clear();
        m_requests.clear();
    }

    const QList<Request> &requests() const { return m_requests; }
    QList<Request> requests(const QByteArray &method, const QByteArray &prefix) const
    {
        QList<Request> out;
        for (const Request &r : m_requests)
            if (r.method == method && r.path.startsWith(prefix))
                out << r;
        return out;
    }
    // Requests that have not been answered yet.
    int pending() const { return m_pending; }

private:
    void accept(QTcpSocket *socket)
    {
        auto buffer = std::make_shared<QByteArray>();
        QObject::connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer]() {
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
            QObject::disconnect(socket, &QTcpSocket::readyRead, socket, nullptr);
            serve(socket, r);
        });
        QObject::connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
    }

    void serve(QTcpSocket *socket, const Request &request)
    {
        m_requests << request;
        ++m_pending;
        Reply reply = json("[]");
        for (const auto &[prefix, handler] : std::as_const(m_routes)) {
            if (request.path.startsWith(prefix)) {
                reply = handler(request);
                break;
            }
        }
        // The count goes down even if the client hung up first.
        QTimer::singleShot(reply.delayMs, &m_server, [this, socket = QPointer<QTcpSocket>(socket), reply]() {
            --m_pending;
            if (!socket)
                return;
            socket->write("HTTP/1.1 " + QByteArray::number(reply.status) + " X\r\nContent-Type: " + reply.type
                          + "\r\nContent-Length: " + QByteArray::number(reply.body.size())
                          + "\r\nConnection: close\r\n\r\n" + reply.body);
            socket->flush();
            socket->disconnectFromHost();
        });
    }

    QTcpServer m_server;
    QList<QPair<QByteArray, Route>> m_routes;
    QList<Request> m_requests;
    int m_pending = 0;
};
