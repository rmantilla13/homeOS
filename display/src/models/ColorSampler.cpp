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

void ColorSampler::sample(const QString &url)
{
    if (url.isEmpty() || m_cache.contains(url) || m_pending.contains(url))
        return;
    m_pending.insert(url);

    const QUrl u(url);
    if (u.scheme() == "http" || u.scheme() == "https") {
        QNetworkReply *reply = m_nam.get(QNetworkRequest(u));
        connect(reply, &QNetworkReply::finished, this, [this, reply, url]() {
            reply->deleteLater();
            if (reply->error() != QNetworkReply::NoError) {
                finish(url, QColor());
                return;
            }
            auto *watcher = new QFutureWatcher<QColor>(this);
            connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, url]() {
                finish(url, watcher->result());
                watcher->deleteLater();
            });
            watcher->setFuture(QtConcurrent::run(sampleBytes, reply->readAll()));
        });
        return;
    }

    const QString path = u.isLocalFile() ? u.toLocalFile() : (u.scheme() == "qrc" ? ":" + u.path() : url);
    auto *watcher = new QFutureWatcher<QColor>(this);
    connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, url]() {
        finish(url, watcher->result());
        watcher->deleteLater();
    });
    watcher->setFuture(QtConcurrent::run(sampleFile, path));
}

void ColorSampler::finish(const QString &url, const QColor &color)
{
    m_pending.remove(url);
    m_cache.insert(url, color);
    if (color.isValid())
        emit sampled(url, color);
}
