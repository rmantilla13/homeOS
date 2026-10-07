#include <QtTest>

#include <QBuffer>
#include <QImage>
#include <QJsonArray>
#include <QNetworkProxy>
#include <QSettings>

#include "FakeServer.h"
#include "backend/SupabaseClient.h"
#include "models/ColorSampler.h"
#include "models/FamilyStore.h"

// Media in live mode, against a fake Supabase and admin app: signed URLs
// are kept and reused between refreshes, posters stand in for videos and
// small tiles, and colors are sampled once per file.
class TestMedia : public QObject
{
    Q_OBJECT

    using Request = FakeServer::Request;
    FakeServer m_server;
    const QString m_family = QStringLiteral("f0000000-0000-4000-8000-000000000001");

    QJsonArray m_rows;        // /rest/v1/media_items
    QByteArray m_pictureBytes; // every photo and poster
    int m_blobSigns = 0;      // numbers the answers: ?sig=N
    int m_storageSigns = 0;   // ?token=N
    int m_signStatus = 200;   // both signers
    int m_blobDelayMs = 0;
    bool m_oldAdmin = false;  // /api/media/urls answers "" for posters
    QSet<QString> m_missing;  // Storage objects that don't exist

    struct Rig
    {
        explicit Rig(const QUrl &url) : client(url, "anon-key"), store(&client, false) {}
        SupabaseClient client;
        FamilyStore store;
    };

    QJsonObject row(const QString &id, const QString &kind, const QString &where, bool poster, int hoursAgo,
                    const QString &ext = {}) const
    {
        const QString file = m_family + '/' + id + '.' + (ext.isEmpty() ? (kind == "video" ? "mp4" : "jpg") : ext);
        return {{"id", id},
                {"family_id", m_family},
                {"kind", kind},
                {"file_store", where},
                {"storage_path", file},
                {"thumbnail_path", poster ? QJsonValue(m_family + '/' + id + "-thumb.jpg") : QJsonValue()},
                {"duration_seconds", kind == "video" ? QJsonValue(42) : QJsonValue()},
                {"show_on_frame", true},
                {"taken_at", QDateTime::currentDateTimeUtc().addSecs(-3600 * hoursAgo).toString(Qt::ISODate)}};
    }
    QString file(const QString &id, const QString &ext) const { return m_family + '/' + id + '.' + ext; }
    QString poster(const QString &id) const { return m_family + '/' + id + "-thumb.jpg"; }

    // Photos and videos in Blob (with and without posters), and older ones
    // still in Supabase Storage, one of them with a poster that is gone.
    void defaultRows()
    {
        m_rows = QJsonArray{row("p1", "photo", "blob", true, 1),
                            row("p2", "photo", "blob", true, 2),
                            row("v1", "video", "blob", true, 3),
                            row("p3", "photo", "blob", false, 4),
                            row("v2", "video", "blob", false, 5, "mov"),
                            row("s1", "photo", "storage", false, 6),
                            row("s2", "photo", "storage", true, 7),
                            row("s3", "photo", "storage", true, 8)};
        m_missing = {poster("s3")};
    }

    std::unique_ptr<Rig> started()
    {
        auto rig = std::make_unique<Rig>(m_server.baseUrl());
        rig->client.setRefreshToken("refresh-0");
        rig->store.setMediaApiUrl(m_server.baseUrl().toString() + "/");
        rig->store.start();
        settle();
        return rig;
    }

    // Waits until every request is answered and nothing new has come in for
    // a while: signing, color samples and rebuilds are then done.
    void settle()
    {
        QElapsedTimer total;
        total.start();
        while (total.elapsed() < 10000) {
            const qsizetype seen = m_server.requests().size();
            QTest::qWait(250);
            if (m_server.pending() == 0 && m_server.requests().size() == seen)
                return;
        }
        qWarning() << "the fake server never went quiet";
    }
    void refreshAndSettle(FamilyStore &store)
    {
        store.refresh();
        settle();
    }

    QList<Request> blobSignPosts() const { return m_server.requests("POST", "/api/media/urls"); }
    QList<Request> storageSignPosts() const { return m_server.requests("POST", "/storage/v1/object/sign/"); }
    // Downloads of pictures (the color sampler; QML isn't loaded here).
    QStringList downloads() const
    {
        QStringList out;
        for (const Request &r : m_server.requests()) {
            const QString path = QString::fromUtf8(r.pathOnly());
            if (r.method == "GET" && (path.startsWith("/blob/") || path.startsWith("/storage/v1/object/sign/")))
                out << path.mid(path.indexOf(m_family));
        }
        return out;
    }

    static QVariantMap item(const FamilyStore &store, const QString &id)
    {
        for (const QVariant &v : store.media())
            if (v.toMap().value("id").toString() == id)
                return v.toMap();
        return {};
    }
    static QStringList field(const QVariantList &items, const char *name)
    {
        QStringList out;
        for (const QVariant &v : items)
            out << v.toMap().value(QLatin1String(name)).toString();
        return out;
    }

private slots:
    void initTestCase()
    {
        QCoreApplication::setOrganizationName("homeOS-tests");
        QCoreApplication::setApplicationName("tst_media");
        QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
        QVERIFY(m_server.listen());

        QImage picture(32, 24, QImage::Format_RGB32);
        picture.fill(QColor("#C0503A"));
        QBuffer buffer(&m_pictureBytes);
        buffer.open(QIODevice::WriteOnly);
        if (!picture.save(&buffer, "JPG")) // no JPEG plugin: any format will do
            QVERIFY(picture.save(&buffer, "PNG"));
    }

    void init()
    {
        QSettings().clear();
        m_server.reset();
        m_blobSigns = m_storageSigns = 0;
        m_signStatus = 200;
        m_blobDelayMs = 0;
        m_oldAdmin = false;
        defaultRows();

        m_server.route("/auth/v1/token", [](const Request &) {
            return FakeServer::json("{\"access_token\":\"access-1\",\"refresh_token\":\"refresh-1\"}");
        });
        m_server.route("/rest/v1/families", [](const Request &) { return FakeServer::json("[{\"name\":\"Test Family\"}]"); });
        m_server.route("/rest/v1/media_items", [this](const Request &) { return FakeServer::json(QJsonDocument(m_rows)); });
        m_server.route("/api/media/urls", [this](const Request &r) {
            if (m_signStatus != 200)
                return FakeServer::json("{\"error\":\"Couldn't sign\"}", m_signStatus);
            const int n = ++m_blobSigns;
            QJsonArray urls;
            for (const QJsonValue &p : r.body.value("paths").toArray()) {
                const QString path = p.toString();
                urls << (m_oldAdmin && path.endsWith("-thumb.jpg")
                             ? QString()
                             : QStringLiteral("%1/blob/%2?sig=%3").arg(m_server.baseUrl().toString(), path).arg(n));
            }
            return FakeServer::json(QJsonDocument(QJsonObject{{"urls", urls}}), 200, m_blobDelayMs);
        });
        m_server.route("/blob/", [this](const Request &) { return FakeServer::Reply{200, "image/jpeg", m_pictureBytes, 0}; });
        // Storage: POST signs, GET downloads.
        m_server.route("/storage/v1/object/sign/family-media", [this](const Request &r) {
            if (r.method == "GET")
                return FakeServer::Reply{200, "image/jpeg", m_pictureBytes, 0};
            if (m_signStatus != 200)
                return FakeServer::json("{\"error\":\"Couldn't sign\"}", m_signStatus);
            const int n = ++m_storageSigns;
            QJsonArray out;
            for (const QJsonValue &p : r.body.value("paths").toArray()) {
                const QString path = p.toString();
                if (m_missing.contains(path))
                    out << QJsonObject{{"error", "Object not found"}, {"path", path}, {"signedURL", QJsonValue()}};
                else
                    out << QJsonObject{{"error", QJsonValue()},
                                       {"path", path},
                                       {"signedURL", QStringLiteral("/object/sign/family-media/%1?token=%2").arg(path).arg(n)}};
            }
            return FakeServer::json(QJsonDocument(out));
        });
    }

    // Let requests a test left in flight finish before the next one.
    void cleanup() { QTest::qWait(100); }

    void cleanupTestCase() { QSettings().clear(); }

    void urlsAreReusedAcrossRefreshes()
    {
        auto rig = started();
        const QVariantList first = rig->store.media();
        QCOMPARE(first.size(), 8);
        QCOMPARE(blobSignPosts().size(), 1);
        QCOMPARE(storageSignPosts().size(), 1);
        QVERIFY(!item(rig->store, "p1").value("url").toString().isEmpty());
        QVERIFY(!item(rig->store, "s1").value("url").toString().isEmpty());

        // Nothing changed, so nothing is signed again and the media list
        // doesn't notify (the rest of the store still does).
        QSignalSpy media(&rig->store, &FamilyStore::mediaChanged);
        QSignalSpy data(&rig->store, &FamilyStore::dataChanged);
        for (int i = 0; i < 3; ++i)
            refreshAndSettle(rig->store);
        QCOMPARE(m_server.requests("GET", "/rest/v1/media_items").size(), 4);
        QCOMPARE(blobSignPosts().size(), 1);
        QCOMPARE(storageSignPosts().size(), 1);
        QCOMPARE(field(rig->store.media(), "url"), field(first, "url"));
        QCOMPARE(field(rig->store.media(), "thumbUrl"), field(first, "thumbUrl"));
        QCOMPARE(rig->store.media(), first);
        QCOMPARE(media.size(), 0);
        QVERIFY(data.size() > 0);
    }

    void resignsAfterRefreshWindow()
    {
        auto rig = started();
        const QStringList before = field(rig->store.media(), "url");
        QVERIFY(item(rig->store, "p1").value("url").toString().endsWith("?sig=1"));

        // Shortens the URLs already signed too.
        rig->store.setUrlRefreshAfterMs(0);
        refreshAndSettle(rig->store);
        QCOMPARE(blobSignPosts().size(), 2);
        QCOMPARE(storageSignPosts().size(), 2);
        QVERIFY(item(rig->store, "p1").value("url").toString().endsWith("?sig=2"));
        QVERIFY(item(rig->store, "v1").value("thumbUrl").toString().endsWith("?sig=2"));
        QVERIFY(item(rig->store, "s1").value("url").toString().endsWith("?token=2"));
        QVERIFY(field(rig->store.media(), "url") != before);
    }

    void failedSigningKeepsUrls()
    {
        auto rig = started();
        const QVariantList before = rig->store.media();
        rig->store.setUrlRefreshAfterMs(0);
        m_signStatus = 502;
        refreshAndSettle(rig->store);
        QCOMPARE(blobSignPosts().size(), 2); // it did try
        QCOMPARE(storageSignPosts().size(), 2);
        QCOMPARE(field(rig->store.media(), "url"), field(before, "url"));
        QCOMPARE(field(rig->store.media(), "thumbUrl"), field(before, "thumbUrl"));
        for (const QString &url : field(rig->store.media(), "url"))
            QVERIFY(!url.isEmpty());
    }

    void oldUrlsAreDroppedWhenSigningKeepsFailing()
    {
        auto rig = started();
        rig->store.setUrlRefreshAfterMs(0);
        rig->store.setUrlDropAfterMs(0); // as if they were 5.5 h old
        m_signStatus = 502;
        QSignalSpy media(&rig->store, &FamilyStore::mediaChanged);
        refreshAndSettle(rig->store);
        // Expired URLs would only fail to load: show nothing instead.
        for (const QString &url : field(rig->store.media(), "url"))
            QCOMPARE(url, QString());
        for (const QString &url : field(rig->store.media(), "thumbUrl"))
            QCOMPARE(url, QString());
        QVERIFY(media.size() > 0);

        // Signing works again: everything comes back.
        rig->store.setUrlDropAfterMs(qint64(5.5 * 3600 * 1000));
        m_signStatus = 200;
        refreshAndSettle(rig->store);
        QVERIFY(item(rig->store, "p1").value("url").toString().endsWith("?sig=2"));
        QVERIFY(item(rig->store, "s1").value("url").toString().endsWith("?token=2"));
    }

    void postersFeedImageTileAndColor()
    {
        auto rig = started();

        // A video: its poster is the placeholder, the tile and the tint source.
        const QVariantMap v1 = item(rig->store, "v1");
        const QString v1Poster = v1.value("thumbUrl").toString();
        QVERIFY(v1Poster.endsWith(poster("v1") + "?sig=1"));
        QCOMPARE(v1.value("posterUrl").toString(), v1Poster);
        QCOMPARE(v1.value("imageUrl").toString(), v1Poster);
        QCOMPARE(v1.value("tileUrl").toString(), v1Poster);
        QVERIFY(v1.value("url").toString().endsWith(file("v1", "mp4") + "?sig=1"));

        // A photo: the full picture to view, the poster for small tiles.
        const QVariantMap p1 = item(rig->store, "p1");
        QVERIFY(p1.value("url").toString().endsWith(file("p1", "jpg") + "?sig=1"));
        QCOMPARE(p1.value("imageUrl").toString(), p1.value("url").toString());
        QCOMPARE(p1.value("tileUrl").toString(), p1.value("thumbUrl").toString());
        QVERIFY(p1.value("tileUrl").toString().endsWith(poster("p1") + "?sig=1"));

        // Posters of rows still in Supabase Storage are signed there.
        const QVariantMap s2 = item(rig->store, "s2");
        QVERIFY(s2.value("thumbUrl").toString().contains("/storage/v1/object/sign/family-media/" + poster("s2")));
        QCOMPARE(s2.value("tileUrl").toString(), s2.value("thumbUrl").toString());
        // A Storage poster that is gone: the photo itself again.
        const QVariantMap s3 = item(rig->store, "s3");
        QCOMPARE(s3.value("thumbUrl").toString(), QString());
        QVERIFY(!s3.value("url").toString().isEmpty());
        QCOMPARE(s3.value("tileUrl").toString(), s3.value("url").toString());

        // Colors come from the small posters (or the photo when there is
        // none), never from a video file, each fetched once.
        const QStringList expected{poster("p1"), poster("p2"), poster("v1"), file("p3", "jpg"),
                                   file("s1", "jpg"), poster("s2"), file("s3", "jpg")};
        QStringList got = downloads();
        got.sort();
        QStringList want = expected;
        want.sort();
        QCOMPARE(got, want);
        const QString tint = ColorSampler::representative(QImage::fromData(m_pictureBytes)).name();
        QCOMPARE(item(rig->store, "v1").value("tint").toString(), tint);
        QCOMPARE(item(rig->store, "p1").value("tint").toString(), tint);
        QCOMPARE(item(rig->store, "s3").value("tint").toString(), tint);

        // A refresh used to download every photo again.
        for (int i = 0; i < 3; ++i)
            refreshAndSettle(rig->store);
        got = downloads();
        got.sort();
        QCOMPARE(got, want);
    }

    void legacyRowsUnchanged()
    {
        auto rig = started();
        // An older video with no poster: no picture until it plays.
        const QVariantMap v2 = item(rig->store, "v2");
        QVERIFY(v2.value("url").toString().endsWith(file("v2", "mov") + "?sig=1"));
        QCOMPARE(v2.value("thumbUrl").toString(), QString());
        QCOMPARE(v2.value("posterUrl").toString(), QString());
        QCOMPARE(v2.value("imageUrl").toString(), QString());
        QCOMPARE(v2.value("tileUrl").toString(), QString());
        // A photo with no poster: the photo everywhere.
        const QVariantMap p3 = item(rig->store, "p3");
        QVERIFY(!p3.value("url").toString().isEmpty());
        QCOMPARE(p3.value("thumbUrl").toString(), QString());
        QCOMPARE(p3.value("imageUrl").toString(), p3.value("url").toString());
        QCOMPARE(p3.value("tileUrl").toString(), p3.value("url").toString());
    }

    void blobPathsAreChunked()
    {
        m_rows = QJsonArray();
        for (int i = 0; i < 150; ++i)
            m_rows << row(QStringLiteral("b%1").arg(i, 3, 10, QChar('0')), "photo", "blob", true, i);
        auto rig = started();
        const QList<Request> posts = blobSignPosts();
        QCOMPARE(posts.size(), 2);
        qsizetype total = 0;
        for (const Request &r : posts) {
            QVERIFY(r.body.value("paths").toArray().size() <= 200);
            total += r.body.value("paths").toArray().size();
        }
        QCOMPARE(total, qsizetype(300));
        QCOMPARE(rig->store.media().size(), 150);
        for (const QVariant &v : rig->store.media()) {
            QVERIFY(!v.toMap().value("url").toString().isEmpty());
            QVERIFY(!v.toMap().value("thumbUrl").toString().isEmpty());
        }
    }

    void emptyPosterUrlNotRetriedEveryRefresh()
    {
        m_oldAdmin = true; // can't sign "-thumb.jpg" names yet
        auto rig = started();
        const QVariantMap p1 = item(rig->store, "p1");
        QCOMPARE(p1.value("thumbUrl").toString(), QString());
        QCOMPARE(p1.value("tileUrl").toString(), p1.value("url").toString());
        QCOMPARE(item(rig->store, "v1").value("imageUrl").toString(), QString());

        refreshAndSettle(rig->store);
        QCOMPARE(blobSignPosts().size(), 1);

        // It is asked again later (15 min, here at once).
        m_oldAdmin = false;
        rig->store.setUrlRefreshAfterMs(0);
        refreshAndSettle(rig->store);
        QCOMPARE(blobSignPosts().size(), 2);
        QVERIFY(item(rig->store, "p1").value("thumbUrl").toString().endsWith(poster("p1") + "?sig=2"));
    }

    void overlappingLoadsSignOnce()
    {
        auto rig = started();
        // A chore tick and the minute refresh close together, while a new
        // video's URLs are still being signed.
        m_rows.prepend(row("v3", "video", "blob", true, 0));
        m_blobDelayMs = 400;
        rig->store.refresh();
        rig->store.refresh();
        settle();
        const QList<Request> posts = blobSignPosts();
        QCOMPARE(posts.size(), 2);
        QCOMPARE(posts.last().body.value("paths").toArray().size(), 2);
        const QVariantMap v3 = item(rig->store, "v3");
        QVERIFY(v3.value("url").toString().endsWith(file("v3", "mp4") + "?sig=2"));
        QVERIFY(v3.value("thumbUrl").toString().endsWith(poster("v3") + "?sig=2"));
        // The others kept their first URLs.
        QVERIFY(item(rig->store, "p1").value("url").toString().endsWith("?sig=1"));
    }

    void unpairForgetsMedia()
    {
        auto rig = started();
        QVERIFY(!rig->store.media().isEmpty());
        QVERIFY(!rig->store.photos().isEmpty());
        QSignalSpy media(&rig->store, &FamilyStore::mediaChanged);
        rig->store.unpair();
        QCOMPARE(rig->store.media().size(), 0);
        QCOMPARE(rig->store.photos().size(), 0);
        QCOMPARE(media.size(), 1);
    }
};

QTEST_MAIN(TestMedia)
#include "tst_media.moc"
