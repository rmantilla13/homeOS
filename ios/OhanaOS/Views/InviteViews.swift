import SwiftUI
import UIKit

/// A parent invites someone into the family: a new member with a role, or an
/// existing member (usually a kid) getting their own login.
struct CreateInviteView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Opens with this member picked, from the member editor.
    var preselected: Member?

    @State private var memberId: UUID?
    @State private var role: MemberRole = .parent
    @State private var email = ""
    @State private var days = 14
    @State private var working = false
    @State private var created: CreatedInvite?

    private static let expiryOptions = [1, 3, 7, 14, 30, 60]

    private var forMember: Member? { store.member(memberId) }

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    ScrollView {
                        InviteCodeCard(code: created.code, expiresAt: created.expiresAt, familyName: store.family?.name,
                                       subtitle: forMember.map { "For \($0.displayName)" } ?? "Joins as \(role.withArticle)")
                            .padding(Theme.page)
                    }
                    .transition(.opacity)
                } else {
                    form
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(created == nil ? "Invite someone" : "Invite ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if created == nil { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if created == nil {
                        Button("Create") { Task { await create() } }
                            .disabled(working)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .animation(Theme.springy, value: created)
            .showsStoreErrors()
        }
        .onAppear {
            if let preselected, memberId == nil { memberId = preselected.id }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("For", selection: $memberId) {
                    Text("Someone new").tag(UUID?.none)
                    ForEach(store.membersWithoutAccounts) { member in
                        Text(member.displayName).tag(UUID?.some(member.id))
                    }
                }
            } header: {
                Text("Who's it for")
            } footer: {
                if let forMember {
                    Text("\(forMember.displayName) gets their own login and keeps their chores and points.")
                } else {
                    Text("They'll be added to the family when they accept.")
                }
            }
            if forMember == nil {
                Section {
                    Picker("Joins as", selection: $role) {
                        ForEach(MemberRole.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Parents manage the family: members, invites, rewards and approvals.")
                }
            }
            Section {
                TextField("Email (optional)", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("With an email, only that address can use the code.")
            }
            Section {
                Picker("Works for", selection: $days) {
                    ForEach(Self.expiryOptions, id: \.self) { n in
                        Text(n == 1 ? "1 day" : "\(n) days").tag(n)
                    }
                }
            }
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        if let invite = await store.createInvite(role: role, for: forMember, email: email, expiresInDays: days) {
            created = invite
        }
    }
}

/// The code, big, with Share and Copy.
struct InviteCodeCard: View {
    let code: String
    let expiresAt: Date
    let familyName: String?
    var subtitle: String?
    @State private var copied = false

    private var shareText: String {
        InviteCode.shareText(code: code, familyName: familyName, expiresAt: expiresAt)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.muted)
                }
                Text(InviteCode.format(code))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                Text("Works until \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                GlowView().frame(height: 180).offset(y: -70).opacity(0.8)
            }
            HStack(spacing: 10) {
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.pill())
                Button {
                    UIPasteboard.general.string = InviteCode.format(code)
                    withAnimation(Theme.springy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pill(.soft))
            }
            Text("They open the link on their iPhone, or enter the code when they sign up in Ohana Display.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 18)
        .card()
        .sensoryFeedback(.success, trigger: copied)
    }
}

/// A pending invite in the Family tab: code, who it's for, share and revoke.
struct PendingInviteRow: View {
    @Environment(FamilyStore.self) private var store
    let invite: FamilyInvite
    @State private var confirmingRevoke = false

    private var detail: String {
        var parts: [String] = []
        if let member = store.member(invite.memberId) {
            parts.append("For \(member.displayName)")
        } else {
            parts.append(invite.role.title)
        }
        if let email = invite.email, !email.isEmpty { parts.append(email) }
        parts.append("until \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.displayCode)
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            ShareLink(item: InviteCode.shareText(code: invite.code, familyName: store.family?.name, expiresAt: invite.expiresAt)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Share invite")
            Menu {
                Button("Copy code", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = invite.displayCode
                }
                Button("Revoke", systemImage: "xmark.circle", role: .destructive) { confirmingRevoke = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("More")
        }
        .confirmationDialog("Revoke this invite?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Revoke \(invite.displayCode)", role: .destructive) {
                Task { await store.revokeInvite(invite) }
            }
        } message: {
            Text("The code stops working right away.")
        }
    }
}

/// Someone who joined with an invite.
struct AcceptedInviteRow: View {
    @Environment(FamilyStore.self) private var store
    let invite: FamilyInvite

    private var member: Member? {
        guard let user = invite.acceptedBy else { return nil }
        return store.members.first { $0.userId == user }
    }

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatar(member: member, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(member?.displayName ?? store.profile(for: invite.acceptedBy)?.displayName ?? "Someone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if let joined = invite.acceptedAt {
                    Text("Joined \(joined.formatted(.relative(presentation: .named))) · \(invite.displayCode)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        }
    }
}
