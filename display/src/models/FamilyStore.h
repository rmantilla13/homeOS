#pragma once

#include <QDate>
#include <QDateTime>
#include <QDeadlineTimer>
#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QSettings>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <functional>

#include "models/ColorSampler.h"

class SupabaseClient;

// Single source of family data for the QML UI.
//
// Modes:
//   demo    - no backend configured (or --demo): sample data, local-only edits
//   pairing - backend configured but this display has no session yet
//   live    - signed in as the device user; data synced from Supabase
//
// Rows keep their database shape (snake_case) and are decorated with a few
// display-ready fields (colors, "done today", points) in rebuild().
//
// `today` is the one local date the whole UI treats as today. It moves on at
// local midnight (and when the clock jumps), and the day's data moves with it.
class FamilyStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(bool online READ online NOTIFY statusChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY statusChanged)
    Q_PROPERTY(QString pairingCode READ pairingCode NOTIFY pairingChanged)
    Q_PROPERTY(QString today READ today NOTIFY todayChanged)       // local date, yyyy-MM-dd

    Q_PROPERTY(QString familyName READ familyName NOTIFY dataChanged)
    Q_PROPERTY(QVariantList members READ members NOTIFY dataChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY dataChanged)
    Q_PROPERTY(QVariantList tasks READ tasks NOTIFY dataChanged)
    Q_PROPERTY(QVariantList rewards READ rewards NOTIFY dataChanged)
    Q_PROPERTY(QVariantList meals READ meals NOTIFY dataChanged)
    Q_PROPERTY(QVariantList lists READ lists NOTIFY dataChanged)
    // Their own signal, sent only when the list really changes: every reload
    // of an unrelated table would otherwise rebuild the media grid and
    // re-read every image.
    Q_PROPERTY(QVariantList photos READ photos NOTIFY mediaChanged)  // photos shown in the frame
    Q_PROPERTY(QVariantList media READ media NOTIFY mediaChanged)    // all photos and videos, newest first

public:
    FamilyStore(SupabaseClient *client, bool forceDemo, QObject *parent = nullptr);

    void start();
    // Origin of the admin app that signs private photo and video URLs.
    // Empty means Blob files have no playback URL. Rows still in Supabase play.
    void setMediaApiUrl(const QString &url);
    // The media service the phones upload through: `configured` when it is
    // an http(s) URL with a real host, else https://ohanaos.co, the iOS
    // app's default. An empty value or the display.env example placeholder
    // would leave every new photo and video without a URL.
    static QString mediaApiUrlOrDefault(const QString &configured);
    // How long a signed media URL is reused, and when it is dropped even if
    // signing it again fails. Both shorten URLs already signed (for tests).
    void setUrlRefreshAfterMs(qint64 ms);
    void setUrlDropAfterMs(qint64 ms);

    QString mode() const { return m_mode; }
    bool online() const { return m_online; }
    QString lastError() const { return m_lastError; }
    QString pairingCode() const { return m_pairingCode; }
    QString today() const { return m_today.toString(Qt::ISODate); }
    QDate todayDate() const { return m_today; }

    QString familyName() const { return m_familyName; }
    QVariantList members() const { return m_members; }
    QVariantList events() const { return m_events; }
    QVariantList tasks() const { return m_tasks; }
    QVariantList rewards() const { return m_rewards; }
    QVariantList meals() const { return m_meals; }
    QVariantList lists() const { return m_lists; }
    QVariantList photos() const { return m_photos; }
    QVariantList media() const { return m_media; }

    // Syncs now (live), or asks for a pairing code again now if the last try
    // failed (e.g. Wi-Fi was just joined). Also re-checks the date.
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void completeTask(const QString &taskId, const QString &memberId);
    Q_INVOKABLE void redeemReward(const QString &rewardId, const QString &memberId);
    Q_INVOKABLE void setListItemDone(const QString &listId, const QString &itemId, bool done);
    Q_INVOKABLE void addListItem(const QString &listId, const QString &text);
    // Wall create flows. startsAt/endsAt are ISO-8601 local timestamps from QML.
    // memberIds is a list of member UUID strings (may be empty).
    Q_INVOKABLE void addEvent(const QString &title, const QString &location,
                              const QString &startsAt, const QString &endsAt, bool allDay,
                              const QVariantList &memberIds);
    // Device accounts must keep requiresApproval=true when points > 0 (tasks_guard).
    Q_INVOKABLE void addTask(const QString &title, const QString &icon, const QString &assigneeId,
                             int points, bool requiresApproval, const QString &rrule);
    Q_INVOKABLE void addReward(const QString &title, const QString &icon, int cost);
    Q_INVOKABLE int pointsFor(const QString &memberId) const { return m_points.value(memberId); }
    // Forgets this display's session and shows a new pairing code (Settings → Re-pair).
    Q_INVOKABLE void unpair();

    // Does an RRULE (subset: DAILY, WEEKLY;BYDAY=..) occur on `day`? Demo data
    // only, whose chores are all FREQ=DAILY: live mode asks the database
    // (chores_due, event_occurrences), which knows the full rule set.
    static bool occursOn(const QString &rrule, const QDate &day);

    // Tests: a stand-in for the wall clock (local time). Call before start().
    void setClock(std::function<QDateTime()> now) { m_clock = std::move(now); }

signals:
    void modeChanged();
    void statusChanged();
    void pairingChanged();
    void todayChanged();
    void dataChanged();
    void mediaChanged();
    void notify(const QString &message);

private:
    void setMode(const QString &mode);
    void setOnline(bool online, const QString &error = {});
    void loadDemo();
    void loadLive();
    void attachMediaUrls(const QVariantList &rows, int generation);
    void signMedia(bool blob, const QStringList &paths, int generation);
    void rememberUrls(bool blob, const QStringList &paths, const QStringList &urls, bool ok);
    void publishMedia();
    QString signedUrl(bool blob, const QString &path) const;
    void forgetMedia();
    void withSession(std::function<void()> fn);
    void checkIn();
    void syncCalendars(const QString &familyId);
    void startPairing();
    void pollPairing();
    void rebuild();
    void scheduleRebuild();
    QDateTime now() const { return m_clock ? m_clock() : QDateTime::currentDateTime(); }
    bool updateToday();
    bool rollDay();
    static QString demoMediaDir();

    SupabaseClient *m_client;
    QString m_mediaApiUrl;
    QSettings m_settings;
    bool m_forceDemo;
    QString m_mode = QStringLiteral("demo");
    bool m_online = false;
    QString m_lastError;

    QTimer m_syncTimer;
    QTimer m_pairTimer;
    QTimer m_pairRetryTimer;
    QString m_pairingCode;
    QString m_pairingSecret;
    // Bumped for each new code and once paired; answers to older pairing
    // requests (a slow poll, a retry that crossed one) are ignored.
    int m_pairAttempt = 0;
    // Bumped when the device's session is dropped (re-pair, lost session) so
    // answers to requests made before are ignored.
    int m_generation = 0;
    // When this display last set devices.last_seen_at (monotonic; invalid until it has).
    QElapsedTimer m_lastCheckIn;
    // When this display last asked for the family's connected calendars to be refreshed.
    QElapsedTimer m_lastCalendarSync;

    std::function<QDateTime()> m_clock; // tests only; empty means the real clock
    QDate m_today;
    QTimer m_dayTimer; // fires just after local midnight

    // Raw rows as loaded (demo JSON or Supabase).
    QVariantList m_rawMembers, m_rawEvents, m_rawTasks, m_rawRewards, m_rawMeals, m_rawLists, m_rawMedia;
    QHash<QString, QString> m_completedToday; // "taskId|memberId" -> status
    QHash<QString, int> m_points;              // memberId -> balance
    ColorSampler m_colors;
    bool m_rebuildQueued = false;

    // Signed media URLs, one per storage or thumbnail path, kept until they
    // are due to be signed again. The same URL string means the players and
    // the image cache don't reload the file.
    struct SignedUrl
    {
        QString url;
        QDeadlineTimer refreshAt; // sign again after this
        QDeadlineTimer dropAt;    // stop using it after this, even if signing fails
    };
    QHash<QString, SignedUrl> m_signedUrls;   // "b:<path>" Blob, "s:<path>" Storage
    QSet<QString> m_signing;                  // keys with a signing request out
    int m_signRequests = 0;                   // signing requests out
    QVariantList m_mediaRows;                 // the latest media_items rows
    qint64 m_urlRefreshMs = 4 * 3600 * 1000LL; // URLs are valid for 6 h (both signers)
    qint64 m_urlDropMs = 5 * 3600 * 1000LL + 30 * 60 * 1000LL; // half an hour before they expire

    // Decorated rows for QML.
    QString m_familyName;
    QVariantList m_members, m_events, m_tasks, m_rewards, m_meals, m_lists, m_photos, m_media;
};
