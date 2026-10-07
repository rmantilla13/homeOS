import AppIntents
import PhotosUI
import SwiftUI

/// Your account: name, photo, email, which family to show, Siri, privacy
/// and support links, sign out, and deleting the account.
struct ProfileView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var renameMember = true
    @State private var saving = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleting = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var shownName: String {
        store.myProfile?.displayName.nilIfEmpty ?? store.me?.displayName ?? "You"
    }

    private var nameChanged: Bool {
        guard !trimmedName.isEmpty else { return false }
        if trimmedName != store.myProfile?.displayName { return true }
        if renameMember, let me = store.me, me.displayName != trimmedName { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                    if store.me != nil {
                        Toggle("Use it on the family screen too", isOn: $renameMember)
                    }
                    Button {
                        Task {
                            saving = true
                            _ = await store.updateDisplayName(trimmedName, renameMember: renameMember && store.me != nil)
                            saving = false
                        }
                    } label: {
                        HStack {
                            Text("Save name")
                            Spacer()
                            if saving { ProgressView() }
                        }
                    }
                    .disabled(!nameChanged || saving)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Your name in Ohana Display. Parents can also rename you on the family screen.")
                }
                Section("Photo") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(store.myProfile?.avatarPath == nil ? "Add a photo" : "Choose a new photo",
                              systemImage: "photo.on.rectangle")
                    }
                    .disabled(uploading)
                    if store.myProfile?.avatarPath != nil {
                        Button("Remove photo", systemImage: "trash", role: .destructive) {
                            Task { await store.removeAvatar() }
                        }
                        .disabled(uploading)
                    }
                }
                Section("Account") {
                    LabeledContent("Email", value: store.email ?? "—")
                    if let family = store.family {
                        LabeledContent("Family", value: family.name)
                    }
                    if let me = store.me {
                        LabeledContent("Role", value: me.role.title)
                    }
                }
                if store.families.count > 1 {
                    Section {
                        Picker("Show", selection: familySelection) {
                            ForEach(store.families) { family in
                                Text(family.name).tag(family.id)
                            }
                        }
                    } header: {
                        Text("Your families")
                    } footer: {
                        Text("You belong to more than one family. Pick the one this iPhone shows.")
                    }
                }
                Section {
                    SiriTipView(intent: AskOhanaOSIntent())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Siri")
                } footer: {
                    Text("Ask a quick question hands-free, like “Ask Ohana what's for dinner”. Siri asks what you'd like to know.")
                }
                Section("About") {
                    Link(destination: Config.privacyPolicyURL) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Link(destination: Config.supportURL) {
                        Label("Help and support", systemImage: "questionmark.circle")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                        .frame(maxWidth: .infinity)
                }
                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete account")
                            if deleting { ProgressView().padding(.leading, 6) }
                            Spacer()
                        }
                    }
                    .disabled(deleting)
                } footer: {
                    Text("Deletes your login, profile and chats with Ohana for good.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(deleting) }
            }
            .onAppear {
                guard name.isEmpty else { return }
                name = shownName == "You" ? "" : shownName
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
            .confirmationDialog("Sign out of Ohana Display?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    Task { await store.signOut() }
                }
            }
            .alert("Delete your account?", isPresented: $confirmingDelete) {
                Button("Delete account", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteWarning)
            }
            .interactiveDismissDisabled(deleting)
            .showsStoreErrors()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarCircle(name: shownName, color: store.me?.color ?? "#8E9CE6", photo: store.photo(of: store.myProfile), size: 96)
                .overlay {
                    if uploading {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: Circle())
                            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                    }
                    .buttonStyle(.borderless)  // only the badge is tappable, not the whole row
                    .disabled(uploading)
                    .accessibilityLabel("Change photo")
                }
            Text(shownName)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.text)
            if let email = store.email {
                Text(email).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    /// What goes and what stays, for the family on screen.
    private var deleteWarning: String {
        var text = "Your login, profile, photo and chats with Ohana are deleted. This can't be undone."
        if let family = store.family {
            let othersHaveLogins = store.members.contains { $0.userId != nil && $0.id != store.me?.id }
            text += othersHaveLogins
                ? " \(family.name) keeps your name on its screen, your points and what you've added."
                : " You're the only one with a login in \(family.name), so it's deleted too, with its calendar, chores, photos and displays."
        }
        if store.families.count > 1 {
            text += " Any other family where you're the only login is deleted too."
        }
        return text
    }

    private func deleteAccount() async {
        deleting = true
        let deleted = await store.deleteAccount()
        deleting = false
        if deleted { dismiss() }
    }

    private var familySelection: Binding<UUID> {
        Binding(
            get: { store.family?.id ?? store.families.first?.id ?? UUID() },
            set: { id in
                guard let family = store.families.first(where: { $0.id == id }) else { return }
                Task { await store.switchFamily(to: family) }
            })
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer {
            uploading = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = MediaTools.prepareAvatar(data) else {
            store.errorMessage = "That photo couldn't be used. Try another one."
            return
        }
        _ = await store.uploadAvatar(jpeg)
    }
}
