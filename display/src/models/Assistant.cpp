#include "Assistant.h"

#include "backend/SupabaseClient.h"
#include "models/FamilyStore.h"
#include "voice/VoiceClient.h"

#include <QDate>
#include <QJsonArray>
#include <QNetworkReply>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSettings>
#include <QTimer>
#include <QUrlQuery>

namespace {
constexpr int kRestoreLimit = 40;    // messages shown when the display restarts mid-thread
constexpr int kDemoThinkMs = 650;    // pause before a demo reply starts streaming

QString joinNatural(const QStringList &items)
{
    if (items.size() <= 1)
        return items.join(QString());
    return QStringList(items.mid(0, items.size() - 1)).join(", ") + " and " + items.last();
}

int httpStatus(const QString &error)
{
    static const QRegularExpression re(QStringLiteral("\\(HTTP (\\d+)\\)$"));
    const auto m = re.match(error);
    return m.hasMatch() ? m.captured(1).toInt() : 0;
}
} // namespace

Assistant::Assistant(SupabaseClient *client, FamilyStore *store, VoiceClient *voice, QObject *parent)
    : QObject(parent), m_client(client), m_store(store), m_voice(voice)
{
    m_threadId = QSettings().value("assistant/threadId").toString();

    // Once the display is signed in, bring back the conversation it was in.
    connect(m_store, &FamilyStore::statusChanged, this, [this]() {
        if (!m_restoreTried && m_store->mode() == "live" && m_store->online()) {
            m_restoreTried = true;
            restoreThread();
        }
    });
    // A re-paired display is a different device user: its old thread is gone.
    connect(m_store, &FamilyStore::modeChanged, this, [this]() {
        if (m_store->mode() == "pairing") {
            reset();
            m_restoreTried = false;
        }
    });
}

QStringList Assistant::suggestions() const
{
    return {tr("What's on today?"), tr("What's for dinner?"), tr("Who has chores left?"), tr("Add milk to the grocery list")};
}

void Assistant::setBusy(bool busy)
{
    if (m_busy == busy)
        return;
    m_busy = busy;
    emit busyChanged();
}

void Assistant::setThreadId(const QString &id)
{
    if (id == m_threadId)
        return;
    m_threadId = id;
    if (id.isEmpty())
        QSettings().remove("assistant/threadId");
    else
        QSettings().setValue("assistant/threadId", id);
    emit threadIdChanged();
}

void Assistant::ask(const QString &text)
{
    send(text, QStringLiteral("chat"));
}

void Assistant::askQuick(const QString &text)
{
    send(text, QStringLiteral("quick"));
}

void Assistant::stop()
{
    if (!m_busy)
        return;
    ++m_generation; // ignore anything still on its way
    if (m_reply)
        m_reply->abort();
    m_reply = nullptr;
    const ChatModel::Message &m = m_messages.at(m_replyRow);
    const bool partial = !m.text.trimmed().isEmpty();
    finishReply(partial ? m.text : tr("Stopped."), m.actions, partial, false);
}

void Assistant::reset()
{
    stop();
    m_messages.reset();
    m_replyRow = -1;
    m_replyText.clear();
    m_replyActions.clear();
    emit replyChanged();
    setThreadId({});
}

void Assistant::send(const QString &text, const QString &mode)
{
    const QString question = text.trimmed();
    if (question.isEmpty())
        return;
    if (m_busy) {
        // The wake word wins over a reply still streaming; a typed message waits.
        if (mode != "quick")
            return;
        stop();
    }

    m_messages.append({QStringLiteral("user"), question, {}, false, false, mode});
    m_replyRow = m_messages.append({QStringLiteral("assistant"), QString(), {}, true, false, mode});
    m_replyMode = mode;
    m_replyText.clear();
    m_replyActions.clear();
    emit replyChanged();
    setBusy(true);
    emit replyStarted(mode);

    const int generation = ++m_generation;
    if (m_store->mode() != "live") {
        streamDemo(generation, question);
        return;
    }
    if (m_client->hasSession()) {
        request(generation, question, mode, false);
        return;
    }
    m_client->refreshSession([this, generation, question, mode](bool ok) {
        if (generation != m_generation)
            return;
        if (ok)
            request(generation, question, mode, false);
        else
            fail(tr("I couldn't reach Ohana cloud just now. Try again in a moment."));
    });
}

void Assistant::request(int generation, const QString &question, const QString &mode, bool retried)
{
    QJsonObject body{{"message", question}, {"mode", mode}, {"stream", true}};
    if (!m_threadId.isEmpty())
        body.insert("thread_id", m_threadId);

    m_reply = m_client->streamFunction(
        "assistant", body,
        [this, generation](const QString &event, const QJsonObject &data) {
            if (generation == m_generation)
                onEvent(event, data);
        },
        [this, generation, question, mode, retried](const QString &error) {
            if (generation != m_generation || !m_busy)
                return; // superseded, or `done` / `error` already ended the turn
            m_reply = nullptr;
            const ChatModel::Message &m = m_messages.at(m_replyRow);
            const bool nothingYet = m.text.isEmpty() && m.actions.isEmpty();
            if (error.isEmpty()) {
                qWarning() << "assistant stream ended without a reply";
                fail(tr("Sorry, I lost the connection partway through. Try again?"));
                return;
            }
            const int status = httpStatus(error);
            if (!retried && nothingYet && status == 401) {
                // The access token expired between syncs: refresh once and resend.
                m_client->refreshSession([this, generation, question, mode](bool ok) {
                    // A rejected token ends the turn through re-pairing (the
                    // generation moves on); getting here means Ohana cloud
                    // couldn't be reached, not that the pairing is gone.
                    if (generation != m_generation)
                        return;
                    if (ok)
                        request(generation, question, mode, true);
                    else
                        fail(tr("I couldn't reach Ohana cloud just now. Try again in a moment."));
                });
                return;
            }
            if (!retried && nothingYet && status == 404 && !m_threadId.isEmpty()) {
                // The thread was deleted (e.g. from the phone): start a new one.
                setThreadId({});
                request(generation, question, mode, true);
                return;
            }
            qWarning() << "assistant failed:" << error;
            if (status == 403)
                fail(tr("The assistant isn't available for this family right now."));
            else if (status == 429)
                fail(tr("Ohana is a little busy. Try again in a moment."));
            else
                fail(tr("I couldn't reach Ohana cloud just now. Try again in a moment."));
        });
}

void Assistant::onEvent(const QString &event, const QJsonObject &data)
{
    if (!m_busy)
        return;
    if (event == "thread") {
        // Demo replies have no thread.
        if (m_store->mode() == "live")
            setThreadId(data.value("thread_id").toString());
    } else if (event == "delta") {
        const QString text = data.value("text").toString();
        m_messages.appendText(m_replyRow, text);
        m_replyText += text;
        emit replyChanged();
    } else if (event == "action") {
        const QVariantMap action = data.toVariantMap();
        m_messages.addAction(m_replyRow, action);
        m_replyActions.append(action);
        emit replyChanged();
    } else if (event == "done") {
        if (data.contains("thread_id") && m_store->mode() == "live")
            setThreadId(data.value("thread_id").toString());
        complete(data.value("reply").toString(), data.value("actions").toArray().toVariantList());
    } else if (event == "error") {
        const QString message = data.value("message").toString();
        qWarning() << "assistant stream error:" << message;
        fail(message.isEmpty() ? tr("Something went wrong on my side. Try again?") : message);
    }
}

void Assistant::complete(const QString &reply, const QVariantList &actions)
{
    QString text = reply.trimmed();
    if (text.isEmpty())
        text = actions.isEmpty() ? tr("I don't have an answer for that.") : tr("Done.");
    finishReply(text, actions, false, true);
}

void Assistant::fail(const QString &message)
{
    // Keep a partial answer (marked as cut short); otherwise say what happened.
    const ChatModel::Message &m = m_messages.at(m_replyRow);
    const bool partial = !m.text.trimmed().isEmpty();
    finishReply(partial ? m.text : message, m.actions, partial, true);
}

void Assistant::finishReply(const QString &text, const QVariantList &actions, bool failed, bool announce)
{
    m_reply = nullptr;
    m_messages.finish(m_replyRow, text, actions, failed);
    m_replyText = text;
    m_replyActions = actions;
    emit replyChanged();
    setBusy(false);
    if (!actions.isEmpty())
        m_store->refresh();
    if (!announce)
        return; // stopped on purpose: nothing to read out

    QString speechId;
    if (m_replyMode == "quick" && m_voice && m_voice->speakReplies() && m_voice->canSpeak())
        speechId = m_voice->speak(text);
    emit replyFinished(text, actions, m_replyMode, speechId);
}

void Assistant::restoreThread()
{
    if (m_threadId.isEmpty() || m_messages.count() > 0 || m_busy)
        return;
    QUrlQuery q;
    q.addQueryItem("select", "role,content,actions,mode");
    q.addQueryItem("thread_id", "eq." + m_threadId);
    q.addQueryItem("order", "id.desc");
    q.addQueryItem("limit", QString::number(kRestoreLimit));
    const QString thread = m_threadId;
    m_client->select("assistant_messages", q, [this, thread](const QJsonDocument &doc, const QString &error) {
        if (!error.isEmpty()) {
            qWarning() << "loading the assistant thread failed:" << error;
            return;
        }
        if (thread != m_threadId || m_messages.count() > 0 || m_busy)
            return; // the conversation moved on meanwhile
        QList<ChatModel::Message> rows;
        const QJsonArray array = doc.array(); // newest first
        for (qsizetype i = array.size() - 1; i >= 0; --i) {
            const QJsonObject o = array.at(i).toObject();
            rows.append({o.value("role").toString(), o.value("content").toString(),
                         o.value("actions").toArray().toVariantList(), false, false, o.value("mode").toString()});
        }
        if (rows.isEmpty()) {
            setThreadId({}); // deleted, or it belonged to an earlier pairing
            return;
        }
        m_messages.reset(rows);
    });
}

// ───────────────────────────── Demo replies ─────────────────────────────

void Assistant::streamDemo(int generation, const QString &question)
{
    QVariantList actions;
    const QString answer = demoAnswer(question, &actions);
    // Word by word, every 30–60 ms, like a live reply.
    static const QRegularExpression wordEnd(QStringLiteral("(?<=\\s)"));
    const QStringList chunks = answer.split(wordEnd, Qt::SkipEmptyParts);

    QTimer::singleShot(kDemoThinkMs, this, [this, generation, chunks, answer, actions]() {
        if (generation != m_generation)
            return;
        // Tools run before the model writes its summary, so chips come first.
        for (const QVariant &a : actions)
            onEvent(QStringLiteral("action"), QJsonObject::fromVariantMap(a.toMap()));
        streamChunks(generation, chunks, 0, answer, actions);
    });
}

void Assistant::streamChunks(int generation, const QStringList &chunks, int next, const QString &answer,
                             const QVariantList &actions)
{
    if (generation != m_generation)
        return;
    if (next >= chunks.size()) {
        onEvent(QStringLiteral("done"), {{"reply", answer}, {"actions", QJsonArray::fromVariantList(actions)}});
        return;
    }
    onEvent(QStringLiteral("delta"), {{"text", chunks.at(next)}});
    const int delay = QRandomGenerator::global()->bounded(30, 61);
    QTimer::singleShot(delay, this, [this, generation, chunks, next, answer, actions]() {
        streamChunks(generation, chunks, next + 1, answer, actions);
    });
}

QString Assistant::demoAnswer(const QString &question, QVariantList *actions)
{
    const QString q = question.toLower();
    const QString today = QDate::currentDate().toString(Qt::ISODate);
    const QString tomorrow = QDate::currentDate().addDays(1).toString(Qt::ISODate);

    // "add eggs to the grocery list", "put bread on the list"
    static const QRegularExpression addToList(
        QStringLiteral("^(?:please\\s+)?(?:add|put)\\s+(.+?)\\s+(?:to|on)\\s+(?:the\\s+|my\\s+|our\\s+)?(?:grocery|groceries|shopping)?\\s*list"),
        QRegularExpression::CaseInsensitiveOption);
    const auto add = addToList.match(question.trimmed());
    if (add.hasMatch() && !m_store->lists().isEmpty()) {
        const QVariantMap list = m_store->lists().first().toMap();
        const QString item = add.captured(1);
        const QString listName = list.value("name").toString();
        m_store->addListItem(list.value("id").toString(), item);
        actions->append(QVariantMap{{"type", "add_list_item"}, {"summary", tr("Added %1 to %2").arg(item, listName)}});
        return tr("Done — I added %1 to %2.").arg(item, listName);
    }

    auto eventsOn = [this](const QString &day) {
        QStringList out;
        for (const QVariant &v : m_store->events()) {
            const QVariantMap e = v.toMap();
            if (e.value("day").toString() != day)
                continue;
            const QString time = e.value("all_day").toBool() ? tr("all day") : e.value("timeLabel").toString().section(" – ", 0, 0);
            out << QStringLiteral("%1 at %2").arg(e.value("title").toString(), time);
        }
        return out;
    };

    if (q.contains("dinner") || q.contains("eat")) {
        for (const QVariant &v : m_store->meals()) {
            const QVariantMap m = v.toMap();
            if (m.value("date").toString() == today && m.value("meal").toString() == "dinner")
                return tr("Tonight is %1.").arg(m.value("title").toString());
        }
        return tr("Dinner isn't planned yet for tonight.");
    }

    if (q.contains("chore") || q.contains("left") || q.contains("to do") || q.contains("todo")) {
        QStringList parts;
        QHash<QString, QStringList> remaining;
        for (const QVariant &v : m_store->tasks()) {
            const QVariantMap t = v.toMap();
            if (t.value("status").toString() == "todo")
                remaining[t.value("assigneeName").toString()] << t.value("title").toString().toLower();
        }
        for (const QVariant &v : m_store->members()) {
            const QString name = v.toMap().value("display_name").toString();
            if (remaining.contains(name))
                parts << QStringLiteral("%1: %2").arg(name, joinNatural(remaining.value(name)));
        }
        return parts.isEmpty() ? tr("Everyone's done with their chores today!")
                               : tr("Still to do — ") + parts.join("; ") + ".";
    }

    if (q.contains("point") || q.contains("star")) {
        QStringList parts;
        for (const QVariant &v : m_store->members()) {
            const QVariantMap m = v.toMap();
            if (m.value("role").toString() == "child")
                parts << QStringLiteral("%1 has %2").arg(m.value("display_name").toString()).arg(m.value("points").toInt());
        }
        return joinNatural(parts) + tr(" points.");
    }

    if (q.contains("tomorrow")) {
        const QStringList events = eventsOn(tomorrow);
        return events.isEmpty() ? tr("Nothing on the calendar tomorrow.")
                                : tr("Tomorrow: ") + joinNatural(events) + ".";
    }

    if (q.contains("today") || q.contains("schedule") || q.contains("calendar") || q.contains("what's on")
        || q.contains("whats on")) {
        const QStringList events = eventsOn(today);
        return events.isEmpty() ? tr("Nothing on the calendar today — enjoy it!")
                                : tr("Today: ") + joinNatural(events) + ".";
    }

    if (q.startsWith("remember")) {
        return tr("Got it — I'll remember that once Ohana cloud is connected. (Demo mode doesn't save memories.)");
    }

    return tr("In demo mode I can tell you about today's schedule, tomorrow, dinner, chores and points, "
              "or add things to the grocery list. Connect Ohana cloud for the full assistant.");
}
