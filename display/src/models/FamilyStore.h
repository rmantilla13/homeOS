#pragma once

#include <QDate>
#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QSettings>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

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
class FamilyStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(bool online READ online NOTIFY statusChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY statusChanged)
    Q_PROPERTY(QString pairingCode READ pairingCode NOTIFY pairingChanged)

    Q_PROPERTY(QString familyName READ familyName NOTIFY dataChanged)
    Q_PROPERTY(QVariantList members READ members NOTIFY dataChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY dataChanged)
    Q_PROPERTY(QVariantList tasks READ tasks NOTIFY dataChanged)
    Q_PROPERTY(QVariantList rewards READ rewards NOTIFY dataChanged)
    Q_PROPERTY(QVariantList meals READ meals NOTIFY dataChanged)
    Q_PROPERTY(QVariantList lists READ lists NOTIFY dataChanged)
    Q_PROPERTY(QVariantList photos READ photos NOTIFY dataChanged)   // photos shown in the frame
    Q_PROPERTY(QVariantList media READ media NOTIFY dataChanged)     // all photos and videos, newest first

public:
    FamilyStore(SupabaseClient *client, bool forceDemo, QObject *parent = nullptr);

    void start();

    QString mode() const { return m_mode; }
    bool online() const { return m_online; }
    QString lastError() const { return m_lastError; }
    QString pairingCode() const { return m_pairingCode; }

    QString familyName() const { return m_familyName; }
    QVariantList members() const { return m_members; }
    QVariantList events() const { return m_events; }
    QVariantList tasks() const { return m_tasks; }
    QVariantList rewards() const { return m_rewards; }
    QVariantList meals() const { return m_meals; }
    QVariantList lists() const { return m_lists; }
    QVariantList photos() const { return m_photos; }
    QVariantList media() const { return m_media; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void completeTask(const QString &taskId, const QString &memberId);
    Q_INVOKABLE void redeemReward(const QString &rewardId, const QString &memberId);
    Q_INVOKABLE void setListItemDone(const QString &listId, const QString &itemId, bool done);
    Q_INVOKABLE void addListItem(const QString &listId, const QString &text);
    Q_INVOKABLE int pointsFor(const QString &memberId) const { return m_points.value(memberId); }
    // Forgets this display's session and shows a new pairing code (Settings → Re-pair).
    Q_INVOKABLE void unpair();

    // Exposed for tests: does an RRULE (subset: DAILY, WEEKLY;BYDAY=..) occur on `day`?
    static bool occursOn(const QString &rrule, const QDate &day);

signals:
    void modeChanged();
    void statusChanged();
    void pairingChanged();
    void dataChanged();
    void notify(const QString &message);

private:
    void setMode(const QString &mode);
    void setOnline(bool online, const QString &error = {});
    void loadDemo();
    void loadLive();
    void withSession(std::function<void()> fn);
    void checkIn();
    void startPairing();
    void pollPairing();
    void rebuild();
    void scheduleRebuild();
    static QString demoMediaDir();

    SupabaseClient *m_client;
    QSettings m_settings;
    bool m_forceDemo;
    QString m_mode = QStringLiteral("demo");
    bool m_online = false;
    QString m_lastError;

    QTimer m_syncTimer;
    QTimer m_pairTimer;
    QString m_pairingCode;
    QString m_pairingSecret;
    // Bumped when the device's session is dropped (re-pair, lost session) so
    // answers to requests made before are ignored.
    int m_generation = 0;
    // When this display last set devices.last_seen_at (monotonic; invalid until it has).
    QElapsedTimer m_lastCheckIn;

    // Raw rows as loaded (demo JSON or Supabase).
    QVariantList m_rawMembers, m_rawEvents, m_rawTasks, m_rawRewards, m_rawMeals, m_rawLists, m_rawMedia;
    QHash<QString, QString> m_completedToday; // "taskId|memberId" -> status
    QHash<QString, int> m_points;              // memberId -> balance
    ColorSampler m_colors;
    bool m_rebuildQueued = false;

    // Decorated rows for QML.
    QString m_familyName;
    QVariantList m_members, m_events, m_tasks, m_rewards, m_meals, m_lists, m_photos, m_media;
};
