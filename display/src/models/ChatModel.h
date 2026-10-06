#pragma once

#include <QAbstractListModel>
#include <QVariantList>

// The assistant conversation as a list model, so a streaming reply updates
// one bubble in place instead of rebuilding the whole list.
class ChatModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Role { RoleRole = Qt::UserRole + 1, TextRole, ActionsRole, StreamingRole, FailedRole, ModeRole };

    struct Message
    {
        QString role;          // "user" | "assistant"
        QString text;
        QVariantList actions;  // [{ type, summary }]
        bool streaming = false;
        bool failed = false;   // the reply was cut short; text holds what arrived
        QString mode;          // "chat" | "quick"
    };

    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return int(m_rows.size()); }
    const Message &at(int row) const { return m_rows.at(row); }
    const QList<Message> &rows() const { return m_rows; }

    int append(const Message &message);
    void appendText(int row, const QString &delta);
    void addAction(int row, const QVariantMap &action);
    void finish(int row, const QString &text, const QVariantList &actions, bool failed = false);
    void reset(const QList<Message> &rows = {});

signals:
    void countChanged();

private:
    void changed(int row, const QList<int> &roles);

    QList<Message> m_rows;
};
