#pragma once

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QVariantList>

#include "models/ChatModel.h"

class FamilyStore;
class QNetworkReply;
class SupabaseClient;
class VoiceClient;

// The family assistant behind the "Ask Ohana" card and the wake word.
//
// Live mode streams from the `assistant` edge function (v2), which grounds
// Claude in the family's data, keeps the conversation in a thread and can add
// events, list items, chores and meals. The display keeps one thread going
// (QSettings assistant/threadId) until someone taps "New chat". Demo mode
// answers a handful of questions from the sample data, streamed the same way,
// so the screen is fully usable without a backend.
class Assistant : public QObject
{
    Q_OBJECT
    Q_PROPERTY(ChatModel *messages READ messages CONSTANT)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QStringList suggestions READ suggestions CONSTANT)
    Q_PROPERTY(QString threadId READ threadId NOTIFY threadIdChanged)
    // The reply being written (or the last one): the quick answer card shows it.
    Q_PROPERTY(QString replyText READ replyText NOTIFY replyChanged)
    Q_PROPERTY(QVariantList replyActions READ replyActions NOTIFY replyChanged)
    Q_PROPERTY(QString replyMode READ replyMode NOTIFY replyChanged)

public:
    Assistant(SupabaseClient *client, FamilyStore *store, VoiceClient *voice, QObject *parent = nullptr);

    ChatModel *messages() { return &m_messages; }
    bool busy() const { return m_busy; }
    QStringList suggestions() const;
    QString threadId() const { return m_threadId; }
    QString replyText() const { return m_replyText; }
    QVariantList replyActions() const { return m_replyActions; }
    QString replyMode() const { return m_replyMode; }

    // A chat message (the assistant panel, push-to-talk).
    Q_INVOKABLE void ask(const QString &text);
    // A short spoken answer (wake word). Speaks the reply when it's done if
    // spoken replies are on.
    Q_INVOKABLE void askQuick(const QString &text);
    // Stops the reply in flight, keeping whatever has arrived.
    Q_INVOKABLE void stop();
    // "New chat": clears the conversation and starts a new thread next time.
    Q_INVOKABLE void reset();

signals:
    void busyChanged();
    void threadIdChanged();
    void replyChanged();
    void replyStarted(const QString &mode);
    // speechId is the Voice.speak() id when the reply is being read out, else "".
    void replyFinished(const QString &text, const QVariantList &actions, const QString &mode, const QString &speechId);

private:
    void send(const QString &text, const QString &mode);
    void request(int generation, const QString &question, const QString &mode, bool retried);
    void onEvent(const QString &event, const QJsonObject &data);
    void complete(const QString &reply, const QVariantList &actions);
    void fail(const QString &message);
    void finishReply(const QString &text, const QVariantList &actions, bool failed, bool announce);
    void streamDemo(int generation, const QString &question);
    void streamChunks(int generation, const QStringList &chunks, int next, const QString &answer,
                      const QVariantList &actions);
    void restoreThread();
    void setThreadId(const QString &id);
    void setBusy(bool busy);
    QString demoAnswer(const QString &question, QVariantList *actions);

    SupabaseClient *m_client;
    FamilyStore *m_store;
    VoiceClient *m_voice;
    ChatModel m_messages;
    bool m_busy = false;
    QString m_threadId;
    bool m_restoreTried = false;

    // The reply in flight. Callbacks from older requests carry a stale
    // generation and are ignored.
    int m_generation = 0;
    int m_replyRow = -1;
    QString m_replyMode = QStringLiteral("chat");
    QString m_replyText;
    QVariantList m_replyActions;
    QPointer<QNetworkReply> m_reply;
};
