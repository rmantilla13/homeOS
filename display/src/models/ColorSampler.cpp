#include "ColorSampler.h"

#include <QFutureWatcher>
#include <QImage>
#include <QNetworkReply>
#include <QUrl>
#include <QtConcurrent/QtConcurrentRun>

namespace {
QColor sampleFile(const QString &path)
{
    QImage image(path);
    return image.isNull() ? QColor() : ColorSampler::representative(image);
}
QColor sampleBytes(const QByteArray &bytes)
{
    QImage image;
    image.loadFromData(bytes);
    return image.isNull() ? QColor() : ColorSampler::representative(image);
}
} // namespace

ColorSampler::ColorSampler(QObject *parent) : QObject(parent) {}

QColor ColorSampler::representative(const QImage &image)
{
    // Averaging a small thumbnail is cheap and stable.
    const QImage small = image.scaled(24, 24, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
                             .convertToFormat(QImage::Format_RGB32);
    qint64 r = 0, g = 0, b = 0;
    const int n = small.width() * small.height();
    for (int y = 0; y < small.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(small.constScanLine(y));
        for (int x = 0; x < small.width(); ++x) {
            r += qRed(line[x]);
            g += qGreen(line[x]);
            b += qBlue(line[x]);
        }
    }
    QColor avg(int(r / n), int(g / n), int(b / n));
    float h, s, l;
    avg.getHslF(&h, &s, &l);
    return QColor::fromHslF(h < 0 ? 0 : h, qBound(0.35f, s * 1.7f, 0.85f), qBound(0.40f, l, 0.60f));
}

void ColorSampler::sample(const QString &key, const QString &url)
{
    if (key.isEmpty() || url.isEmpty() || m_cache.contains(key) || m_pending.contains(key)
        || m_failed.value(key) == url)
        return;
    m_pending.insert(key);
    const int generation = m_generation;

    const QUrl u(url);
    if (u.scheme() == "http" || u.scheme() == "https") {
        QNetworkReply *reply = m_nam.get(QNetworkRequest(u));
        connect(reply, &QNetworkReply::finished, this, [this, reply, key, url, generation]() {
            reply->deleteLater();
            if (generation != m_generation)
                return;
            if (reply->error() != QNetworkReply::NoError) {
                finish(key, url, QColor());
                return;
            }
            auto *watcher = new QFutureWatcher<QColor>(this);
            connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, key, url, generation]() {
                if (generation == m_generation)
                    finish(key, url, watcher->result());
                watcher->deleteLater();
            });
            watcher->setFuture(QtConcurrent::run(sampleBytes, reply->readAll()));
        });
        return;
    }

    const QString path = u.isLocalFile() ? u.toLocalFile() : (u.scheme() == "qrc" ? ":" + u.path() : url);
    auto *watcher = new QFutureWatcher<QColor>(this);
    connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, key, url, generation]() {
        if (generation == m_generation)
            finish(key, url, watcher->result());
        watcher->deleteLater();
    });
    watcher->setFuture(QtConcurrent::run(sampleFile, path));
}

void ColorSampler::clear()
{
    ++m_generation;
    m_cache.clear();
    m_failed.clear();
    m_pending.clear();
}

void ColorSampler::finish(const QString &key, const QString &url, const QColor &color)
{
    m_pending.remove(key);
    if (!color.isValid()) {
        m_failed.insert(key, url);
        return;
    }
    m_failed.remove(key);
    m_cache.insert(key, color);
    emit sampled(key, color);
}
