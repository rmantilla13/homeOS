import AuthenticationServices
import SwiftUI
import UIKit

/// Calendars from elsewhere on the family calendar (Google, iCloud, Outlook,
/// school and team calendars), and the family calendar in other apps.
/// Everyone sees what comes in; parents add, change and remove calendars.
struct ConnectedCalendarsView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// Shown in a sheet (from the Calendar tab), so it needs its own Done.
    var inSheet = false

    @State private var addingLink = false
    @State private var picking: CalendarAccount?
    @State private var editing: CalendarSource?
    @State private var disconnecting: CalendarAccount?
    @State private var connecting = false
    @State private var syncing = false

    var body: some View {
        Form {
            Section {
                if store.calendarSources.isEmpty {
                    Text(store.isParent ? "No calendars yet. Add one below." : "No calendars connected yet.")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(store.calendarSources) { source in
                    Button { editing = source } label: { CalendarSourceRow(source: source) }
                        .disabled(!store.isParent)
                }
                if !store.calendarSources.isEmpty {
                    Button {
                        Task {
                            syncing = true
                            await store.syncCalendars()
                            syncing = false
                        }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if syncing { ProgressView() }
                        }
                    }
                    .disabled(syncing)
                }
            } header: {
                Text("Showing in Ohana")
            } footer: {
                Text("Events from these calendars appear on the family calendar and the wall display, and update about every 15 minutes. "
                     + (store.isParent ? "To change an event, change it in the calendar it comes from."
                                       : "A parent can add or remove calendars."))
            }

            if store.isParent {
                Section {
                    Button { Task { await connectGoogle() } } label: {
                        HStack {
                            Label("Connect Google Calendar", systemImage: "g.circle")
                            Spacer()
                            if connecting { ProgressView() }
                        }
                    }
                    .disabled(connecting)
                    Button { addingLink = true } label: {
                        Label("Add a calendar link", systemImage: "link")
                    }
                } header: {
                    Text("Add a calendar")
                } footer: {
                    Text("Sign in to Google to pick from your Google calendars. Use a link for iCloud, Outlook, school, sports and holiday calendars.")
                }

                if !store.calendarAccounts.isEmpty {
                    Section {
                        ForEach(store.calendarAccounts) { account in
                            accountRow(account)
                        }
                    } header: {
                        Text("Google accounts")
                    } footer: {
                        Text("Ohana can only read these calendars, never change them.")
                    }
                }

                ShareFamilyCalendarSection()
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Connected calendars")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .refreshable { await store.syncCalendars() }
        .task { await store.loadCalendars() }
        .animation(Theme.springy, value: store.calendarSources)
        .sheet(isPresented: $addingLink) { AddCalendarLinkView() }
        .sheet(item: $picking) { GoogleCalendarPicker(account: $0) }
        .sheet(item: $editing) { CalendarSourceEditor(source: $0) }
        .confirmationDialog("Disconnect \(disconnecting?.email ?? "this account")?",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let account = disconnecting {
                    Task { await store.disconnectGoogle(account) }
                }
            }
        } message: {
            Text("Its calendars and their events leave the family calendar, and Ohana loses access to the account. Nothing changes in Google Calendar.")
        }
        .showsStoreErrors()
    }

    private func accountRow(_ account: CalendarAccount) -> some View {
        let count = store.calendarSources.filter { $0.accountId == account.id }.count
        let mine = store.isMine(account)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if account.needsReconnect {
                    Label("Google needs you to sign in again", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                } else {
                    Text(count == 1 ? "1 calendar showing" : "\(count) calendars showing")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                if !mine {
                    Text("Connected by \(connectedBy(account)). Only they can choose its calendars.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 18) {
                if mine {
                    if account.needsReconnect {
                        Button("Sign in again") { Task { await connectGoogle() } }
                    } else {
                        Button("Choose calendars") { picking = account }
                    }
                }
                Spacer()
                Button("Disconnect", role: .destructive) { disconnecting = account }
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private func connectedBy(_ account: CalendarAccount) -> String {
        store.profile(for: account.createdBy)?.displayName.nilIfEmpty
            ?? store.members.first { $0.userId == account.createdBy }?.displayName
            ?? "another parent"
    }

    /// Google sign-in in a browser sheet. calendar-sync sends the browser
    /// back to ohanaos://google-calendar, which ends the sheet, and the app
    /// finishes the sign-in with its own session.
    private func connectGoogle() async {
        connecting = true
        defer { connecting = false }
        guard let url = await store.googleSignInURL() else { return }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: Config.urlScheme)
            if let account = await store.finishGoogleSignIn(from: callback) {
                picking = account
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

/// A connected calendar: its color, where it comes from, and how syncing went.
struct CalendarSourceRow: View {
    @Environment(FamilyStore.self) private var store
    let source: CalendarSource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 14, height: 14)
                .padding(.top, 4)
                .opacity(source.enabled ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(source.enabled ? Theme.text : Theme.muted)
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                status
            }
            Spacer(minLength: 0)
            if store.isParent {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        if let hex = source.color { return Color(hex: hex) }
        if let member = store.member(source.memberId) { return Color(hex: member.color) }
        return Theme.accent
    }

    /// "Google · mom@gmail.com · For Leo · Busy only"
    private var origin: String {
        var parts: [String] = [store.calendarOrigin(of: source)]
        if let member = store.member(source.memberId) { parts.append("For \(member.displayName)") }
        if source.busyOnly { parts.append("Busy only") }
        return parts.joined(separator: " · ")
    }

    /// "12 events · updated 5 minutes ago"
    private func updatedLine(_ synced: Date) -> String {
        let count = source.eventCount == 1 ? "1 event" : "\(source.eventCount) events"
        return "\(count) · updated \(synced.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder private var status: some View {
        if !source.enabled {
            Text("Off: its events aren't showing")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        } else {
            if let problem = source.lastError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            if let synced = source.lastSyncedAt {
                Text(updatedLine(synced))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            } else if source.lastError == nil {
                Text("Getting its events…")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Adding a link

/// A calendar link: iCloud public calendars, Outlook, Google's secret
/// address, school, team and holiday calendars.
struct AddCalendarLinkView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @State private var color = ""
    @State private var memberId: UUID?
    @State private var busyOnly = false
    @State private var working = false

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("webcal:// or https:// link", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Ohana checks the link now and then keeps its events up to date. Leave the name empty to use the calendar's own.")
                }
                Section {
                    Picker("Who it's for", selection: $memberId) {
                        Text("Everyone").tag(UUID?.none)
                        ForEach(store.members) { member in
                            Text(member.displayName).tag(Optional(member.id))
                        }
                    }
                    Toggle("Show as Busy", isOn: $busyOnly)
                } footer: {
                    Text("Busy shows only when something is on, without titles or places. Handy for a work calendar.")
                }
                Section("Color") {
                    ColorPalettePicker(selection: $color)
                }
                Section {
                    DisclosureGroup("iCloud (Apple Calendar)") {
                        help("On iPhone, open Calendar and tap Calendars. Tap ⓘ next to the calendar, turn on Public Calendar, then tap Share Link and Copy.")
                    }
                    DisclosureGroup("Google Calendar") {
                        help("Easiest: go back and tap Connect Google Calendar. Or, on a computer, open Google Calendar's Settings, pick the calendar, and under Integrate calendar copy the Secret address in iCal format.")
                    }
                    DisclosureGroup("Outlook") {
                        help("In Outlook on the web, open Settings → Calendar → Shared calendars. Under Publish a calendar, choose the calendar and Can view all details, select Publish, then copy the ICS link.")
                    }
                    DisclosureGroup("School, sports and holidays") {
                        help("On their calendar page, look for Subscribe, Add to calendar, iCal, ICS or webcal, and copy that link.")
                    }
                } header: {
                    Text("Where to find a calendar link")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Add a calendar link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add") {
                            working = true
                            Task {
                                let added = await store.addCalendarLink(trimmedLink, name: name, color: color.nilIfEmpty,
                                                                        memberId: memberId, busyOnly: busyOnly)
                                working = false
                                if added { dismiss() }
                            }
                        }
                        .disabled(trimmedLink.isEmpty)
                    }
                }
            }
            .onAppear { if color.isEmpty { color = store.nextCalendarColor } }
            .interactiveDismissDisabled(working)
            .showsStoreErrors()  // a refused link keeps this sheet open, with the reason
        }
    }

    private func help(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Google

/// After signing in to Google: which of the account's calendars to show.
struct GoogleCalendarPicker: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: CalendarAccount
    @State private var calendars: [GoogleCalendarChoice]?
    @State private var selected: Set<String> = []
    @State private var failed = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if let calendars {
                    Section {
                        ForEach(calendars) { calendar in
                            Button { toggle(calendar) } label: { row(calendar) }
                                .disabled(calendar.added)
                        }
                    } header: {
                        Text(account.email)
                    } footer: {
                        Text("Events from these calendars show on the family calendar and the wall display. Private events show as Busy. You can change each calendar's color, who it's for, or show all of it as Busy afterwards.")
                    }
                } else if failed {
                    Section {
                        Text("Couldn't load this account's calendars.")
                            .foregroundStyle(Theme.muted)
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading calendars…").foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Choose calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(selected.count > 1 ? "Add \(selected.count)" : "Add") {
                            working = true
                            Task {
                                let chosen = (calendars ?? []).filter { selected.contains($0.id) }
                                _ = await store.addGoogleCalendars(chosen, from: account)
                                working = false
                                dismiss()
                            }
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .task { await load() }
            .showsStoreErrors()
        }
    }

    private func row(_ calendar: GoogleCalendarChoice) -> some View {
        HStack(spacing: 12) {
            Circle().fill(calendar.color.map { Color(hex: $0) } ?? Theme.accent).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.name).foregroundStyle(Theme.text)
                if calendar.primary {
                    Text("Main calendar").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if calendar.added {
                Text("Added").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            } else {
                Image(systemName: selected.contains(calendar.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(calendar.id) ? Theme.accent : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ calendar: GoogleCalendarChoice) {
        withAnimation(Theme.springy) {
            if selected.contains(calendar.id) { selected.remove(calendar.id) } else { selected.insert(calendar.id) }
        }
    }

    private func load() async {
        failed = false
        guard let list = await store.googleCalendars(in: account) else {
            failed = true
            return
        }
        calendars = list
        // First time for this account: start with its main calendar ticked.
        if selected.isEmpty, !list.contains(where: \.added), let main = list.first(where: \.primary) {
            selected = [main.id]
        }
    }
}

// MARK: - One calendar's settings

/// A parent changes a connected calendar's name, person, privacy, color and
/// on/off, syncs it now, or removes it.
struct CalendarSourceEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: CalendarSource
    @State private var name: String
    /// "" uses the person's color.
    @State private var color: String
    @State private var memberId: UUID?
    @State private var busyOnly: Bool
    @State private var enabled: Bool
    @State private var saving = false
    @State private var syncing = false
    @State private var confirmingRemove = false

    init(source: CalendarSource) {
        self.source = source
        _name = State(initialValue: source.name)
        _color = State(initialValue: source.color ?? "")
        _memberId = State(initialValue: source.memberId)
        _busyOnly = State(initialValue: source.busyOnly)
        _enabled = State(initialValue: source.enabled)
    }

    /// The row as it is now, after a sync.
    private var live: CalendarSource { store.calendarSource(source.id) ?? source }

    /// The palette, plus the calendar's own color (Google's) when it isn't in it.
    private var palette: [String] {
        guard let own = source.color?.uppercased(), !memberPalette.contains(own) else { return memberPalette }
        return [own] + memberPalette
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Someone else's Google calendar shown as Busy: only they can show its details.
    private var busyLocked: Bool {
        source.isGoogle && source.busyOnly && !store.isMine(store.calendarAccount(source.accountId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Picker("Who it's for", selection: $memberId) {
                        Text("Everyone").tag(UUID?.none)
                        ForEach(store.members) { member in
                            Text(member.displayName).tag(Optional(member.id))
                        }
                    }
                    Toggle("Show as Busy", isOn: $busyOnly)
                        .disabled(busyLocked)
                    Toggle("Show in Ohana", isOn: $enabled)
                } footer: {
                    Text(busyLocked
                         ? "Only the parent who connected this Google account can show its details. Turned off, its events leave the family calendar until you turn it back on."
                         : "Busy shows only when something is on, without titles or places. Turned off, its events leave the family calendar until you turn it back on.")
                }
                Section {
                    ColorPalettePicker(selection: $color, colors: palette)
                    if let member = store.member(memberId), !color.isEmpty {
                        Button("Use \(member.displayName)'s color") { withAnimation(Theme.springy) { color = "" } }
                    }
                } header: {
                    Text("Color")
                } footer: {
                    if color.isEmpty, let member = store.member(memberId) {
                        Text("Events use \(member.displayName)'s color.")
                    }
                }
                Section("Syncing") {
                    LabeledContent("From", value: store.calendarOrigin(of: live))
                    LabeledContent("Events", value: "\(live.eventCount)")
                    LabeledContent("Updated", value: live.lastSyncedAt?.formatted(.relative(presentation: .named)) ?? "Not yet")
                    if let problem = live.lastError {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.danger)
                    }
                    Button {
                        Task {
                            syncing = true
                            await store.syncCalendars(live)
                            syncing = false
                        }
                    } label: {
                        HStack {
                            Text("Sync now")
                            Spacer()
                            if syncing { ProgressView() }
                        }
                    }
                    .disabled(syncing || !live.enabled)
                }
                Section {
                    Button("Remove calendar", role: .destructive) { confirmingRemove = true }
                } footer: {
                    Text(live.isGoogle
                         ? "Removes its events from Ohana. The Google account stays connected, and nothing changes in Google Calendar."
                         : "Removes its events from Ohana. The calendar itself doesn't change.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            saving = true
                            Task {
                                let saved = await store.updateCalendarSource(source, name: trimmedName, color: color.nilIfEmpty,
                                                                             memberId: memberId, busyOnly: busyOnly, enabled: enabled)
                                saving = false
                                if saved { dismiss() }
                            }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .confirmationDialog("Remove “\(source.name)”?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove calendar", role: .destructive) {
                    Task {
                        await store.removeCalendarSource(source)
                        dismiss()
                    }
                }
            } message: {
                Text("Its events leave the family calendar and the wall display.")
            }
            .interactiveDismissDisabled(saving)
            .showsStoreErrors()
        }
    }
}

// MARK: - Sharing the family calendar

/// The family's own events as a link Apple Calendar, Google Calendar or
/// Outlook can subscribe to. Parents only.
struct ShareFamilyCalendarSection: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var copied = false
    @State private var confirmingNewLink = false
    @State private var confirmingStop = false

    var body: some View {
        Section {
            if let url = store.calendarFeedURL {
                Button { openURL(url.webcal) } label: {
                    Label("Add to Apple Calendar", systemImage: "calendar.badge.plus")
                }
                Button { openURL(url.googleCalendarSubscribe) } label: {
                    Label("Add to Google Calendar", systemImage: "g.circle")
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    withAnimation(Theme.springy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy link (for Outlook and others)", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                Button("Make a new link") { confirmingNewLink = true }
                Button("Stop sharing", role: .destructive) { confirmingStop = true }
            } else {
                Button {
                    Task {
                        working = true
                        await store.shareFamilyCalendar()
                        working = false
                    }
                } label: {
                    HStack {
                        Label("Create a calendar link", systemImage: "link.badge.plus")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working)
            }
        } header: {
            Text("Show Ohana in other calendars")
        } footer: {
            Text("See the family's events in Apple Calendar, Google Calendar or Outlook. Anyone with the link can see them, so share it only with family. Those apps check for changes on their own schedule, from minutes to a few hours.")
        }
        .confirmationDialog("Make a new link?", isPresented: $confirmingNewLink, titleVisibility: .visible) {
            Button("Make a new link", role: .destructive) {
                Task {
                    copied = false
                    await store.shareFamilyCalendar(newLink: true)
                }
            }
        } message: {
            Text("The current link stops working. Anyone using it needs the new one.")
        }
        .confirmationDialog("Stop sharing the family calendar?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) {
                Task {
                    copied = false
                    await store.stopSharingFamilyCalendar()
                }
            }
        } message: {
            Text("Calendars subscribed to the link stop getting the family's events.")
        }
    }
}
