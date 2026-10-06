import AppIntents
import PhotosUI
import SwiftUI

/// Your account: name, photo, email, which family to show, Siri, sign out.
struct ProfileView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var renameMember = true
    @State private var saving = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var confirmingSignOut = false

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
                    Text("Your name in Ohana. Parents can also rename you on the family screen.")
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
                Section {
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                guard name.isEmpty else { return }
                name = shownName == "You" ? "" : shownName
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
            .confirmationDialog("Sign out of Ohana?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    Task { await store.signOut() }
                }
            }
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
