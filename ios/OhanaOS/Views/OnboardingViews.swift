import SwiftUI

/// Glow and title shared by the sign-in and setup screens.
private struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.bottom, 12)
        .background(alignment: .top) {
            GlowView()
                .frame(height: 260)
                .offset(y: -90)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

// MARK: - Invite code pieces

/// Monospaced code field that tidies input into `XXXX-XXXX` as you type.
struct InviteCodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("XXXX-XXXX", text: $code)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(Theme.text)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .onChange(of: code) { _, new in
                let tidy = Self.tidy(new)
                if tidy != new { code = tidy }
            }
            .accessibilityLabel("Invite code")
    }

    /// Up to 8 code characters, with the dash once there are more than 4.
    static func tidy(_ raw: String) -> String {
        let chars = String(InviteCode.normalize(raw).prefix(8))
        guard chars.count > 4 else { return chars }
        return "\(chars.prefix(4))-\(chars.dropFirst(4))"
    }
}

/// "You're invited to The Smiths as a parent", or why a code can't be used.
struct InvitePreviewRow: View {
    let preview: InvitePreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(preview.valid ? Theme.success : Theme.danger)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if preview.valid, let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        guard preview.valid else { return "exclamationmark.triangle.fill" }
        return preview.kind == .family ? "person.2.fill" : "house.fill"
    }

    private var detail: String? {
        var parts: [String] = []
        if let by = preview.invitedBy, !by.isEmpty { parts.append("From \(by)") }
        if let expires = preview.expiresAt {
            parts.append("Works until \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The store's preview, if it belongs to the code in the field.
@MainActor
private func preview(for code: String, in store: FamilyStore) -> InvitePreview? {
    guard let pending = store.pendingInviteCode, pending == InviteCode.format(code) else { return nil }
    return store.pendingPreview
}

// MARK: - Welcome (signed out)

/// Invite code first, then create an account or sign in.
struct WelcomeView: View {
    @Environment(FamilyStore.self) private var store

    enum Mode: String, CaseIterable {
        case create = "Create account"
        case signIn = "Sign in"
    }

    @State private var mode: Mode = .create
    @State private var code = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var checking = false
    @State private var working = false
    @State private var sentEmail: SentEmail?

    /// What the "Check your email" alert is about.
    private enum SentEmail {
        case confirmation(String)
        case passwordReset(String)
    }

    private var invite: InvitePreview? { preview(for: code, in: store) }
    private var inviteReady: Bool { invite?.valid == true }

    private var canSubmit: Bool {
        let hasEmail = email.contains("@")
        switch mode {
        case .create:
            return inviteReady && hasEmail && password.count >= 8
                && !name.trimmingCharacters(in: .whitespaces).isEmpty && !working
        case .signIn:
            return hasEmail && !password.isEmpty && !working
        }
    }

    private var accountFooter: String {
        switch mode {
        case .create:
            return inviteReady ? "At least 8 characters." : "Check your invite code first."
        case .signIn:
            guard inviteReady, let invite, invite.kind == .family else { return "Already have an account? No code needed." }
            return "You'll join \(invite.familyName ?? "the family") after signing in."
        }
    }

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "Ohana Display", subtitle: "Your family's calendar, chores and photos — on the wall and in your pocket.")
            }
            Section {
                InviteCodeField(code: $code)
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check invite")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(InviteCode.normalize(code).count != 8 || checking)
                if let invite {
                    InvitePreviewRow(preview: invite).transition(.opacity)
                }
            } header: {
                Text("Invite code")
            } footer: {
                Text("Ohana Display is invite-only. Your code came with your invite, or from someone in your family.")
            }

            Section {
                SegmentedPill(Mode.allCases, selection: $mode) { $0.rawValue }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                if mode == .create {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .create ? .newPassword : .password)
                if mode == .signIn {
                    Button("Forgot password?") { Task { await forgotPassword() } }
                        .font(.subheadline)
                        .disabled(working)
                }
            } footer: {
                Text(accountFooter)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView().tint(.white) } else { Text(mode.rawValue) }
                        Spacer()
                    }
                }
                .buttonStyle(.pill())
                .disabled(!canSubmit)
                .listRowBackground(Color.clear)
            } footer: {
                Link("Privacy policy", destination: Config.privacyPolicyURL)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .animation(Theme.springy, value: mode)
        .animation(Theme.springy, value: invite)
        .showsStoreErrors()
        .task(id: store.pendingInviteCode) {
            // An ohanaos://invite link prefills and checks the code.
            guard let pending = store.pendingInviteCode else { return }
            if code != pending { code = pending }
            if store.pendingPreview == nil && !checking { await check() }
        }
        .alert("Check your email", isPresented: Binding(
            get: { sentEmail != nil },
            set: { if !$0 { sentEmail = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sentEmailMessage)
        }
    }

    private var sentEmailMessage: String {
        switch sentEmail {
        case .confirmation(let address)?:
            return "We sent a link to \(address). Open it on this iPhone, then sign in here. Your invite code is saved."
        case .passwordReset(let address)?:
            // Auth doesn't say whether the address has an account.
            return "If \(address) has an account, we sent it a link. Open it on this iPhone to choose a new password."
        case nil:
            return ""
        }
    }

    private func check() async {
        checking = true
        await store.checkInvite(code)
        checking = false
    }

    private func submit() async {
        working = true
        defer { working = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create:
            if await store.signUp(email: address, password: password, name: name) == .confirmEmail {
                sentEmail = .confirmation(address)
                password = ""
                mode = .signIn
            }
        case .signIn:
            // Only a code that checked out rides along into the account.
            if !inviteReady { store.setPendingInvite(nil) }
            await store.signIn(email: address, password: password)
        }
    }

    private func forgotPassword() async {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else {
            store.errorMessage = "Enter your email first."
            return
        }
        working = true
        defer { working = false }
        if await store.sendPasswordReset(email: address) {
            password = ""
            sentEmail = .passwordReset(address)
        }
    }
}

// MARK: - Choose a password (signed in from an email link)

/// After an admin's email invite, whose login has no password yet, or a
/// "Forgot password?" link. Comes before family setup and the tabs.
struct SetPasswordView: View {
    @Environment(FamilyStore.self) private var store
    @State private var password = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "Choose a password",
                                 subtitle: "You'll sign in to Ohana Display with your email and this password.")
            }
            Section {
                SecureField("New password", text: $password)
                    .textContentType(.newPassword)
            } footer: {
                Text("At least 8 characters.")
            }
            Section {
                Button {
                    Task {
                        working = true
                        _ = await store.setPassword(password)
                        working = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView().tint(.white) } else { Text("Save password") }
                        Spacer()
                    }
                }
                .buttonStyle(.pill())
                .disabled(password.count < 8 || working)
                .listRowBackground(Color.clear)
            }
            Section {
                Button("Sign out") { Task { await store.signOut() } }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                if let email = store.email {
                    Text("Signed in as \(email)").frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .showsStoreErrors()
    }
}

// MARK: - Family setup (signed in, no family)

/// Signed in without a family: start one with a platform invite, or enter a code.
struct FamilySetupView: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        Group {
            if let code = store.pendingInviteCode, let preview = store.pendingPreview,
               preview.valid, preview.kind == .platform {
                CreateFamilyView(inviteCode: code)
                    .transition(.opacity)
            } else {
                EnterInviteView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.pendingPreview)
    }
}

/// "Enter an invite code": for accounts that aren't in a family yet.
struct EnterInviteView: View {
    @Environment(FamilyStore.self) private var store
    @State private var code = ""
    @State private var checking = false
    @State private var joining = false
    @State private var confirmingDelete = false
    @State private var deleting = false

    private var invite: InvitePreview? { preview(for: code, in: store) }

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "Enter an invite code",
                                 subtitle: "Ohana Display is invite-only. Ask someone in your family for a code, or use the one from your invite email.")
            }
            Section {
                InviteCodeField(code: $code)
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check invite")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(InviteCode.normalize(code).count != 8 || checking)
                if let invite {
                    InvitePreviewRow(preview: invite).transition(.opacity)
                }
            }
            if let invite, invite.valid, invite.kind == .family {
                Section {
                    Button {
                        Task {
                            joining = true
                            await store.acceptInvite(code)
                            joining = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if joining { ProgressView().tint(.white) } else { Text("Join \(invite.familyName ?? "the family")") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.pill())
                    .disabled(joining)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("You'll appear as \(store.myProfile?.displayName.nilIfEmpty ?? "yourself"). You can change your name later.")
                }
            }
            Section {
                Button("Sign out") { Task { await store.signOut() } }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                Button("Delete account", role: .destructive) { confirmingDelete = true }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .disabled(deleting)
            } footer: {
                if let email = store.email {
                    Text("Signed in as \(email)").frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .animation(Theme.springy, value: invite)
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Delete account", role: .destructive) {
                Task {
                    deleting = true
                    _ = await store.deleteAccount()
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your login and profile are deleted. This can't be undone.")
        }
        .showsStoreErrors()
        .task(id: store.pendingInviteCode) {
            guard let pending = store.pendingInviteCode else { return }
            if code != pending { code = pending }
            if store.pendingPreview == nil && !checking { await check() }
        }
    }

    private func check() async {
        checking = true
        await store.checkInvite(code)
        checking = false
    }
}

/// Start a family with a platform invite. You become its first parent.
struct CreateFamilyView: View {
    @Environment(FamilyStore.self) private var store
    let inviteCode: String
    /// False inside the invite-link sheet, where you're already in a family.
    var showsAccountActions = true

    @State private var familyName = ""
    @State private var myName = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                OnboardingHeader(title: "Welcome", subtitle: "Set up your family. You'll be the first parent.")
            }
            Section {
                Label {
                    Text("Invite \(InviteCode.format(inviteCode)) lets you start a new family")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                }
            }
            Section("Your family") {
                TextField("Family name (e.g. The Smiths)", text: $familyName)
                TextField("Your name", text: $myName)
                    .textContentType(.name)
            }
            Section {
                Button {
                    Task {
                        working = true
                        await store.createFamily(name: familyName.trimmingCharacters(in: .whitespaces),
                                                 myName: myName.trimmingCharacters(in: .whitespaces),
                                                 inviteCode: inviteCode)
                        working = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView().tint(.white) } else { Text("Create family") }
                        Spacer()
                    }
                }
                .buttonStyle(.pill())
                .disabled(familyName.trimmingCharacters(in: .whitespaces).isEmpty
                          || myName.trimmingCharacters(in: .whitespaces).isEmpty || working)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Add kids, invite the other grown-ups and pair your wall display next, from the Family tab.")
            }
            if showsAccountActions {
                Section {
                    Button("Use a different code") { store.setPendingInvite(nil) }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    Button("Sign out") { Task { await store.signOut() } }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .showsStoreErrors()
        .onAppear {
            if myName.isEmpty { myName = store.myProfile?.displayName ?? "" }
        }
    }
}

// MARK: - Invite link while signed in

/// Identifies the invite-link sheet by its code.
struct InviteLink: Identifiable {
    let code: String
    var id: String { code }
}

/// Opened by an ohanaos://invite link when you're already in a family.
struct InviteLinkSheet: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let code: String
    @State private var invite: InvitePreview?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(InviteCode.format(code))
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Text("Invite code").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    GlowView().frame(height: 200).offset(y: -80)
                }

                if let invite {
                    InvitePreviewRow(preview: invite).card(padding: 16)
                    actions(for: invite)
                } else {
                    ProgressView().padding()
                }
                Spacer()
            }
            .padding(.horizontal, Theme.page)
            .screenBackground()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        store.setPendingInvite(nil)
                        dismiss()
                    }
                }
            }
            .task { invite = await store.previewInvite(code) }
            .showsStoreErrors()
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func actions(for invite: InvitePreview) -> some View {
        if invite.valid && invite.kind == .family {
            Button {
                Task {
                    working = true
                    // On success the store clears the pending code, which closes this sheet.
                    await store.acceptInvite(code)
                    working = false
                }
            } label: {
                HStack {
                    Spacer()
                    if working { ProgressView().tint(.white) } else { Text("Join \(invite.familyName ?? "the family")") }
                    Spacer()
                }
            }
            .buttonStyle(.pill())
            .disabled(working)
            Text("Ohana Display will switch to that family. Switch back any time from your profile.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
        } else if invite.valid {
            NavigationLink {
                CreateFamilyView(inviteCode: code, showsAccountActions: false)
            } label: {
                Text("Start a new family").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill())
        }
    }
}
