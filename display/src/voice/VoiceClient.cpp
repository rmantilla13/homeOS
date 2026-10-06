#include "VoiceClient.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSettings>

namespace {
constexpr int kRetryMs = 5000;
constexpr int kConnectTimeoutMs = 10000;
const QStringList kStates{"idle", "listening", "transcribing", "speaking"};
} // namespace

VoiceClient::VoiceClient(const QUrl &url, QObject *parent) : QObject(parent), m_url(url)
{
    m_speakReplies = QSettings().value("voice/speakReplies", true).toBool();

    m_retry.setSingleShot(true);
    m_retry.setInterval(kRetryMs);
    connect(&m_retry, &QTimer::timeout, this, &VoiceClient::connectNow);

    // Qt 6.4 has no handshake timeout; don't let a half-open connect hang forever.
    m_connectTimeout.setSingleShot(true);
    m_connectTimeout.setInterval(kConnectTimeoutMs);
    connect(&m_connectTimeout, &QTimer::timeout, this, [this]() {
        if (m_socket.state() != QAbstractSocket::ConnectedState)
            m_socket.abort();
        scheduleRetry();
    });

    connect(&m_socket, &QWebSocket::connected, this, &VoiceClient::onConnected);
    connect(&m_socket, &QWebSocket::disconnected, this, &VoiceClient::onDisconnected);
    // A refused connect only reports a state change on some Qt versions.
    connect(&m_socket, &QWebSocket::stateChanged, this, [this](QAbstractSocket::SocketState s) {
        if (s == QAbstractSocket::UnconnectedState)
            onDisconnected();
    });
    connect(&m_socket, &QWebSocket::textMessageReceived, this, &VoiceClient::onMessage);
}

VoiceClient::~VoiceClient()
{
    // Closing the socket emits signals; don't handle them half-destroyed.
    m_socket.disconnect(this);
    m_socket.abort();
}

void VoiceClient::start()
{
    if (!m_url.isValid() || m_url.isEmpty()) {
        qInfo() << "voice: no service URL; voice features are off";
        return;
    }
    connectNow();
}

void VoiceClient::connectNow()
{
    if (m_socket.state() != QAbstractSocket::UnconnectedState)
        return;
    m_connectTimeout.start();
    m_socket.open(m_url);
}

void VoiceClient::scheduleRetry()
{
    if (!m_retry.isActive())
        m_retry.start();
}

void VoiceClient::onConnected()
{
    m_connectTimeout.stop();
    m_loggedFailure = false;
    qInfo() << "voice: connected to" << m_url.toString();
    setAvailable(true);
}

void VoiceClient::onDisconnected()
{
    m_connectTimeout.stop();
    if (m_available) {
        qInfo() << "voice: service disconnected; reconnecting";
        m_loggedFailure = true;
    } else if (!m_loggedFailure) {
        // Log once, not every 5 s: the service is optional.
        qInfo().noquote() << QStringLiteral("voice: no service at %1 (%2); retrying every %3 s")
                                 .arg(m_url.toString(), m_socket.errorString())
                                 .arg(m_retry.interval() / 1000.0);
        m_loggedFailure = true;
    }
    setAvailable(false);
    setState(QStringLiteral("idle"));
    setLevel(0);
    scheduleRetry();
}

void VoiceClient::onMessage(const QString &text)
{
    const QJsonObject msg = QJsonDocument::fromJson(text.toUtf8()).object();
    const QString type = msg.value("type").toString();

    if (type == "hello") {
        if (msg.value("version").toString() != "1")
            qWarning() << "voice: service speaks protocol version" << msg.value("version").toString()
                       << "- expected 1";
        m_wakewordName = msg.value("wakeword_name").toString();
        m_tts = msg.value("tts").toBool();
        m_stt = msg.value("stt").toBool();
        emit infoChanged();
        const bool wake = msg.value("wakeword").toBool();
        if (wake != m_wakewordEnabled) {
            m_wakewordEnabled = wake;
            emit wakewordEnabledChanged();
        }
    } else if (type == "state") {
        setState(msg.value("state").toString());
    } else if (type == "wake") {
        setTranscript({});
        emit woke(msg.value("source").toString(QStringLiteral("wakeword")));
    } else if (type == "level") {
        setLevel(qBound(0.0, msg.value("rms").toDouble(), 1.0));
    } else if (type == "transcript") {
        const QString said = msg.value("text").toString().trimmed();
        setTranscript(said);
        if (!msg.value("final").toBool(true))
            return;
        if (said.isEmpty())
            emit heardNothing();
        else
            emit heard(said);
    } else if (type == "spoken") {
        emit spoken(msg.value("id").toString());
    } else if (type == "error") {
        const QString message = msg.value("message").toString();
        qWarning() << "voice: service error:" << message;
        emit errorOccurred(message);
    }
}

bool VoiceClient::send(const QJsonObject &message)
{
    if (!m_available)
        return false;
    m_socket.sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
    return true;
}

void VoiceClient::listen()
{
    send({{"type", "listen"}});
}

void VoiceClient::cancel()
{
    send({{"type", "cancel"}});
}

QString VoiceClient::speak(const QString &text)
{
    const QString said = text.trimmed();
    if (said.isEmpty())
        return {};
    const QString id = QStringLiteral("display-%1").arg(m_nextSpeechId++);
    return send({{"type", "speak"}, {"text", said}, {"id", id}}) ? id : QString();
}

void VoiceClient::stopSpeaking()
{
    send({{"type", "stop_speaking"}});
}

void VoiceClient::setWakewordEnabled(bool enabled)
{
    // The service answers with a fresh hello, which corrects this if it refused.
    if (!send({{"type", "set"}, {"wakeword_enabled", enabled}}) || enabled == m_wakewordEnabled)
        return;
    m_wakewordEnabled = enabled;
    emit wakewordEnabledChanged();
}

void VoiceClient::setSpeakReplies(bool on)
{
    if (on == m_speakReplies)
        return;
    m_speakReplies = on;
    QSettings().setValue("voice/speakReplies", on);
    emit speakRepliesChanged();
}

QString VoiceClient::wakewordLabel() const
{
    // "hey_jarvis", "hey_jarvis_v0.1" or "/etc/homeos/hey_homeos.onnx" -> "Hey Jarvis" / "Hey Ohana"
    QString name = m_wakewordName.section('/', -1);
    static const QRegularExpression ext(QStringLiteral("\\.(onnx|tflite)$"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression version(QStringLiteral("[_-]v\\d+(\\.\\d+)*$"));
    name.remove(ext);
    name.remove(version);
    QStringList words = name.split(QRegularExpression(QStringLiteral("[_\\-\\s]+")), Qt::SkipEmptyParts);
    for (QString &w : words) {
        if (w.compare(QLatin1String("homeos"), Qt::CaseInsensitive) == 0)
            w = QStringLiteral("Ohana");
        else
            w[0] = w.at(0).toUpper();
    }
    return words.join(' ');
}

void VoiceClient::setAvailable(bool available)
{
    if (available == m_available)
        return;
    m_available = available;
    emit availableChanged();
}

void VoiceClient::setState(const QString &state)
{
    if (!kStates.contains(state) || state == m_state)
        return;
    m_state = state;
    if (state != "listening")
        setLevel(0);
    emit stateChanged();
}

void VoiceClient::setLevel(qreal level)
{
    if (qFuzzyCompare(level + 1, m_level + 1))
        return;
    m_level = level;
    emit levelChanged();
}

void VoiceClient::setTranscript(const QString &text)
{
    if (text == m_transcript)
        return;
    m_transcript = text;
    emit transcriptChanged();
}
