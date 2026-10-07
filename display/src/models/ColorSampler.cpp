#include "ColorSampler.h"

#include <QBuffer>
#include <QFutureWatcher>
#include <QImage>
#include <QImageReader>
#include <QNetworkReply>
#include <QUrl>
#include <QtConcurrent/QtConcurrentRun>

namespace {
constexpr int kRetryAfterMs = 10 * 60 * 1000;
constexpr int kTimeoutMs = 30 * 1000;

// Decodes at about 64 px: the color is an average anyway, and JPEG scales
// while it decodes, so a 2560 px photo costs little memory or time.
QColor sampleReader(QImageReader &reader)
{
    const QSize size = reader.size();
    if (size.isValid() && (size.width() > 64 || size.height() > 64))
        reader.setScaledSize(size.scaled(64, 64, Qt::KeepAspectRatioByExpanding));
    const QImage image = reader.read();
    return image.isNull() ? QColor() : ColorSampler::representative(image);
}
QColor sampleFile(const QString &path)
{
    QImageReader reader(path);
    return sampleReader(reader);
}
QColor sampleBytes(const QByteArray &bytes)
{
    QBuffer buffer;
    buffer.setData(bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    return sampleReader(reader);
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
    if (key.isEmpty() || url.isEmpty() || m_cache.contains(key) || m_pending.contains(key))
        return;
    const auto retry = m_retryAt.constFind(key);
    if (retry != m_retryAt.cend() && !retry->hasExpired())
        return;
    m_pending.insert(key);
    const int generation = m_generation;

    const QUrl u(url);
    if (u.scheme() == "http" || u.scheme() == "https") {
        QNetworkRequest request(u);
        request.setTransferTimeout(kTimeoutMs);
        QNetworkReply *reply = m_nam.get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply, key, generation]() {
            reply->deleteLater();
            if (reply->error() != QNetworkReply::NoError) {
                finish(key, QColor(), generation);
                return;
            }
            auto *watcher = new QFutureWatcher<QColor>(this);
            connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, key, generation]() {
                finish(key, watcher->result(), generation);
                watcher->deleteLater();
            });
            watcher->setFuture(QtConcurrent::run(sampleBytes, reply->readAll()));
        });
        return;
    }

    const QString path = u.isLocalFile() ? u.toLocalFile() : (u.scheme() == "qrc" ? ":" + u.path() : url);
    auto *watcher = new QFutureWatcher<QColor>(this);
    connect(watcher, &QFutureWatcher<QColor>::finished, this, [this, watcher, key, generation]() {
        finish(key, watcher->result(), generation);
        watcher->deleteLater();
    });
    watcher->setFuture(QtConcurrent::run(sampleFile, path));
}

void ColorSampler::clear()
{
    ++m_generation;
    m_cache.clear();
    m_pending.clear();
    m_retryAt.clear();
}

void ColorSampler::finish(const QString &key, const QColor &color, int generation)
{
    if (generation != m_generation)
        return; // cleared meanwhile
    m_pending.remove(key);
    if (!color.isValid()) {
        m_retryAt.insert(key, QDeadlineTimer(kRetryAfterMs));
        return;
    }
    m_retryAt.remove(key);
    m_cache.insert(key, color);
    emit sampled(key, color);
}
