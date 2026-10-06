#include "SupabaseClient.h"

#include <QJsonArray>
#include <QNetworkReply>
#include <QNetworkRequest>

SupabaseClient::SupabaseClient(const QUrl &baseUrl, const QString &anonKey, QObject *parent)
    : QObject(parent), m_baseUrl(baseUrl), m_anonKey(anonKey)
{
}

bool SupabaseClient::isConfigured() const
{
    return m_baseUrl.isValid() && !m_baseUrl.isEmpty() && !m_anonKey.isEmpty();
}

void SupabaseClient::setSession(const QString &accessToken, const QString &refreshToken)
{
    m_accessToken = accessToken;
    m_refreshToken = refreshToken;
    emit sessionChanged();
}

void SupabaseClient::clearSession()
{
    m_accessToken.clear();
    m_refreshToken.clear();
    emit sessionChanged();
}

QNetworkRequest SupabaseClient::request(const QString &path, const QUrlQuery &query) const
{
    QUrl url = m_baseUrl;
    url.setPath(url.path() + path);
    if (!query.isEmpty())
        url.setQuery(query);

    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("apikey", m_anonKey.toUtf8());
    const QString bearer = m_accessToken.isEmpty() ? m_anonKey : m_accessToken;
    req.setRawHeader("Authorization", "Bearer " + bearer.toUtf8());
    req.setTransferTimeout(15000);
    return req;
}

void SupabaseClient::handle(QNetworkReply *reply, Callback cb)
{
    connect(reply, &QNetworkReply::finished, this, [this, reply, cb]() {
        reply->deleteLater();
        const QByteArray body = reply->readAll();
        const QJsonDocument doc = QJsonDocument::fromJson(body);
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();

        if (reply->error() == QNetworkReply::NoError) {
            cb(doc, {});
            return;
        }
        QString message = doc.object().value("message").toString();
        if (message.isEmpty())
            message = doc.object().value("error").toString();
        if (message.isEmpty())
            message = reply->errorString();
        if (status == 401)
            m_accessToken.clear(); // FamilyStore refreshes and retries on the next sync
        cb(doc, QStringLiteral("%1 (HTTP %2)").arg(message).arg(status));
    });
}

void SupabaseClient::refreshSession(std::function<void(bool)> done)
{
    if (m_refreshToken.isEmpty()) {
        done(false);
        return;
    }
    QUrlQuery q;
    q.addQueryItem("grant_type", "refresh_token");
    QNetworkRequest req = request("/auth/v1/token", q);
    req.setRawHeader("Authorization", "Bearer " + m_anonKey.toUtf8());
    const QJsonObject body{{"refresh_token", m_refreshToken}};

    handle(m_nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact)),
           [this, done](const QJsonDocument &doc, const QString &error) {
               if (!error.isEmpty()) {
                   qWarning() << "session refresh failed:" << error;
                   // A 4xx means the token is dead; network errors are retried later.
                   if (error.contains("HTTP 400") || error.contains("HTTP 401"))
                       emit sessionLost();
                   done(false);
                   return;
               }
               setSession(doc.object().value("access_token").toString(),
                          doc.object().value("refresh_token").toString());
               done(true);
           });
}

void SupabaseClient::select(const QString &table, const QUrlQuery &query, Callback cb)
{
    handle(m_nam.get(request("/rest/v1/" + table, query)), cb);
}

void SupabaseClient::insert(const QString &table, const QJsonObject &row, Callback cb)
{
    QNetworkRequest req = request("/rest/v1/" + table);
    req.setRawHeader("Prefer", "return=representation");
    handle(m_nam.post(req, QJsonDocument(row).toJson(QJsonDocument::Compact)), cb);
}

void SupabaseClient::update(const QString &table, const QUrlQuery &filter, const QJsonObject &patch, Callback cb)
{
    QNetworkRequest req = request("/rest/v1/" + table, filter);
    req.setRawHeader("Prefer", "return=representation");
    handle(m_nam.sendCustomRequest(req, "PATCH", QJsonDocument(patch).toJson(QJsonDocument::Compact)), cb);
}

void SupabaseClient::rpc(const QString &function, const QJsonObject &args, Callback cb)
{
    handle(m_nam.post(request("/rest/v1/rpc/" + function), QJsonDocument(args).toJson(QJsonDocument::Compact)), cb);
}

void SupabaseClient::callFunction(const QString &name, const QJsonObject &body, Callback cb)
{
    handle(m_nam.post(request("/functions/v1/" + name), QJsonDocument(body).toJson(QJsonDocument::Compact)), cb);
}

void SupabaseClient::signUrls(const QString &bucket, const QStringList &paths, int expiresInSec,
                              std::function<void(const QStringList &)> done)
{
    if (paths.isEmpty()) {
        done({});
        return;
    }
    const QJsonObject body{{"expiresIn", expiresInSec}, {"paths", QJsonArray::fromStringList(paths)}};
    handle(m_nam.post(request("/storage/v1/object/sign/" + bucket), QJsonDocument(body).toJson(QJsonDocument::Compact)),
           [this, done](const QJsonDocument &doc, const QString &error) {
               QStringList urls;
               if (!error.isEmpty()) {
                   qWarning() << "signing media URLs failed:" << error;
                   done(urls);
                   return;
               }
               const QString storageRoot = m_baseUrl.toString() + "/storage/v1";
               for (const QJsonValue &v : doc.array()) {
                   const QString signedPath = v.toObject().value("signedURL").toString();
                   urls << (signedPath.isEmpty() ? QString() : storageRoot + signedPath);
               }
               done(urls);
           });
}
