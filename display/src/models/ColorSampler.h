#pragma once

#include <QColor>
#include <QDeadlineTimer>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QSet>

// Finds a representative color for an image (local file, qrc or http) in the
// background, for the "dynamic colors" that tint the media viewer and photo
// frame to match the photo on screen.
//
// Results are cached per key (the media row's storage path, or a demo file's
// URL), not per URL: a signed URL changes when it is signed again, but the
// picture does not.
class ColorSampler : public QObject
{
    Q_OBJECT
public:
    explicit ColorSampler(QObject *parent = nullptr);

    // Cached color, or an invalid QColor if not sampled yet.
    QColor cached(const QString &key) const { return m_cache.value(key); }
    // Downloads `url` and remembers its color under `key`. A failed key is
    // left alone for a while, so a broken URL isn't fetched on every rebuild;
    // a different URL for it (signed again, or its poster) is tried at once.
    void sample(const QString &key, const QString &url);
    // Forgets everything (re-pair). Answers still on their way are dropped.
    void clear();

    // Average of the image, nudged toward a usable accent (more saturated,
    // mid lightness) so pale or very dark photos still give a visible tint.
    static QColor representative(const QImage &image);

signals:
    void sampled(const QString &key, const QColor &color);

private:
    void finish(const QString &key, const QString &url, const QColor &color, int generation);

    QNetworkAccessManager m_nam;
    QHash<QString, QColor> m_cache;
    QSet<QString> m_pending;
    struct Retry
    {
        QString url;       // the URL that gave no color
        QDeadlineTimer at; // not fetched again before this
    };
    QHash<QString, Retry> m_retry; // failed keys
    int m_generation = 0;
};
