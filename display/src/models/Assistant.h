#pragma once

#include <QObject>
#include <QVariantList>

class FamilyStore;
class SupabaseClient;

// The family assistant behind the "Ask homeOS" card.
//
// Live mode sends the conversation to the `assistant` edge function, which
// grounds Claude in the family's data and can add events, list items, chores
// and meals. Demo mode answers a handful of questions from the sample data so
// the screen is fully usable without a backend.
class Assistant : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QStringList suggestions READ suggestions CONSTANT)

public:
    Assistant(SupabaseClient *client, FamilyStore *store, QObject *parent = nullptr);

    QVariantList messages() const { return m_messages; }
    bool busy() const { return m_busy; }
    QStringList suggestions() const;

    Q_INVOKABLE void ask(const QString &text);
    Q_INVOKABLE void reset();

signals:
    void messagesChanged();
    void busyChanged();

private:
    void append(const QString &role, const QString &text, const QVariantList &actions = {});
    void setBusy(bool busy);
    QString demoAnswer(const QString &question);

    SupabaseClient *m_client;
    FamilyStore *m_store;
    QVariantList m_messages; // [{ role: "user" | "assistant", text, actions }]
    bool m_busy = false;
};
