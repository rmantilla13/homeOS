import Foundation
import Supabase

// Connected calendars (docs/PLATFORM_SPEC.md §1.13, §2.5).
//
// In: a parent connects a Google account or adds a calendar link (iCloud,
// Outlook, a school or team calendar). The `calendar-sync` function copies
// their events into the family calendar as read-only events, refreshed
// about every 15 minutes. Out: the family's own events as a link that Apple
// Calendar, Google Calendar or Outlook can subscribe to.

// MARK: Models

/// A calendar whose events are copied into the family calendar: one of a
/// connected Google account's calendars, or a calendar link (ICS / webcal).
struct CalendarSource: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    /// "google" or "ics" (a calendar link).
    var provider: String
    var accountId: UUID?
    /// A link's host ("p52-caldav.icloud.com"). The link itself stays on the server.
    var urlHost: String?
    var name: String
    /// "#RRGGBB"; nil uses the person's color.
    var color: String?
    /// Who the events are for; nil is the whole family.
    var memberId: UUID?
    /// Events show as "Busy", without titles or places.
    var busyOnly: Bool
    var enabled: Bool
    var lastAttemptAt: Date?
    var lastSyncedAt: Date?
    /// Why the last sync failed, in words a parent can act on.
    var lastError: String?
    var eventCount: Int

    enum CodingKeys: String, CodingKey {
        case id, provider, name, color, enabled
        case familyId = "family_id"
        case accountId = "account_id"
        case urlHost = "url_host"
        case memberId = "member_id"
        case busyOnly = "busy_only"
        case lastAttemptAt = "last_attempt_at"
        case lastSyncedAt = "last_synced_at"
        case lastError = "last_error"
        case eventCount = "event_count"
    }

    var isGoogle: Bool { provider == "google" }
}

/// A Google account a parent connected for the family.
struct CalendarAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var email: String
    /// Google stopped accepting Ohana's access (revoked, password changed).
    var needsReconnect: Bool

    enum CodingKeys: String, CodingKey {
        case id, email
        case needsReconnect = "needs_reconnect"
    }
}

/// One of a Google account's calendars, as calendar-sync lists them.
struct GoogleCalendarChoice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let primary: Bool
    /// Already connected to this family.
    let added: Bool
}

/// What calendar-sync answers for each calendar it synced.
struct CalendarSyncResult: Decodable {
    let source_id: UUID
    let ok: Bool
    let added: Int?
    let updated: Int?
    let removed: Int?
    let error: String?

    var changed: Bool { (added ?? 0) + (updated ?? 0) + (removed ?? 0) > 0 }
}

/// A source's editable settings. Nulls are sent, so a color or person can be cleared.
private struct CalendarSourcePatch: Encodable {
    let name: String
    let color: String?
    let memberId: UUID?
    let busyOnly: Bool
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, color, enabled
        case memberId = "member_id"
        case busyOnly = "busy_only"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let color { try container.encode(color, forKey: .color) } else { try container.encodeNil(forKey: .color) }
        if let memberId { try container.encode(memberId, forKey: .memberId) } else { try container.encodeNil(forKey: .memberId) }
        try container.encode(busyOnly, forKey: .busyOnly)
        try container.encode(enabled, forKey: .enabled)
    }
}

// MARK: Store

extension FamilyStore {
    private static let syncFunction = "calendar-sync"
    private static let sourceColumns = "id, family_id, provider, account_id, url_host, name, color, member_id, busy_only, "
        + "enabled, last_attempt_at, last_synced_at, last_error, event_count"

    func calendarSource(_ id: UUID?) -> CalendarSource? { calendarSources.first { $0.id == id } }
    func calendarAccount(_ id: UUID?) -> CalendarAccount? { calendarAccounts.first { $0.id == id } }

    /// Where a calendar comes from: "Google · mom@gmail.com", or a link's host.
    func calendarOrigin(of source: CalendarSource) -> String {
        if source.isGoogle {
            guard let account = calendarAccount(source.accountId) else { return "Google" }
            return "Google · \(account.email)"
        }
        return source.urlHost ?? "Calendar link"
    }

    /// A palette color no connected calendar uses yet, for a new one.
    var nextCalendarColor: String {
        let used = Set(calendarSources.compactMap { $0.color?.uppercased() })
        return memberPalette.first { !used.contains($0.uppercased()) } ?? memberPalette[calendarSources.count % memberPalette.count]
    }

    /// The family's connected calendars, and for parents the Google accounts
    /// and the shared link. Quiet on failure: calendars are extra, and a
    /// server without calendar sync yet shouldn't put up an alert on every refresh.
    func loadCalendars() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard let family else { return }
        let fid = family.id.uuidString
        do {
            let sources: [CalendarSource] = try await supabase.from("calendar_sources").select(Self.sourceColumns)
                .eq("family_id", value: fid).order("created_at").execute().value
            var accounts: [CalendarAccount] = []
            var feedURL: URL?
            if isParent {
                struct Feed: Decodable { let token: String }
                accounts = try await supabase.from("calendar_accounts").select("id, email, needs_reconnect")
                    .eq("family_id", value: fid).order("created_at").execute().value
                let feeds: [Feed] = try await supabase.from("calendar_feeds").select("token")
                    .eq("family_id", value: fid).execute().value
                feedURL = feeds.first.map { Self.feedURL(token: $0.token) }
            }
            guard self.family?.id == family.id else { return }
            calendarSources = sources
            calendarAccounts = accounts
            calendarFeedURL = feedURL
        } catch {
            print("OhanaOS: couldn't load connected calendars:", error)
        }
    }

    /// Asks the server to refresh calendars that haven't synced for a while
    /// (it skips any refreshed in the last 10 minutes), then reloads if
    /// anything changed. Opening the app keeps calendars current even where
    /// the server's 15-minute schedule isn't set up.
    func refreshStaleCalendars() {
        guard let family else { return }
        let staleBefore = Date.now.addingTimeInterval(-15 * 60)
        guard calendarSources.contains(where: { $0.enabled && ($0.lastAttemptAt ?? .distantPast) < staleBefore }),
              (calendarsNudgedAt ?? .distantPast) < .now.addingTimeInterval(-10 * 60) else { return }
        calendarsNudgedAt = .now
        Task {
            let results = try? await self.runCalendarSync(familyId: family.id, sourceId: nil, force: false)
            if results?.contains(where: \.changed) == true {
                await self.refresh()
            } else {
                await self.loadCalendars()
            }
        }
    }

    /// "Sync now", for every connected calendar or just `source`. Returns
    /// whether all of them synced; a failure shows on that calendar's row.
    @discardableResult
    func syncCalendars(_ source: CalendarSource? = nil) async -> Bool {
        guard let family else { return false }
        #if DEBUG
        if DemoMode.isOn { return true }
        #endif
        do {
            let results = try await runCalendarSync(familyId: source == nil ? family.id : nil, sourceId: source?.id, force: true)
            if results.contains(where: \.changed) { await refresh() } else { await loadCalendars() }
            return results.allSatisfy(\.ok)
        } catch {
            report(error)
            return false
        }
    }

    private func runCalendarSync(familyId: UUID?, sourceId: UUID?, force: Bool) async throws -> [CalendarSyncResult] {
        struct Body: Encodable {
            let action = "sync"
            let family_id: UUID?
            let source_id: UUID?
            let force: Bool
        }
        struct Reply: Decodable { let results: [CalendarSyncResult] }
        let reply: Reply = try await supabase.functions.invoke(
            Self.syncFunction, options: FunctionInvokeOptions(body: Body(family_id: familyId, source_id: sourceId, force: force)))
        return reply.results
    }

    /// The reply to adding a calendar: it was added, and maybe its first sync failed.
    private struct AddedCalendar: Decodable {
        let source_id: UUID
        let name: String
        let event_count: Int
        let sync_error: String?
    }

    /// Adds a calendar link (webcal:// or https://). The server reads it first,
    /// so a link that isn't a calendar is refused with a reason.
    func addCalendarLink(_ url: String, name: String?, color: String?, memberId: UUID?, busyOnly: Bool) async -> Bool {
        struct Body: Encodable {
            let action = "add_link"
            let family_id: UUID
            let url: String
            let name: String?
            let color: String?
            let member_id: UUID?
            let busy_only: Bool
        }
        guard let family else { return false }
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        do {
            let added: AddedCalendar = try await supabase.functions.invoke(Self.syncFunction, options: FunctionInvokeOptions(
                body: Body(family_id: family.id, url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                           name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                           color: color, member_id: memberId, busy_only: busyOnly)))
            if let problem = added.sync_error {
                errorMessage = "\(added.name) was added, but its events couldn't be copied yet: \(problem)"
            }
            await refresh()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Google

    /// Where to send the parent to sign in to Google and allow read-only calendar access.
    func googleSignInURL() async -> URL? {
        struct Body: Encodable {
            let action = "google_start"
            let family_id: UUID
        }
        struct Reply: Decodable { let url: URL }
        guard let family else { return nil }
        #if DEBUG
        if DemoMode.isOn { return nil }
        #endif
        do {
            let reply: Reply = try await supabase.functions.invoke(
                Self.syncFunction, options: FunctionInvokeOptions(body: Body(family_id: family.id)))
            return reply.url
        } catch {
            report(error)
            return nil
        }
    }

    /// Reads calendar-sync's redirect back to the app
    /// (`ohanaos://google-calendar?account_id=…&email=…`, or `?error=…`).
    func connectedGoogleAccount(from callback: URL) async -> CalendarAccount? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }
        if let problem = value("error") {
            errorMessage = problem
            return nil
        }
        guard let id = value("account_id").flatMap(UUID.init(uuidString:)) else {
            errorMessage = "Google didn't finish connecting. Try again."
            return nil
        }
        await loadCalendars()
        return calendarAccount(id) ?? CalendarAccount(id: id, email: value("email") ?? "Google", needsReconnect: false)
    }

    /// The calendars a connected Google account can see.
    func googleCalendars(in account: CalendarAccount) async -> [GoogleCalendarChoice]? {
        struct Body: Encodable {
            let action = "google_calendars"
            let account_id: UUID
        }
        struct Reply: Decodable { let calendars: [GoogleCalendarChoice] }
        #if DEBUG
        if DemoMode.isOn { return nil }
        #endif
        do {
            let reply: Reply = try await supabase.functions.invoke(
                Self.syncFunction, options: FunctionInvokeOptions(body: Body(account_id: account.id)))
            return reply.calendars
        } catch {
            report(error)
            await loadCalendars()  // the account may need reconnecting now
            return nil
        }
    }

    /// Connects Google calendars, each in its own Google color. Returns how many went in.
    func addGoogleCalendars(_ choices: [GoogleCalendarChoice], from account: CalendarAccount) async -> Int {
        struct Body: Encodable {
            let action = "add_google"
            let account_id: UUID
            let calendar_id: String
        }
        #if DEBUG
        if DemoMode.isOn { return 0 }
        #endif
        var added = 0
        var problems: [String] = []
        for choice in choices {
            do {
                let reply: AddedCalendar = try await supabase.functions.invoke(
                    Self.syncFunction, options: FunctionInvokeOptions(body: Body(account_id: account.id, calendar_id: choice.id)))
                added += 1
                if let problem = reply.sync_error { problems.append("\(reply.name): \(problem)") }
            } catch {
                report(error)
            }
        }
        if !problems.isEmpty {
            errorMessage = "Added, but some events couldn't be copied yet. " + problems.joined(separator: " ")
        }
        await refresh()
        return added
    }

    /// Disconnects a Google account: Google forgets Ohana's access, and its
    /// calendars and their events leave the family calendar.
    func disconnectGoogle(_ account: CalendarAccount) async {
        struct Body: Encodable {
            let action = "disconnect_google"
            let account_id: UUID
        }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        calendarAccounts.removeAll { $0.id == account.id }
        calendarSources.removeAll { $0.accountId == account.id }
        do {
            try await supabase.functions.invoke(Self.syncFunction, options: FunctionInvokeOptions(body: Body(account_id: account.id)))
        } catch {
            report(error)
        }
        await refresh()
    }

    // MARK: Settings

    /// Saves a calendar's name, color, person, privacy and on/off. Turning
    /// "Busy" off, or the calendar back on, copies its events again at once.
    func updateCalendarSource(_ source: CalendarSource, name: String, color: String?, memberId: UUID?,
                              busyOnly: Bool, enabled: Bool) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if let i = calendarSources.firstIndex(where: { $0.id == source.id }) {
            calendarSources[i].name = name
            calendarSources[i].color = color
            calendarSources[i].memberId = memberId
            calendarSources[i].busyOnly = busyOnly
            calendarSources[i].enabled = enabled
        }
        #if DEBUG
        if DemoMode.isOn { return true }
        #endif
        do {
            try await supabase.from("calendar_sources")
                .update(CalendarSourcePatch(name: name, color: color, memberId: memberId, busyOnly: busyOnly, enabled: enabled))
                .eq("id", value: source.id.uuidString)
                .execute()
        } catch {
            report(error)
            await loadCalendars()
            return false
        }
        let needsEvents = (source.busyOnly && !busyOnly) || (!source.enabled && enabled)
        if needsEvents, let fresh = calendarSource(source.id) {
            await syncCalendars(fresh)
        } else {
            await refresh()
        }
        return true
    }

    /// Removes a calendar and the events copied from it. The calendar itself isn't touched.
    func removeCalendarSource(_ source: CalendarSource) async {
        calendarSources.removeAll { $0.id == source.id }
        events.removeAll { $0.sourceId == source.id }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            try await supabase.from("calendar_sources").delete().eq("id", value: source.id.uuidString).execute()
        } catch {
            report(error)
        }
        await refresh()
    }

    // MARK: Sharing the family calendar

    /// The family calendar's subscribable link: made on first use, replaced with `newLink`.
    func shareFamilyCalendar(newLink: Bool = false) async {
        struct Params: Encodable {
            let family: UUID
            let rotate: Bool
        }
        guard let family else { return }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            let token: String = try await supabase.rpc("calendar_feed_token", params: Params(family: family.id, rotate: newLink))
                .execute().value
            calendarFeedURL = Self.feedURL(token: token)
        } catch {
            report(error)
        }
    }

    /// Turns the link off: calendars subscribed to it stop updating.
    func stopSharingFamilyCalendar() async {
        guard let family else { return }
        calendarFeedURL = nil
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            try await supabase.from("calendar_feeds").delete().eq("family_id", value: family.id.uuidString).execute()
        } catch {
            report(error)
            await loadCalendars()
        }
    }

    static func feedURL(token: String) -> URL {
        Config.supabaseURL.appendingPathComponent("functions/v1/calendar-sync/feed/\(token).ics")
    }
}

extension URL {
    /// webcal:// for an https:// calendar link, which opens Calendar's Subscribe sheet.
    var webcal: URL {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        parts.scheme = "webcal"
        return parts.url ?? self
    }

    /// Google Calendar's "add this calendar" page for a calendar link.
    var googleCalendarSubscribe: URL {
        var parts = URLComponents(string: "https://calendar.google.com/calendar/r")!
        parts.queryItems = [URLQueryItem(name: "cid", value: webcal.absoluteString)]
        return parts.url!
    }
}
