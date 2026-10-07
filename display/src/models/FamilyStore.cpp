#include "FamilyStore.h"

#include "backend/SupabaseClient.h"

#include <QColor>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QSet>
#include <QUuid>
#include <algorithm>
#include <memory>

namespace {

constexpr int kSyncIntervalMs = 60 * 1000; // fallback until Realtime subscriptions land (M1)
constexpr int kPairPollMs = 3000;
constexpr int kPairRetryMs = 10 * 1000;
constexpr qint64 kCheckInIntervalMs = 5 * 60 * 1000;
// Re-check the date at least this often, so a jump of the clock (NTP setting
// it at boot) is noticed between syncs and in demo mode too.
constexpr qint64 kDayCheckMaxMs = 15 * 60 * 1000;
const QString kMediaBucket = QStringLiteral("family-media");
// Signed media URLs last 6 hours: Supabase signs for that long here, and the
// admin's Blob URLs too (admin/lib/media/api.ts PLAYBACK_TTL_MS). They're
// renewed only within an hour of running out.
constexpr int kSignedUrlSecs = 6 * 3600;
constexpr int kRenewUrlSecs = 3600;

QString key(const QString &taskId, const QString &memberId) { return taskId + '|' + memberId; }

QVariantList toList(const QJsonDocument &doc) { return doc.array().toVariantList(); }

QDateTime parseTimestamp(const QString &s)
{
    QDateTime dt = QDateTime::fromString(s, Qt::ISODateWithMs);
    if (!dt.isValid())
        dt = QDateTime::fromString(s, Qt::ISODate);
    return dt.toLocalTime();
}

QString newId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }

} // namespace

FamilyStore::FamilyStore(SupabaseClient *client, bool forceDemo, QObject *parent)
    : QObject(parent), m_client(client), m_forceDemo(forceDemo)
{
    m_syncTimer.setInterval(kSyncIntervalMs);
    connect(&m_syncTimer, &QTimer::timeout, this, &FamilyStore::refresh);

    // Photo colors arrive asynchronously; fold them in with one rebuild.
    connect(&m_colors, &ColorSampler::sampled, this, &FamilyStore::scheduleRebuild);

    m_pairTimer.setInterval(kPairPollMs);
    connect(&m_pairTimer, &QTimer::timeout, this, &FamilyStore::pollPairing);
    m_pairRetryTimer.setSingleShot(true);
    m_pairRetryTimer.setInterval(kPairRetryMs);
    connect(&m_pairRetryTimer, &QTimer::timeout, this, &FamilyStore::startPairing);

    m_today = QDate::currentDate();
    m_dayTimer.setSingleShot(true);
    connect(&m_dayTimer, &QTimer::timeout, this, &FamilyStore::rollDay);

    connect(m_client, &SupabaseClient::sessionChanged, this, [this]() {
        if (m_client->refreshToken().isEmpty())
            return;
        m_settings.setValue("device/refreshToken", m_client->refreshToken());
        // The token signs in as this family's display: keep the file private
        // (later saves replace it with the same permissions).
        m_settings.sync();
        QFile::setPermissions(m_settings.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    });
    connect(m_client, &SupabaseClient::sessionLost, this, [this]() {
        ++m_generation;
        m_settings.remove("device/refreshToken");
        m_client->clearSession();
        m_syncTimer.stop();
        forgetMedia();
        startPairing();
    });
}

void FamilyStore::setMediaApiUrl(const QString &url)
{
    m_mediaApiUrl = url.trimmed();
    while (m_mediaApiUrl.endsWith(QLatin1Char('/')))
        m_mediaApiUrl.chop(1);
}

void FamilyStore::start()
{
    updateToday(); // the clock may have been swapped since construction (tests)
    if (m_forceDemo || !m_client->isConfigured()) {
        setMode("demo");
        loadDemo();
    } else if (m_client->refreshToken().isEmpty()) {
        startPairing();
    } else {
        setMode("live");
        loadLive();
        m_syncTimer.start();
    }
}

void FamilyStore::setMode(const QString &mode)
{
    if (m_mode == mode)
        return;
    m_mode = mode;
    emit modeChanged();
}

void FamilyStore::setOnline(bool online, const QString &error)
{
    if (m_online == online && m_lastError == error)
        return;
    m_online = online;
    m_lastError = error;
    emit statusChanged();
}

void FamilyStore::refresh()
{
    // Each sync re-checks the date too, in case the clock jumped past midnight
    // (a live display reloads for the new day there).
    const bool rolled = rollDay();
    if (m_mode == "live") {
        if (!rolled)
            loadLive();
    } else if (m_mode == "pairing" && m_pairRetryTimer.isActive()) {
        startPairing(); // the last try failed: don't wait for the next one
    }
}

// Reads the clock: sets `today` and arms the timer for the next check, just
// after local midnight. True if the date changed.
bool FamilyStore::updateToday()
{
    const QDateTime current = now();
    const bool changed = current.date() != m_today;
    if (changed) {
        m_today = current.date();
        emit todayChanged();
    }
    const qint64 untilMidnight = current.msecsTo(m_today.addDays(1).startOfDay());
    m_dayTimer.start(int(qBound<qint64>(1000, untilMidnight + 500, kDayCheckMaxMs)));
    return changed;
}

// A new day: demo data is laid out around the new date again; live data is
// fetched again, starting with no chores at all (yesterday's list isn't
// today's, even while offline). True if the date changed.
bool FamilyStore::rollDay()
{
    if (!updateToday())
        return false;
    if (m_mode == "demo") {
        loadDemo();
    } else if (m_mode == "live") {
        m_rawTasks.clear();
        m_completedToday.clear();
        rebuild();
        loadLive();
    }
    return true;
}

// ───────────────────────────── Demo data ─────────────────────────────

void FamilyStore::loadDemo()
{
    QFile file(QStringLiteral(":/HomeOS/resources/demo/family.json"));
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "demo data missing";
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const QDate base = m_today;

    m_familyName = root.value("family").toObject().value("name").toString();
    m_rawMembers = root.value("members").toArray().toVariantList();
    m_rawTasks = root.value("tasks").toArray().toVariantList();
    m_rawRewards = root.value("rewards").toArray().toVariantList();
    m_rawLists = root.value("lists").toArray().toVariantList();
    // Demo media lives next to the binary (copied there at build/install time).
    m_rawMedia.clear();
    const QString mediaDir = demoMediaDir();
    const QDateTime nowDt = now();
    for (const QJsonValue &v : root.value("media").toArray()) {
        QJsonObject m = v.toObject();
        const QString file = QDir(mediaDir).filePath(m.value("file").toString());
        if (!mediaDir.isEmpty() && QFileInfo::exists(file))
            m.insert("url", QUrl::fromLocalFile(file).toString());
        const QString poster = QDir(mediaDir).filePath(m.value("poster").toString());
        if (m.contains("poster") && QFileInfo::exists(poster))
            m.insert("posterUrl", QUrl::fromLocalFile(poster).toString());
        m.insert("taken_at", nowDt.addSecs(-qint64(m.value("hoursAgo").toDouble() * 3600)).toString(Qt::ISODate));
        m.insert("show_on_frame", m.value("kind").toString() == "photo");
        m_rawMedia << m.toVariantMap();
    }

    // Events and meals are stored relative to today so the demo always looks current.
    m_rawEvents.clear();
    for (const QJsonValue &v : root.value("events").toArray()) {
        QJsonObject e = v.toObject();
        const QDate day = base.addDays(e.value("dayOffset").toInt());
        const bool allDay = e.value("all_day").toBool();
        const QTime start = allDay ? QTime(0, 0) : QTime::fromString(e.value("start").toString(), "HH:mm");
        const QTime end = allDay ? QTime(23, 59) : QTime::fromString(e.value("end").toString(), "HH:mm");
        e.insert("starts_at", QDateTime(day, start).toString(Qt::ISODate));
        e.insert("ends_at", QDateTime(day, end).toString(Qt::ISODate));
        m_rawEvents << e.toVariantMap();
    }
    m_rawMeals.clear();
    for (const QJsonValue &v : root.value("meals").toArray()) {
        QJsonObject m = v.toObject();
        m.insert("date", base.addDays(m.value("dayOffset").toInt()).toString(Qt::ISODate));
        m_rawMeals << m.toVariantMap();
    }

    m_points.clear();
    const QJsonObject points = root.value("points").toObject();
    for (auto it = points.begin(); it != points.end(); ++it)
        m_points.insert(it.key(), it.value().toInt());

    m_completedToday.clear();
    rebuild();
}

// ───────────────────────────── Live data ─────────────────────────────

void FamilyStore::withSession(std::function<void()> fn)
{
    if (m_client->hasSession()) {
        fn();
        return;
    }
    const int generation = m_generation;
    m_client->refreshSession([this, fn, generation](bool ok) {
        if (generation != m_generation)
            return; // re-paired meanwhile
        if (ok)
            fn();
        else
            setOnline(false, tr("Can't reach Ohana cloud"));
    });
}

void FamilyStore::loadLive()
{
    if (m_mode != "live")
        return;
    withSession([this]() {
        // Rows that arrive after a re-pair belong to the old family, and rows
        // asked for before midnight to the old day: drop them.
        const int generation = m_generation;
        const QDate base = m_today;
        auto onError = [this](const QString &what, const QString &error) {
            qWarning() << "load" << what << "failed:" << error;
            setOnline(false, error);
        };
        using Apply = std::function<void(const QJsonDocument &)>;
        auto handler = [this, onError, generation, base](const QString &what, Apply apply) {
            return [this, what, apply, onError, generation, base](const QJsonDocument &doc, const QString &error) {
                if (generation != m_generation || base != m_today)
                    return;
                if (!error.isEmpty())
                    return onError(what, error);
                setOnline(true);
                apply(doc);
                rebuild();
            };
        };
        auto load = [this, handler](const QString &table, QUrlQuery q, Apply apply) {
            m_client->select(table, q, handler(table, apply));
        };
        auto call = [this, handler](const QString &function, const QJsonObject &args, Apply apply) {
            m_client->rpc(function, args, handler(function, apply));
        };

        checkIn();

        const QDate weekStart = base.addDays(1 - base.dayOfWeek());

        // The database works out repeats (PLATFORM_SPEC): one row per event
        // occurrence in the window, and the chores due today.
        const QJsonObject window{
            {"range_start", QDateTime(weekStart.addDays(-7), QTime(0, 0)).toUTC().toString(Qt::ISODate)},
            {"range_end", QDateTime(weekStart.addDays(35), QTime(0, 0)).toUTC().toString(Qt::ISODate)}};
        auto loadRepeats = [this, call, window, base](const QString &familyId) {
            QJsonObject events = window;
            events.insert("fid", familyId);
            call("event_occurrences", events, [this](const QJsonDocument &d) { m_rawEvents = toList(d); });
            call("chores_due", {{"fid", familyId}, {"day", base.toString(Qt::ISODate)}},
                 [this](const QJsonDocument &d) { m_rawTasks = toList(d); });
        };
        // Pairing saves the family id; a display paired before that learns it here.
        const QString familyId = m_settings.value("device/familyId").toString();
        load("families", QUrlQuery("select=id,name&limit=1"), [this, familyId, loadRepeats](const QJsonDocument &d) {
            const QJsonObject family = d.array().first().toObject();
            m_familyName = family.value("name").toString();
            const QString id = family.value("id").toString();
            if (familyId.isEmpty() && !id.isEmpty()) {
                m_settings.setValue("device/familyId", id);
                loadRepeats(id);
            }
        });
        if (!familyId.isEmpty())
            loadRepeats(familyId);

        load("members", QUrlQuery("select=*&order=sort_order"), [this](const QJsonDocument &d) { m_rawMembers = toList(d); });
        load("member_points", QUrlQuery("select=member_id,balance"), [this](const QJsonDocument &d) {
            m_points.clear();
            for (const QJsonValue &v : d.array())
                m_points.insert(v["member_id"].toString(), v["balance"].toInt());
        });
        load("task_completions", QUrlQuery("select=task_id,member_id,status&for_date=eq." + today()), [this](const QJsonDocument &d) {
            m_completedToday.clear();
            for (const QJsonValue &v : d.array())
                m_completedToday.insert(key(v["task_id"].toString(), v["member_id"].toString()), v["status"].toString());
        });
        load("rewards", QUrlQuery("select=*&active=eq.true&order=cost"), [this](const QJsonDocument &d) { m_rawRewards = toList(d); });

        QUrlQuery meals;
        meals.addQueryItem("select", "*");
        meals.addQueryItem("date", "gte." + weekStart.toString(Qt::ISODate));
        meals.addQueryItem("and", "(date.lt." + weekStart.addDays(14).toString(Qt::ISODate) + ")");
        load("meal_plans", meals, [this](const QJsonDocument &d) { m_rawMeals = toList(d); });

        load("lists", QUrlQuery("select=*,items:list_items(*)&order=sort_order&items.order=created_at.desc"), [this](const QJsonDocument &d) { m_rawLists = toList(d); });

        m_client->select("media_items",
                         QUrlQuery("select=*&order=taken_at.desc.nullslast,created_at.desc&limit=200"),
                         [this, generation](const QJsonDocument &d, const QString &error) {
                             if (!error.isEmpty() || generation != m_generation)
                                 return;
                             attachMediaUrls(toList(d), generation);
                         });
    });
}

// Signs Supabase paths and Blob paths separately, then keeps the row order.
// A URL signed earlier is reused until it's within an hour of expiring: a new
// URL string for the same file would make every image (and its color) load
// again on each sync. A missing media URL leaves Blob photos and videos with
// an empty url. Rows still in Supabase play.
void FamilyStore::attachMediaUrls(const QVariantList &rows, int generation)
{
    if (generation != m_generation)
        return;

    const QDateTime signedAt = now();
    QStringList keys;
    QSet<QString> listed;
    QList<int> storageAt, blobAt;
    QStringList storagePaths, blobPaths;
    for (int i = 0; i < rows.size(); ++i) {
        const QVariantMap row = rows.at(i).toMap();
        const QString store = row.value(QStringLiteral("file_store")).toString();
        const QString path = row.value(QStringLiteral("storage_path")).toString();
        const QString urlKey = store + QLatin1Char('|') + path;
        keys << urlKey;
        listed.insert(urlKey);
        const auto cached = m_signedUrls.constFind(urlKey);
        if (cached != m_signedUrls.cend() && cached->expires > signedAt.addSecs(kRenewUrlSecs))
            continue;
        if (store == QLatin1String("blob")) {
            blobAt << i;
            blobPaths << path;
        } else {
            storageAt << i;
            storagePaths << path;
        }
    }
    // Forget the URLs of media that's gone.
    for (auto it = m_signedUrls.begin(); it != m_signedUrls.end();)
        it = listed.contains(it.key()) ? std::next(it) : m_signedUrls.erase(it);

    struct Pending {
        QList<QString> urls;
        int remaining = 2;
    };
    const auto pending = std::make_shared<Pending>();
    pending->urls = QList<QString>(rows.size());

    const auto finish = [this, rows, keys, signedAt, generation, pending]() {
        if (--pending->remaining > 0 || generation != m_generation)
            return;
        const QDateTime current = now();
        m_rawMedia.clear();
        for (int i = 0; i < rows.size(); ++i) {
            QString url = pending->urls.at(i);
            const auto cached = m_signedUrls.constFind(keys.at(i));
            // Keep a URL that's still good: one not due for renewal (another
            // sync may have just signed it), or any unexpired one if signing failed.
            if (cached != m_signedUrls.cend()
                && cached->expires > (url.isEmpty() ? current : current.addSecs(kRenewUrlSecs)))
                url = cached->url;
            else if (!url.isEmpty())
                m_signedUrls.insert(keys.at(i), {url, signedAt.addSecs(kSignedUrlSecs)});
            QVariantMap item = rows.at(i).toMap();
            item.insert(QStringLiteral("url"), url);
            m_rawMedia << item;
        }
        rebuild();
    };

    m_client->signUrls(kMediaBucket, storagePaths, kSignedUrlSecs, [pending, storageAt, finish](const QStringList &urls) {
        for (int i = 0; i < storageAt.size() && i < urls.size(); ++i)
            pending->urls[storageAt.at(i)] = urls.at(i);
        finish();
    });

    if (blobPaths.isEmpty()) {
        finish();
        return;
    }
    if (m_mediaApiUrl.isEmpty()) {
        qWarning() << "HOMEOS_MEDIA_URL is not set; photos and videos in Blob storage have no playback URL";
        finish();
        return;
    }

    QJsonArray paths;
    for (const QString &path : blobPaths)
        paths << path;
    m_client->postAbsolute(QUrl(m_mediaApiUrl + QStringLiteral("/api/media/urls")),
                           QJsonObject{{QStringLiteral("paths"), paths}},
                           [pending, blobAt, finish](const QJsonDocument &doc, const QString &error) {
                               if (!error.isEmpty())
                                   qWarning() << "signing blob media failed:" << error;
                               const QJsonArray urls = doc.object().value(QStringLiteral("urls")).toArray();
                               for (int i = 0; i < blobAt.size() && i < urls.size(); ++i)
                                   pending->urls[blobAt.at(i)] = urls.at(i).toString();
                               finish();
                           });
}

// Signed URLs and photo colors belong to the family this display was paired with.
void FamilyStore::forgetMedia()
{
    m_signedUrls.clear();
    m_colors.clear();
}

// Tells the family's phones and the admin console this display is alive:
// devices.last_seen_at on its own row (RLS devices_touch), at most every few
// minutes.
void FamilyStore::checkIn()
{
    const QString deviceId = m_settings.value("device/id").toString();
    if (deviceId.isEmpty() || (m_lastCheckIn.isValid() && m_lastCheckIn.elapsed() < kCheckInIntervalMs))
        return;
    m_lastCheckIn.start();
    const QJsonObject seen{{"last_seen_at", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)}};
    m_client->update("devices", QUrlQuery("id=eq." + deviceId), seen, [](const QJsonDocument &, const QString &error) {
        if (!error.isEmpty())
            qWarning() << "device check-in failed:" << error;
    });
}

// ───────────────────────────── Actions ─────────────────────────────

void FamilyStore::completeTask(const QString &taskId, const QString &memberId)
{
    const QString k = key(taskId, memberId);
    // Only a parent can clear a try they turned down (the phone says the same).
    if (m_completedToday.value(k) == QLatin1String("rejected")) {
        emit notify(tr("A parent turned this one down today. Ask them to undo it, then try again."));
        return;
    }
    if (m_completedToday.contains(k))
        return;

    QVariantMap task;
    for (const QVariant &t : std::as_const(m_rawTasks))
        if (t.toMap().value("id").toString() == taskId)
            task = t.toMap();
    if (task.isEmpty())
        return;

    // Optimistic: the database applies the same rule in prepare_completion().
    const bool needsApproval = task.value("requires_approval").toBool();
    m_completedToday.insert(k, needsApproval ? "pending" : "approved");
    if (!needsApproval)
        m_points[memberId] += task.value("points").toInt();
    rebuild();

    if (m_mode != "live")
        return;
    const QJsonObject row{{"task_id", taskId}, {"member_id", memberId}, {"for_date", today()}};
    m_client->insert("task_completions", row, [this, k](const QJsonDocument &, const QString &error) {
        if (!error.isEmpty()) {
            m_completedToday.remove(k);
            emit notify(tr("Couldn't save that chore. Try again."));
        }
        loadLive();
    });
}

void FamilyStore::redeemReward(const QString &rewardId, const QString &memberId)
{
    QVariantMap reward;
    for (const QVariant &r : std::as_const(m_rawRewards))
        if (r.toMap().value("id").toString() == rewardId)
            reward = r.toMap();
    const int cost = reward.value("cost").toInt();
    const QString title = reward.value("title").toString();

    if (m_mode != "live") {
        if (m_points.value(memberId) < cost) {
            emit notify(tr("Not enough points yet"));
            return;
        }
        m_points[memberId] -= cost;
        rebuild();
        emit notify(tr("Redeemed: %1").arg(title));
        return;
    }

    m_client->rpc("redeem_reward", {{"reward", rewardId}, {"member", memberId}},
                  [this, title](const QJsonDocument &, const QString &error) {
                      if (!error.isEmpty())
                          emit notify(error.contains("not enough points") ? tr("Not enough points yet")
                                                                          : tr("Couldn't redeem. Try again."));
                      else
                          emit notify(tr("Redeemed: %1").arg(title));
                      loadLive();
                  });
}

void FamilyStore::setListItemDone(const QString &listId, const QString &itemId, bool done)
{
    for (QVariant &l : m_rawLists) {
        QVariantMap list = l.toMap();
        if (list.value("id").toString() != listId)
            continue;
        QVariantList items = list.value("items").toList();
        for (QVariant &i : items) {
            QVariantMap item = i.toMap();
            if (item.value("id").toString() == itemId) {
                item.insert("done", done);
                i = item;
            }
        }
        list.insert("items", items);
        l = list;
    }
    rebuild();

    if (m_mode == "live")
        m_client->update("list_items", QUrlQuery("id=eq." + itemId), {{"done", done}},
                         [this](const QJsonDocument &, const QString &error) {
                             if (!error.isEmpty())
                                 emit notify(tr("Couldn't update the list"));
                         });
}

void FamilyStore::addListItem(const QString &listId, const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed.isEmpty())
        return;
    const QString id = newId();
    for (QVariant &l : m_rawLists) {
        QVariantMap list = l.toMap();
        if (list.value("id").toString() != listId)
            continue;
        QVariantList items = list.value("items").toList();
        items.prepend(QVariantMap{{"id", id}, {"text", trimmed}, {"done", false}}); // newest first
        list.insert("items", items);
        l = list;
    }
    rebuild();

    if (m_mode == "live")
        m_client->insert("list_items", {{"id", id}, {"list_id", listId}, {"text", trimmed}},
                         [this](const QJsonDocument &, const QString &error) {
                             if (!error.isEmpty())
                                 emit notify(tr("Couldn't add to the list"));
                         });
}

void FamilyStore::addEvent(const QString &title, const QString &location,
                           const QString &startsAt, const QString &endsAt, bool allDay,
                           const QVariantList &memberIds)
{
    const QString trimmed = title.trimmed();
    if (trimmed.isEmpty())
        return;

    QDateTime start = parseTimestamp(startsAt);
    QDateTime end = parseTimestamp(endsAt);
    if (!start.isValid())
        return;
    if (!end.isValid() || end < start)
        end = allDay ? start.addSecs(24 * 3600 - 1) : start.addSecs(3600);

    QStringList ids;
    for (const QVariant &v : memberIds) {
        const QString id = v.toString().trimmed();
        if (!id.isEmpty() && !ids.contains(id))
            ids << id;
    }

    const QString id = newId();
    const QString familyId = m_settings.value(QStringLiteral("device/familyId")).toString();
    QVariantMap row{{"id", id},
                    {"title", trimmed},
                    {"location", location.trimmed()},
                    {"starts_at", start.toString(Qt::ISODate)},
                    {"ends_at", end.toString(Qt::ISODate)},
                    {"all_day", allDay},
                    {"member_ids", ids}};
    if (!familyId.isEmpty())
        row.insert(QStringLiteral("family_id"), familyId);

    m_rawEvents.prepend(row);
    rebuild();
    emit notify(tr("Added “%1”").arg(trimmed));

    if (m_mode != QLatin1String("live") || familyId.isEmpty())
        return;

    QJsonObject payload{{"id", id},
                        {"family_id", familyId},
                        {"title", trimmed},
                        {"starts_at", start.toUTC().toString(Qt::ISODate)},
                        {"ends_at", end.toUTC().toString(Qt::ISODate)},
                        {"all_day", allDay}};
    const QString place = location.trimmed();
    if (!place.isEmpty())
        payload.insert(QStringLiteral("location"), place);

    m_client->insert("events", payload, [this, id, ids](const QJsonDocument &, const QString &error) {
        if (!error.isEmpty()) {
            for (int i = 0; i < m_rawEvents.size(); ++i) {
                if (m_rawEvents.at(i).toMap().value(QStringLiteral("id")).toString() == id) {
                    m_rawEvents.removeAt(i);
                    break;
                }
            }
            rebuild();
            emit notify(tr("Couldn't save that event. Try again."));
            return;
        }
        if (ids.isEmpty()) {
            loadLive();
            return;
        }
        QJsonArray links;
        for (const QString &memberId : ids)
            links.append(QJsonObject{{"event_id", id}, {"member_id", memberId}});
        m_client->insert("event_members", links, [this](const QJsonDocument &, const QString &linkError) {
            if (!linkError.isEmpty())
                emit notify(tr("Event saved, but who it's for didn't stick. Try again."));
            loadLive();
        });
    });
}

void FamilyStore::addTask(const QString &title, const QString &icon, const QString &assigneeId,
                          int points, bool requiresApproval, const QString &rrule)
{
    const QString trimmed = title.trimmed();
    if (trimmed.isEmpty())
        return;

    // Device accounts aren't parents: tasks_guard refuses points that skip approval.
    const int safePoints = qMax(0, points);
    const bool safeApproval = (safePoints > 0) ? true : requiresApproval;
    const QString rule = rrule.trimmed().isEmpty() ? QStringLiteral("FREQ=DAILY") : rrule.trimmed();
    const QString id = newId();
    const QString familyId = m_settings.value(QStringLiteral("device/familyId")).toString();
    const QString assignee = assigneeId.trimmed();

    QVariantMap row{{"id", id},
                    {"title", trimmed},
                    {"icon", icon.trimmed().isEmpty() ? QStringLiteral("✔️") : icon.trimmed()},
                    {"assignee_id", assignee},
                    {"points", safePoints},
                    {"requires_approval", safeApproval},
                    {"rrule", rule},
                    {"archived", false}};
    if (!familyId.isEmpty())
        row.insert(QStringLiteral("family_id"), familyId);

    m_rawTasks.prepend(row);
    rebuild();
    emit notify(tr("Added “%1”").arg(trimmed));

    if (m_mode != QLatin1String("live") || familyId.isEmpty())
        return;

    QJsonObject payload{{"id", id},
                        {"family_id", familyId},
                        {"title", trimmed},
                        {"icon", row.value(QStringLiteral("icon")).toString()},
                        {"points", safePoints},
                        {"requires_approval", safeApproval},
                        {"rrule", rule}};
    if (!assignee.isEmpty())
        payload.insert(QStringLiteral("assignee_id"), assignee);

    m_client->insert("tasks", payload, [this, id](const QJsonDocument &, const QString &error) {
        if (!error.isEmpty()) {
            for (int i = 0; i < m_rawTasks.size(); ++i) {
                if (m_rawTasks.at(i).toMap().value(QStringLiteral("id")).toString() == id) {
                    m_rawTasks.removeAt(i);
                    break;
                }
            }
            rebuild();
            emit notify(tr("Couldn't save that chore. Try again."));
            return;
        }
        loadLive();
    });
}

void FamilyStore::addReward(const QString &title, const QString &icon, int cost)
{
    const QString trimmed = title.trimmed();
    if (trimmed.isEmpty() || cost <= 0)
        return;

    const QString id = newId();
    const QString familyId = m_settings.value(QStringLiteral("device/familyId")).toString();
    const QString emoji = icon.trimmed().isEmpty() ? QStringLiteral("🎁") : icon.trimmed();

    QVariantMap row{{"id", id},
                    {"title", trimmed},
                    {"icon", emoji},
                    {"cost", cost},
                    {"active", true}};
    if (!familyId.isEmpty())
        row.insert(QStringLiteral("family_id"), familyId);

    m_rawRewards.prepend(row);
    rebuild();
    emit notify(tr("Added “%1”").arg(trimmed));

    if (m_mode != QLatin1String("live") || familyId.isEmpty())
        return;

    m_client->insert("rewards",
                     QJsonObject{{"id", id},
                                 {"family_id", familyId},
                                 {"title", trimmed},
                                 {"icon", emoji},
                                 {"cost", cost}},
                     [this, id](const QJsonDocument &, const QString &error) {
                         if (!error.isEmpty()) {
                             for (int i = 0; i < m_rawRewards.size(); ++i) {
                                 if (m_rawRewards.at(i).toMap().value(QStringLiteral("id")).toString() == id) {
                                     m_rawRewards.removeAt(i);
                                     break;
                                 }
                             }
                             rebuild();
                             emit notify(tr("Couldn't save that reward. Try again."));
                             return;
                         }
                         loadLive();
                     });
}

// ───────────────────────────── Pairing ─────────────────────────────

void FamilyStore::startPairing()
{
    setMode("pairing");
    m_pairTimer.stop();
    m_pairRetryTimer.stop();
    const int attempt = ++m_pairAttempt;

    QByteArray secret(32, Qt::Uninitialized);
    QRandomGenerator::system()->fillRange(reinterpret_cast<quint32 *>(secret.data()), secret.size() / 4);
    m_pairingSecret = QString::fromLatin1(secret.toHex());
    const QString hash = QString::fromLatin1(
        QCryptographicHash::hash(m_pairingSecret.toUtf8(), QCryptographicHash::Sha256).toHex());

    m_client->callFunction("pair-device", {{"action", "start"}, {"secretHash", hash}},
                           [this, attempt](const QJsonDocument &doc, const QString &error) {
                               if (attempt != m_pairAttempt)
                                   return;
                               if (!error.isEmpty()) {
                                   setOnline(false, error);
                                   m_pairRetryTimer.start(); // offline: try again soon
                                   return;
                               }
                               setOnline(true);
                               m_pairingCode = doc.object().value("code").toString();
                               emit pairingChanged();
                               m_pairTimer.start();
                           });
}

void FamilyStore::unpair()
{
    if (m_mode == "demo") {
        emit notify(tr("Demo mode has nothing to pair"));
        return;
    }
    ++m_generation;
    m_syncTimer.stop();
    m_settings.remove("device/refreshToken");
    m_settings.remove("device/familyId");
    m_settings.remove("device/id");
    m_client->clearSession();

    // Drop the old family's data so none of it lingers behind the pairing screen.
    m_familyName.clear();
    m_rawMembers.clear();
    m_rawEvents.clear();
    m_rawTasks.clear();
    m_rawRewards.clear();
    m_rawMeals.clear();
    m_rawLists.clear();
    m_rawMedia.clear();
    m_completedToday.clear();
    m_points.clear();
    forgetMedia();
    rebuild();

    startPairing();
}

void FamilyStore::pollPairing()
{
    const int attempt = m_pairAttempt;
    m_client->callFunction(
        "pair-device", {{"action", "redeem"}, {"code", m_pairingCode}, {"secret", m_pairingSecret}},
        [this, attempt](const QJsonDocument &doc, const QString &error) {
            // A poll that overlapped the one that paired gets "invalid code"
            // (the code is gone): it must not start pairing over.
            if (attempt != m_pairAttempt || m_mode != "pairing")
                return;
            if (!error.isEmpty()) {
                // Expired or unknown code: show a fresh one.
                if (error.contains("HTTP 410") || error.contains("HTTP 404"))
                    startPairing();
                return;
            }
            const QJsonObject o = doc.object();
            if (o.value("status").toString() != "paired")
                return;

            m_pairTimer.stop();
            ++m_pairAttempt;
            const QJsonObject session = o.value("session").toObject();
            m_client->setSession(session.value("accessToken").toString(), session.value("refreshToken").toString());
            m_settings.setValue("device/familyId", o.value("familyId").toString());
            m_settings.setValue("device/id", o.value("deviceId").toString());
            m_lastCheckIn.invalidate(); // a new device row: check in right away
            m_pairingCode.clear();
            emit pairingChanged();

            setMode("live");
            loadLive();
            m_syncTimer.start();
            emit notify(tr("Display paired"));
        });
}

// ───────────────────────────── Shaping ─────────────────────────────

bool FamilyStore::occursOn(const QString &rrule, const QDate &day)
{
    if (rrule.isEmpty())
        return true;
    QHash<QString, QString> parts;
    for (const QString &p : rrule.split(';', Qt::SkipEmptyParts)) {
        const int eq = p.indexOf('=');
        if (eq > 0)
            parts.insert(p.left(eq).toUpper(), p.mid(eq + 1).toUpper());
    }
    const QString freq = parts.value("FREQ");
    if (freq == "WEEKLY" && parts.contains("BYDAY")) {
        static const QStringList codes{"MO", "TU", "WE", "TH", "FR", "SA", "SU"};
        return parts.value("BYDAY").split(',').contains(codes.at(day.dayOfWeek() - 1));
    }
    if (freq == "MONTHLY" && parts.contains("BYMONTHDAY"))
        return parts.value("BYMONTHDAY").split(',').contains(QString::number(day.day()));
    // Anything else counts as daily. Fine for the demo; live data never gets here.
    return true;
}

void FamilyStore::rebuild()
{
    const QDate today = m_today;
    QHash<QString, QVariantMap> memberById;
    for (const QVariant &m : std::as_const(m_rawMembers))
        memberById.insert(m.toMap().value("id").toString(), m.toMap());

    // Tasks due today, with their state for the assignee.
    m_tasks.clear();
    QHash<QString, int> total, done;
    for (const QVariant &v : std::as_const(m_rawTasks)) {
        QVariantMap t = v.toMap();
        if (t.value("archived").toBool())
            continue;
        // Live rows are already the day's chores (chores_due on the server).
        if (m_mode != "live") {
            const QString rrule = t.value("rrule").toString();
            const QDate due = QDate::fromString(t.value("due_date").toString(), Qt::ISODate);
            const bool dueToday = rrule.isEmpty() ? (!due.isValid() || due <= today) : occursOn(rrule, today);
            if (!dueToday)
                continue;
        }

        const QString assignee = t.value("assignee_id").toString();
        const QString status = m_completedToday.value(key(t.value("id").toString(), assignee), "todo");
        const QVariantMap member = memberById.value(assignee);
        t.insert("status", status == "approved" ? "done" : status); // todo | pending | done | rejected
        t.insert("assigneeName", member.value("display_name"));
        t.insert("color", member.value("color", "#8E8E93"));
        m_tasks << t;

        total[assignee] += 1;
        if (status == "approved" || status == "pending")
            done[assignee] += 1;
    }

    m_members.clear();
    for (const QVariant &v : std::as_const(m_rawMembers)) {
        QVariantMap m = v.toMap();
        const QString id = m.value("id").toString();
        m.insert("points", m_points.value(id));
        m.insert("tasksTotal", total.value(id));
        m.insert("tasksDone", done.value(id));
        m.insert("initial", m.value("display_name").toString().left(1).toUpper());
        QColor c(m.value("color").toString());
        m.insert("inkColor", c.darker(175).name());
        c.setAlphaF(0.28);
        m.insert("tintColor", c.name(QColor::HexArgb));
        m_members << m;
    }

    m_events.clear();
    for (const QVariant &v : std::as_const(m_rawEvents)) {
        QVariantMap e = v.toMap();
        const QDateTime start = parseTimestamp(e.value("starts_at").toString());
        const QDateTime end = parseTimestamp(e.value("ends_at").toString());
        const QStringList ids = e.value("member_ids").toStringList();
        QString color = e.value("color").toString();
        if (color.isEmpty() && !ids.isEmpty())
            color = memberById.value(ids.first()).value("color").toString();
        QStringList names;
        for (const QString &id : ids)
            names << memberById.value(id).value("display_name").toString();

        e.insert("day", start.date().toString(Qt::ISODate));
        e.insert("startMs", start.toMSecsSinceEpoch());
        e.insert("timeLabel", e.value("all_day").toBool()
                                  ? tr("All day")
                                  : QLocale().toString(start.time(), "h:mm ap") + " – " + QLocale().toString(end.time(), "h:mm ap"));
        QColor tint(color.isEmpty() ? QStringLiteral("#7C6CF2") : color);
        e.insert("displayColor", tint.name());
        e.insert("inkColor", tint.darker(175).name()); // readable text on the pastel block
        tint.setAlphaF(0.28);
        e.insert("tintColor", tint.name(QColor::HexArgb));
        e.insert("memberNames", names.join(", "));
        m_events << e;
    }
    std::sort(m_events.begin(), m_events.end(), [](const QVariant &a, const QVariant &b) {
        const QVariantMap ma = a.toMap(), mb = b.toMap();
        if (ma.value("all_day").toBool() != mb.value("all_day").toBool())
            return ma.value("all_day").toBool();
        return ma.value("startMs").toLongLong() < mb.value("startMs").toLongLong();
    });

    m_rewards = m_rawRewards;
    m_meals = m_rawMeals;
    m_lists = m_rawLists;
    // Media: newest first, with display labels and a color for dynamic tints.
    m_media.clear();
    m_photos.clear();
    QHash<QString, QString> nameById;
    for (const QVariant &v : std::as_const(m_rawMembers))
        nameById.insert(v.toMap().value("id").toString(), v.toMap().value("display_name").toString());
    for (const QVariant &v : std::as_const(m_rawMedia)) {
        QVariantMap m = v.toMap();
        const bool isVideo = m.value("kind").toString() == "video";
        const QDateTime taken = parseTimestamp(m.value("taken_at", m.value("created_at")).toString());
        m.insert("takenMs", taken.toMSecsSinceEpoch());
        m.insert("monthLabel", taken.date().year() == today.year() ? QLocale().toString(taken.date(), "MMMM")
                                                                    : QLocale().toString(taken.date(), "MMMM yyyy"));
        m.insert("dateLabel", taken.date() == today ? tr("Today")
                              : taken.date() == today.addDays(-1) ? tr("Yesterday")
                                                                  : QLocale().toString(taken.date(), "dddd, MMMM d"));
        const int secs = qRound(m.value("duration_seconds").toDouble());
        m.insert("durationLabel", secs > 0 ? QStringLiteral("%1:%2").arg(secs / 60).arg(secs % 60, 2, 10, QChar('0')) : QString());
        m.insert("uploaderName", nameById.value(m.value("uploaded_by").toString()));

        const QString imageUrl = isVideo ? m.value("posterUrl").toString() : m.value("url").toString();
        // By id, not URL: a renewed signed URL is still the same photo. (Demo
        // media has no id; its file URLs never change.)
        const QString colorKey = m.value("id").toString().isEmpty() ? imageUrl : m.value("id").toString();
        QColor tint = m_colors.cached(colorKey);
        if (!tint.isValid())
            m_colors.sample(colorKey, imageUrl);
        m.insert("imageUrl", imageUrl);
        if (!tint.isValid())
            tint = QColor(m.value("color").toString());
        if (!tint.isValid())
            tint = QColor("#5B7CF5");
        m.insert("tint", tint.name());
        m.insert("tintDeep", tint.darker(260).name());
        m_media << m;
        if (!isVideo && m.value("show_on_frame", true).toBool())
            m_photos << m;
    }
    std::stable_sort(m_media.begin(), m_media.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("takenMs").toLongLong() > b.toMap().value("takenMs").toLongLong();
    });
    emit dataChanged();
}

void FamilyStore::scheduleRebuild()
{
    if (m_rebuildQueued)
        return;
    m_rebuildQueued = true;
    QTimer::singleShot(50, this, [this]() {
        m_rebuildQueued = false;
        rebuild();
    });
}

QString FamilyStore::demoMediaDir()
{
    const QString fromEnv = qEnvironmentVariable("HOMEOS_DEMO_MEDIA");
    if (!fromEnv.isEmpty())
        return fromEnv;
    const QDir app(QCoreApplication::applicationDirPath());
    for (const QString &candidate : {app.filePath("demo-media"), app.filePath("../share/homeos/demo-media")}) {
        if (QFileInfo(candidate).isDir())
            return QDir(candidate).absolutePath();
    }
    return {};
}
