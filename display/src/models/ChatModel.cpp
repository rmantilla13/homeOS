#include "ChatModel.h"

int ChatModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant ChatModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size())
        return {};
    const Message &m = m_rows.at(index.row());
    switch (role) {
    case RoleRole: return m.role;
    case TextRole: return m.text;
    case ActionsRole: return m.actions;
    case StreamingRole: return m.streaming;
    case FailedRole: return m.failed;
    case ModeRole: return m.mode;
    default: return {};
    }
}

QHash<int, QByteArray> ChatModel::roleNames() const
{
    return {{RoleRole, "role"},          {TextRole, "text"},     {ActionsRole, "actions"},
            {StreamingRole, "streaming"}, {FailedRole, "failed"}, {ModeRole, "mode"}};
}

int ChatModel::append(const Message &message)
{
    const int row = int(m_rows.size());
    beginInsertRows({}, row, row);
    m_rows.append(message);
    endInsertRows();
    emit countChanged();
    return row;
}

void ChatModel::appendText(int row, const QString &delta)
{
    if (row < 0 || row >= m_rows.size() || delta.isEmpty())
        return;
    m_rows[row].text += delta;
    changed(row, {TextRole});
}

void ChatModel::addAction(int row, const QVariantMap &action)
{
    if (row < 0 || row >= m_rows.size())
        return;
    m_rows[row].actions.append(action);
    changed(row, {ActionsRole});
}

void ChatModel::finish(int row, const QString &text, const QVariantList &actions, bool failed)
{
    if (row < 0 || row >= m_rows.size())
        return;
    Message &m = m_rows[row];
    m.text = text;
    m.actions = actions;
    m.streaming = false;
    m.failed = failed;
    changed(row, {TextRole, ActionsRole, StreamingRole, FailedRole});
}

void ChatModel::reset(const QList<Message> &rows)
{
    const bool countChanges = rows.size() != m_rows.size();
    beginResetModel();
    m_rows = rows;
    endResetModel();
    if (countChanges)
        emit countChanged();
}

void ChatModel::changed(int row, const QList<int> &roles)
{
    const QModelIndex i = index(row);
    emit dataChanged(i, i, roles);
}
