import SwiftUI

struct SettingsView: View {
    @Environment(FamilyStore.self) private var store
    @State private var showingAddMember = false
    @State private var showingPair = false

    var body: some View {
        NavigationStack {
            List {
                Section("Family members") {
                    ForEach(store.members) { member in
                        HStack {
                            MemberAvatar(member: member)
                            Text(member.displayName)
                            Spacer()
                            Text(member.role.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                    }
                    if store.isParent {
                        Button("Add family member") { showingAddMember = true }
                    }
                }
                if store.isParent {
                    Section("Wall display") {
                        Button("Pair a display") { showingPair = true }
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                }
            }
            .navigationTitle(store.family?.name ?? "Family")
            .sheet(isPresented: $showingAddMember) { AddMemberView() }
            .sheet(isPresented: $showingPair) { PairDisplayView() }
            .showsStoreErrors()
        }
    }
}

struct AddMemberView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role: MemberRole = .child
    @State private var color = memberPalette[2]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Role", selection: $role) {
                    ForEach(MemberRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Section("Color") {
                    HStack {
                        ForEach(memberPalette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                .overlay { if hex == color { Image(systemName: "checkmark").foregroundStyle(.white) } }
                                .onTapGesture { color = hex }
                        }
                    }
                }
            }
            .navigationTitle("Add member")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await store.addMember(name: name, role: role, color: color); dismiss() } }
                        .disabled(name.isEmpty)
                }
            }
        }
    }
}

/// Enter the 6-digit code shown on a new display.
// TODO(M1): scan the code with DataScannerViewController once the display shows a QR code.
struct PairDisplayView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = "Kitchen display"
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("123456", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                } footer: {
                    Text("Turn on the display and enter the code it shows.")
                }
                TextField("Display name", text: $name)
            }
            .navigationTitle("Pair a display")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        working = true
                        Task {
                            if await store.pairDisplay(code: code, name: name) { dismiss() }
                            working = false
                        }
                    }
                    .disabled(code.count != 6 || working)
                }
            }
        }
    }
}
