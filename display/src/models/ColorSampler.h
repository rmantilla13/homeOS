#pragma once

#include <QColor>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QSet>

// Finds a representative color for an image (local file, qrc or http) in the
// background, for the "dynamic colors" that tint the media viewer and photo
// frame to match the photo on screen. Results are cached per URL.
class ColorSampler : public QObject
{
    Q_OBJECT
public:
    explicit ColorSampler(QObject *parent = nullptr);

    // Cached color, or an invalid QColor if not sampled yet.
    QColor cached(const QString &url) const { return m_cache.value(url); }
    void sample(const QString &url);

    // Average of the image, nudged toward a usable accent (more saturated,
    // mid lightness) so pale or very dark photos still give a visible tint.
    static QColor representative(const QImage &image);

signals:
    void sampled(const QString &url, const QColor &color);

private:
    void finish(const QString &url, const QColor &color);

    QNetworkAccessManager m_nam;
    QHash<QString, QColor> m_cache;
    QSet<QString> m_pending;
};
