#include "Assistant.h"

#include "backend/SupabaseClient.h"
#include "models/FamilyStore.h"

#include <QDate>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTimer>

namespace {
constexpr int kMaxHistory = 20;

QString joinNatural(const QStringList &items)
{
    if (items.size() <= 1)
        return items.join(QString());
    return QStringList(items.mid(0, items.size() - 1)).join(", ") + " and " + items.last();
}
} // namespace

Assistant::Assistant(SupabaseClient *client, FamilyStore *store, QObject *parent)
    : QObject(parent), m_client(client), m_store(store)
{
}

QStringList Assistant::suggestions() const
{
    return {tr("What's on today?"), tr("What's for dinner?"), tr("Who has chores left?"), tr("Add milk to the grocery list")};
}

void Assistant::reset()
{
    m_messages.clear();
    emit messagesChanged();
}

void Assistant::append(const QString &role, const QString &text, const QVariantList &actions)
{
    m_messages << QVariantMap{{"role", role}, {"text", text}, {"actions", actions}};
    emit messagesChanged();
}

void Assistant::setBusy(bool busy)
{
    if (m_busy == busy)
        return;
    m_busy = busy;
    emit busyChanged();
}

void Assistant::ask(const QString &text)
{
    const QString question = text.trimmed();
    if (question.isEmpty() || m_busy)
        return;
    append("user", question);
    setBusy(true);

    if (m_store->mode() != "live") {
        // Short pause so the reply feels conversational rather than instant.
        QTimer::singleShot(700, this, [this, question]() {
            append("assistant", demoAnswer(question));
            setBusy(false);
        });
        return;
    }

    QJsonArray history;
    for (const QVariant &v : m_messages.mid(qMax(0, m_messages.size() - kMaxHistory))) {
        const QVariantMap m = v.toMap();
        history.append(QJsonObject{{"role", m.value("role").toString()}, {"text", m.value("text").toString()}});
    }
    m_client->callFunction("assistant", {{"messages", history}}, [this](const QJsonDocument &doc, const QString &error) {
        setBusy(false);
        if (!error.isEmpty()) {
            qWarning() << "assistant failed:" << error;
            append("assistant", tr("I couldn't reach homeOS cloud just now. Try again in a moment."));
            return;
        }
        const QJsonObject o = doc.object();
        const QVariantList actions = o.value("actions").toArray().toVariantList();
        append("assistant", o.value("reply").toString(), actions);
        if (!actions.isEmpty())
            m_store->refresh();
    });
}

// ───────────────────────────── Demo answers ─────────────────────────────

QString Assistant::demoAnswer(const QString &question)
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
        m_store->addListItem(list.value("id").toString(), add.captured(1));
        return tr("Done — I added %1 to %2.").arg(add.captured(1), list.value("name").toString());
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
        return tr("Got it — I'll remember that once homeOS cloud is connected. (Demo mode doesn't save memories.)");
    }

    return tr("In demo mode I can tell you about today's schedule, tomorrow, dinner, chores and points, "
              "or add things to the grocery list. Connect homeOS cloud for the full assistant.");
}
