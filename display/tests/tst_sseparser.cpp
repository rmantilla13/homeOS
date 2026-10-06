#include <QtTest>

#include "backend/SseParser.h"

// The assistant's event stream must survive whatever chunking the network
// produces: these feed the same bytes split at every possible point.
class TestSseParser : public QObject
{
    Q_OBJECT

    using Events = QList<SseParser::Event>;

    static Events parseWhole(const QByteArray &bytes)
    {
        SseParser p;
        Events out = p.feed(bytes);
        out += p.finish();
        return out;
    }

    static Events parseSplit(const QByteArray &bytes, const QList<qsizetype> &cuts)
    {
        SseParser p;
        Events out;
        qsizetype from = 0;
        for (qsizetype cut : cuts) {
            out += p.feed(bytes.mid(from, cut - from));
            from = cut;
        }
        out += p.feed(bytes.mid(from));
        out += p.finish();
        return out;
    }

    static void compare(const Events &actual, const Events &expected)
    {
        QCOMPARE(actual.size(), expected.size());
        for (int i = 0; i < actual.size(); ++i) {
            QCOMPARE(actual.at(i).name, expected.at(i).name);
            QCOMPARE(actual.at(i).data, expected.at(i).data);
        }
    }

    // The order the assistant function sends: thread, deltas, action, done.
    static QByteArray assistantStream(const QByteArray &eol)
    {
        QByteArray s;
        auto line = [&](const QByteArray &l) { s += l + eol; };
        line("event: thread");
        line("data: {\"thread_id\":\"7d4f\"}");
        line("");
        line(": keep-alive");
        line("event: delta");
        line("data: {\"text\":\"Tonight is \"}");
        line("");
        line("event: delta");
        line(QByteArray("data: {\"text\":\"tacos ") + "\xF0\x9F\x8C\xAE" + " and caf" + "\xC3\xA9" + "\"}");
        line("");
        line("event: action");
        line("data: {\"type\":\"set_meal\",\"summary\":\"Set dinner\"}");
        line("");
        line("event: done");
        line("data: {\"reply\":\"Tonight is tacos.\",\"actions\":[],\"thread_id\":\"7d4f\",\"message_id\":7}");
        line("");
        return s;
    }

    static Events expectedAssistant()
    {
        return {
            {"thread", "{\"thread_id\":\"7d4f\"}", {}},
            {"delta", "{\"text\":\"Tonight is \"}", {}},
            {"delta", QString::fromUtf8(QByteArray("{\"text\":\"tacos ") + "\xF0\x9F\x8C\xAE" + " and caf\xC3\xA9\"}"), {}},
            {"action", "{\"type\":\"set_meal\",\"summary\":\"Set dinner\"}", {}},
            {"done", "{\"reply\":\"Tonight is tacos.\",\"actions\":[],\"thread_id\":\"7d4f\",\"message_id\":7}", {}},
        };
    }

private slots:
    void wholeStream_data()
    {
        QTest::addColumn<QByteArray>("eol");
        QTest::newRow("LF") << QByteArray("\n");
        QTest::newRow("CRLF") << QByteArray("\r\n");
        QTest::newRow("CR") << QByteArray("\r");
    }
    void wholeStream()
    {
        QFETCH(QByteArray, eol);
        compare(parseWhole(assistantStream(eol)), expectedAssistant());
    }

    void everySplitPoint_data() { wholeStream_data(); }
    void everySplitPoint()
    {
        QFETCH(QByteArray, eol);
        const QByteArray bytes = assistantStream(eol);
        const Events expected = expectedAssistant();
        for (qsizetype cut = 1; cut < bytes.size(); ++cut)
            compare(parseSplit(bytes, {cut}), expected);
        // Two cuts close together catch a CR and its LF arriving separately.
        for (qsizetype a = 1; a + 1 < bytes.size(); a += 3)
            compare(parseSplit(bytes, {a, a + 1}), expected);
    }

    void byteByByte()
    {
        const QByteArray bytes = assistantStream("\r\n");
        SseParser p;
        Events out;
        for (char c : bytes)
            out += p.feed(QByteArray(1, c));
        out += p.finish();
        compare(out, expectedAssistant());
    }

    void multiLineData()
    {
        compare(parseWhole("event: delta\ndata: line one\ndata:line two\ndata\ndata: \n\n"),
                {{"delta", "line one\nline two\n\n", {}}});
    }

    void defaultsAndIgnoredFields()
    {
        // No event name -> "message"; retry/unknown fields are ignored; a block
        // with no data dispatches nothing; the event name resets after dispatch.
        compare(parseWhole("retry: 1000\nfoo: bar\ndata: a\n\nevent: delta\n\ndata: b\n\n"),
                {{"message", "a", {}}, {"message", "b", {}}});
        SseParser p;
        const Events withId = p.feed("id: 42\ndata: x\n\n");
        QCOMPARE(withId.size(), 1);
        QCOMPARE(withId.first().id, QStringLiteral("42"));
    }

    void byteOrderMark()
    {
        const QByteArray bytes = "\xEF\xBB\xBF" "event: done\ndata: {}\n\n";
        for (qsizetype cut = 1; cut < 6; ++cut)
            compare(parseSplit(bytes, {cut}), {{"done", "{}", {}}});
    }

    void unterminatedFinalEvent()
    {
        // A server that closes without the closing blank line still delivers.
        compare(parseWhole("event: done\ndata: {\"reply\":\"ok\"}"), {{"done", "{\"reply\":\"ok\"}", {}}});
        compare(parseWhole("event: done\r\ndata: {}\r"), {{"done", "{}", {}}});
    }

    void spacesInValues()
    {
        // Only the single space after the colon is dropped.
        compare(parseWhole("data:   indented\n\n"), {{"message", "  indented", {}}});
    }
};

QTEST_GUILESS_MAIN(TestSseParser)
#include "tst_sseparser.moc"
