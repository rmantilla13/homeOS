#pragma once

#include <QByteArray>
#include <QList>
#include <QString>

// Incremental parser for a text/event-stream body (Server-Sent Events).
//
// Feed it bytes as they arrive; it returns the events completed so far. It
// copes with any chunking (a line, a CRLF pair or a multi-byte character split
// across reads), LF / CRLF / CR line endings, multi-line `data:` fields,
// comments and a leading BOM, following the WHATWG event-stream rules.
class SseParser
{
public:
    struct Event
    {
        QString name; // "message" when the event has no `event:` field
        QString data; // data lines joined with '\n'
        QString id;
    };

    QList<Event> feed(const QByteArray &bytes);
    // End of stream: completes a trailing line and dispatches an event that
    // only lacked its blank line, which is more forgiving than the standard.
    QList<Event> finish();

private:
    void processLine(const QByteArray &line, QList<Event> &out);
    void dispatch(QList<Event> &out);

    QByteArray m_buffer;
    bool m_started = false;   // BOM check done
    bool m_skipLf = false;    // last chunk ended in CR; a leading LF belongs to it
    QString m_event;
    QString m_data;
    QString m_lastId;
    bool m_hasData = false;
};
