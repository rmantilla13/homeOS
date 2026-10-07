#pragma once

#include <QColor>
#include <QElapsedTimer>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QSet>

// Finds a representative color for an image (local file, qrc or http) in the
// background, for the "dynamic colors" that tint the media viewer and photo
// frame to match the photo on screen. Results are cached per key: a media
// id, since signed URLs change each time they're renewed.
class ColorSampler : public QObject
{
    Q_OBJECT
public:
    explicit ColorSampler(QObject *parent = nullptr);

    // Cached color, or an invalid QColor if not sampled yet.
    QColor cached(const QString &key) const { return m_cache.value(key); }
    // Samples the image at `url` once per key. A URL that failed is tried
    // again after a few minutes; a new URL for the same key right away.
    void sample(const QString &key, const QString &url);
    // Forgets every color (another family's photos after re-pairing).
    void clear();

    // Average of the image, nudged toward a usable accent (more saturated,
    // mid lightness) so pale or very dark photos still give a visible tint.
    static QColor representative(const QImage &image);

signals:
    void sampled(const QString &key, const QColor &color);

private:
    void finish(const QString &key, const QString &url, const QColor &color);

    QNetworkAccessManager m_nam;
    QHash<QString, QColor> m_cache;
    struct Failure {
        QString url;
        qint64 at = 0; // m_clock time
    };
    QHash<QString, Failure> m_failed; // key -> URL that gave no color, and when
    QElapsedTimer m_clock;
    QSet<QString> m_pending;           // keys being sampled
    int m_generation = 0;              // bumped by clear(); late results are dropped
};
