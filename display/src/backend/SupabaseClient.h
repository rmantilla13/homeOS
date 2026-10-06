#pragma once

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QUrl>
#include <QUrlQuery>
#include <functional>

class QNetworkReply;

// Thin client for the Supabase REST APIs (PostgREST, RPC, Storage, Auth,
// Edge Functions). The display signs in as its own device user; the session
// comes from the pairing flow and is kept alive with the refresh token.
class SupabaseClient : public QObject
{
    Q_OBJECT
public:
    using Callback = std::function<void(const QJsonDocument &result, const QString &error)>;

    SupabaseClient(const QUrl &baseUrl, const QString &anonKey, QObject *parent = nullptr);

    bool isConfigured() const;
    bool hasSession() const { return !m_accessToken.isEmpty(); }
    QString refreshToken() const { return m_refreshToken; }
    void setRefreshToken(const QString &token) { m_refreshToken = token; }
    void setSession(const QString &accessToken, const QString &refreshToken);
    void clearSession();

    // Exchanges the refresh token for a new access token.
    void refreshSession(std::function<void(bool ok)> done);

    void select(const QString &table, const QUrlQuery &query, Callback cb);
    void insert(const QString &table, const QJsonObject &row, Callback cb);
    void update(const QString &table, const QUrlQuery &filter, const QJsonObject &patch, Callback cb);
    void rpc(const QString &function, const QJsonObject &args, Callback cb);
    void callFunction(const QString &name, const QJsonObject &body, Callback cb);

    // Returns signed URLs (absolute) for private storage objects, in order.
    void signUrls(const QString &bucket, const QStringList &paths, int expiresInSec,
                  std::function<void(const QStringList &urls)> done);

signals:
    // The refresh token rotated; persist it so the device stays signed in.
    void sessionChanged();
    // The refresh token was rejected; the device must be paired again.
    void sessionLost();

private:
    QNetworkRequest request(const QString &path, const QUrlQuery &query = {}) const;
    void handle(QNetworkReply *reply, Callback cb);

    QNetworkAccessManager m_nam;
    QUrl m_baseUrl;
    QString m_anonKey;
    QString m_accessToken;
    QString m_refreshToken;
};
