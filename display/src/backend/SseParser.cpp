#include "SseParser.h"

QList<SseParser::Event> SseParser::feed(const QByteArray &bytes)
{
    QList<Event> out;
    m_buffer.append(bytes);

    if (!m_started) {
        if (m_buffer.size() < 3 && QByteArray("\xEF\xBB\xBF").startsWith(m_buffer))
            return out; // could still be a BOM
        if (m_buffer.startsWith("\xEF\xBB\xBF"))
            m_buffer.remove(0, 3);
        m_started = true;
    }

    qsizetype start = 0;
    if (m_skipLf && !m_buffer.isEmpty()) {
        if (m_buffer.at(0) == '\n')
            start = 1;
        m_skipLf = false;
    }
    for (qsizetype i = start; i < m_buffer.size(); ++i) {
        const char c = m_buffer.at(i);
        if (c != '\n' && c != '\r')
            continue;
        processLine(m_buffer.mid(start, i - start), out);
        if (c == '\r') {
            if (i + 1 < m_buffer.size()) {
                if (m_buffer.at(i + 1) == '\n')
                    ++i;
            } else {
                m_skipLf = true; // the LF of this CRLF may arrive in the next chunk
            }
        }
        start = i + 1;
    }
    m_buffer.remove(0, start);
    return out;
}

QList<SseParser::Event> SseParser::finish()
{
    QList<Event> out;
    if (!m_buffer.isEmpty())
        processLine(m_buffer, out);
    m_buffer.clear();
    dispatch(out);
    m_skipLf = false;
    return out;
}

void SseParser::processLine(const QByteArray &line, QList<Event> &out)
{
    if (line.isEmpty()) {
        dispatch(out);
        return;
    }
    if (line.startsWith(':'))
        return; // comment / keep-alive

    const qsizetype colon = line.indexOf(':');
    const QByteArray field = colon < 0 ? line : line.left(colon);
    QByteArray value = colon < 0 ? QByteArray() : line.mid(colon + 1);
    if (value.startsWith(' '))
        value.remove(0, 1);

    if (field == "event") {
        m_event = QString::fromUtf8(value);
    } else if (field == "data") {
        if (m_hasData)
            m_data += '\n';
        m_data += QString::fromUtf8(value);
        m_hasData = true;
    } else if (field == "id") {
        if (!value.contains('\0'))
            m_lastId = QString::fromUtf8(value);
    }
    // `retry` and unknown fields are ignored: we never reconnect a stream.
}

void SseParser::dispatch(QList<Event> &out)
{
    if (m_hasData)
        out.append({m_event.isEmpty() ? QStringLiteral("message") : m_event, m_data, m_lastId});
    m_event.clear();
    m_data.clear();
    m_hasData = false;
}
