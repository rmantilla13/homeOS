import SwiftUI

/// Members, invites, lists, meals, family memory and wall displays.
struct FamilyView: View {
    @Environment(FamilyStore.self) private var store
    @State private var showingAddMember = false
    @State private var showingPair = false
    @State private var showingNewList = false
    @State private var newListName = ""
    @State private var editingMeals: MealDay?
    @State private var newMemory = ""
    @State private var showingProfile = false
    @State private var editingMember: Member?
    @State private var showingInvite = false
    @State private var confirmingLeave = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ScreenHeader(title: store.family?.name ?? "Family", subtitle: "Family") {
                        Button { showingProfile = true } label: {
                            MemberAvatar(member: store.me, size: 44)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Your profile")
                    }
                    membersSection
                    if store.isParent { invitesSection }
                    listsSection
                    mealsSection
                    memorySection
                    if store.isParent { displaysSection }
                    HStack(spacing: 10) {
                        Button("Profile") { showingProfile = true }
                            .buttonStyle(.pill(.neutral))
                        Button("Leave family", role: .destructive) { confirmingLeave = true }
                            .buttonStyle(.pill(.neutral))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 24)
                .animation(Theme.springy, value: store.memories)
                .animation(Theme.springy, value: store.lists)
                .animation(Theme.springy, value: store.members)
                .animation(Theme.springy, value: store.invites)
            }
            .screenBackground()
            .refreshable { await store.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FamilyList.self) { ListDetailView(listId: $0.id) }
            .sheet(isPresented: $showingAddMember) { AddMemberView() }
            .sheet(isPresented: $showingPair) { PairDisplayView() }
            .sheet(item: $editingMeals) { MealEditor(day: $0.id) }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(item: $editingMember) { MemberEditor(member: $0) }
            .sheet(isPresented: $showingInvite) { CreateInviteView() }
            .alert("New list", isPresented: $showingNewList) {
                TextField("Name", text: $newListName)
                Button("Cancel", role: .cancel) { newListName = "" }
                Button("Add") {
                    let name = newListName.trimmingCharacters(in: .whitespaces)
                    newListName = ""
                    if !name.isEmpty { Task { await store.addList(name: name) } }
                }
            }
            .confirmationDialog("Leave \(store.family?.name ?? "this family")?", isPresented: $confirmingLeave,
                                titleVisibility: .visible) {
                Button("Leave family", role: .destructive) { Task { await store.leaveFamily() } }
            } message: {
                Text("Your account is unlinked from the family. \(store.me?.displayName ?? "You") stays on the family screen with their points. You'll need a new invite to come back.")
            }
            .showsStoreErrors()
        }
    }

    // MARK: Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Members")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(store.members) { member in
                        Button { editingMember = member } label: {
                            VStack(spacing: 6) {
                                MemberAvatar(member: member, size: 56)
                                Text(member.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(member.id == store.me?.id ? "You" : member.role.title)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(!store.canEdit(member))
                        .transition(.scale.combined(with: .opacity))
                    }
                    if store.isParent {
                        Button { showingAddMember = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 56, height: 56)
                                    .background(Theme.sunken, in: Circle())
                                Text("Add").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(4)
            }
            .card(padding: 14)
        }
    }

    // MARK: Invites

    private var invitesSection: some View {
        let pending = store.invites.filter { $0.status == .pending }
        let accepted = store.invites.filter { $0.status == .accepted }.prefix(5)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Invites") {
                Button("Invite") { showingInvite = true }
                    .font(.subheadline.weight(.semibold))
            }
            if pending.isEmpty && accepted.isEmpty {
                HStack {
                    Text("Invite the other grown-ups, or give a kid their own login.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Invite") { showingInvite = true }
                        .buttonStyle(.pill(.soft))
                }
                .card(padding: 16)
            }
            if !pending.isEmpty {
                VStack(spacing: 12) {
                    ForEach(pending) { invite in
                        PendingInviteRow(invite: invite)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .card(padding: 14)
            }
            if !accepted.isEmpty {
                VStack(spacing: 12) {
                    ForEach(accepted) { AcceptedInviteRow(invite: $0) }
                }
                .card(padding: 14)
            }
        }
    }

    // MARK: Lists

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Lists") {
                Button("New list") { showingNewList = true }
                    .font(.subheadline.weight(.semibold))
            }
            if store.lists.isEmpty {
                HStack {
                    Text("Keep a shared grocery list the whole family can add to.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Start") { Task { await store.addList(name: "Groceries") } }
                        .buttonStyle(.pill(.soft))
                }
                .card(padding: 16)
            }
            ForEach(store.lists) { list in
                let open = store.items(in: list).filter { !$0.done }
                NavigationLink(value: list) {
                    HStack(spacing: 14) {
                        Image(systemName: list.kind == "shopping" ? "cart.fill" : "checklist")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .background(Theme.accentSoft, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(list.name).font(.headline).foregroundStyle(Theme.text)
                            Text(open.isEmpty ? "All done" : open.prefix(3).map(\.text).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(open.count)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .contentTransition(.numericText(value: Double(open.count)))
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                    .card(padding: 14, radius: Theme.radiusSm + 4)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: Meals

    private var mealsSection: some View {
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: .now)) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Meals this week")
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let key = DayKey.string(day)
                    let dinner = store.meal(.dinner, on: key)
                    let others = [MealSlot.breakfast, .lunch].compactMap { store.meal($0, on: key)?.title }
                    Button { editingMeals = MealDay(id: key) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(index == 0 ? Theme.accent : Theme.muted)
                                Text("\(Calendar.current.component(.day, from: day))")
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                            }
                            .frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dinner?.title ?? "Plan dinner")
                                    .font(.subheadline.weight(dinner == nil ? .regular : .semibold))
                                    .foregroundStyle(dinner == nil ? Theme.muted : Theme.text)
                                if !others.isEmpty {
                                    Text(others.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "pencil").font(.footnote).foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < days.count - 1 { Divider().overlay(Theme.divider) }
                }
            }
            .card(padding: 14)
        }
    }

    // MARK: Family memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Family memory")
            Text("Things Ohana remembers about your family, like routines or who carpools with whom.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Add something to remember", text: $newMemory, axis: .vertical)
                        .lineLimit(1...3)
                        .foregroundStyle(Theme.text)
                    Button {
                        let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
                        newMemory = ""
                        Task { await store.addMemory(text) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.pill(.soft))
                    .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !store.memories.isEmpty { Divider().overlay(Theme.divider) }
                ForEach(store.memories) { memory in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: memory.source == "assistant" ? "sparkles" : "pencil")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                            .padding(.top, 2)
                        Text(memory.content)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if store.isParent {
                            Button { Task { await store.deleteMemory(memory) } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Forget this")
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .card(padding: 16)
        }
    }

    // MARK: Displays

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Wall displays")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "tv")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accentSoft, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            if let seen = device.lastSeenAt {
                                Text("Seen \(seen.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                Button { showingPair = true } label: {
                    Label("Pair a display", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.pill(.soft))
            }
            .card(padding: 16)
        }
    }
}

struct MealDay: Identifiable {
    let id: String  // yyyy-MM-dd
}

// MARK: - List detail

struct ListDetailView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let listId: UUID
    @State private var newItem = ""
    @State private var confirmingDelete = false
    @FocusState private var adding: Bool

    private var list: FamilyList? { store.lists.first { $0.id == listId } }

    var body: some View {
        let items = list.map { store.items(in: $0) } ?? []
        let open = items.filter { !$0.done }
        let done = items.filter(\.done)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    TextField("Add an item", text: $newItem)
                        .focused($adding)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .foregroundStyle(Theme.text)
                    CircleIconButton(systemName: "plus", size: 38) { add() }
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Theme.surface, in: Capsule())

                if open.isEmpty {
                    EmptyCard(text: "Nothing on the list", systemImage: "checkmark.circle")
                } else {
                    VStack(spacing: 0) {
                        ForEach(open) { ListItemRow(item: $0).transition(.move(edge: .top).combined(with: .opacity)) }
                    }
                    .card(padding: 8)
                }

                if !done.isEmpty {
                    HStack {
                        Text("Done").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Clear") { if let list { Task { await store.clearDone(in: list) } } }
                            .font(.subheadline.weight(.semibold))
                    }
                    VStack(spacing: 0) {
                        ForEach(done) { ListItemRow(item: $0).transition(.opacity) }
                    }
                    .card(padding: 8)
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.vertical, 12)
            .animation(Theme.springy, value: store.listItems)
        }
        .screenBackground()
        .refreshable { await store.refresh() }
        .navigationTitle(list?.name ?? "List")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Delete list", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this list and its items?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let list {
                    Task { await store.deleteList(list) }
                    dismiss()
                }
            }
        }
    }

    private func add() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard let list, !text.isEmpty else { return }
        newItem = ""
        adding = true
        Task { await store.addItem(text, to: list) }
    }
}

struct ListItemRow: View {
    @Environment(FamilyStore.self) private var store
    let item: ListItem

    var body: some View {
        Button { Task { await store.toggle(item) } } label: {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Theme.success : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.text)
                    .strikethrough(item.done, color: Theme.muted)
                    .foregroundStyle(item.done ? Theme.muted : Theme.text)
                Spacer()
                if let quantity = item.quantity, !quantity.isEmpty {
                    Text(quantity).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: item.done)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.deleteItem(item) } }
        }
    }
}

// MARK: - Meals editor

struct MealEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let day: String
    @State private var titles: [MealSlot: String] = [:]
    @State private var loaded = false
    @State private var saving = false

    private let slots: [MealSlot] = [.breakfast, .lunch, .dinner]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(slots, id: \.self) { slot in
                    Section(slot.rawValue.capitalized) {
                        TextField("What's for \(slot.rawValue)?", text: binding(for: slot))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(dayLabel(for: DayKey.date(day) ?? .now))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                for slot in slots { titles[slot] = store.meal(slot, on: day)?.title ?? "" }
                loaded = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for slot: MealSlot) -> Binding<String> {
        Binding(get: { titles[slot] ?? "" }, set: { titles[slot] = $0 })
    }

    private func save() {
        saving = true
        Task {
            for slot in slots {
                let title = titles[slot] ?? ""
                if title != (store.meal(slot, on: day)?.title ?? "") {
                    await store.setMeal(slot, on: day, title: title)
                }
            }
            dismiss()
        }
    }
}

// MARK: - Members & pairing

struct AddMemberView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role: MemberRole = .child
    @State private var color = memberPalette[0]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AvatarCircle(name: name, color: color, size: 72)
                            .animation(Theme.springy, value: color)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $name)
                    Picker("Role", selection: $role) {
                        ForEach(MemberRole.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Kids don't need a login. To give someone their own, invite them from the Family tab.")
                }
                Section("Color") {
                    ColorPalettePicker(selection: $color)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Add member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await store.addMember(name: name, role: role, color: color); dismiss() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// The member palette with a ring that slides to the picked color.
struct ColorPalettePicker: View {
    @Binding var selection: String
    var colors = memberPalette
    @Namespace private var namespace

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(colors, id: \.self) { hex in
                ZStack {
                    if hex == selection {
                        Circle()
                            .stroke(Color(hex: hex), lineWidth: 3)
                            .frame(width: 40, height: 40)
                            .matchedGeometryEffect(id: "ring", in: namespace)
                    }
                    Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .onTapGesture { withAnimation(Theme.springy) { selection = hex } }
                .accessibilityLabel("Color \(hex)")
                .accessibilityAddTraits(hex == selection ? .isSelected : [])
            }
        }
    }
}

/// Edit a member. Parents can change anyone's name, color and role, invite a
/// member without a login, or remove them; everyone else edits only themselves.
struct MemberEditor: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let member: Member

    @State private var name: String
    @State private var color: String
    @State private var role: MemberRole
    @State private var working = false
    @State private var confirmingRemove = false
    @State private var inviting = false

    init(member: Member) {
        self.member = member
        _name = State(initialValue: member.displayName)
        _color = State(initialValue: member.color)
        _role = State(initialValue: member.role)
    }

    private var isMe: Bool { member.id == store.me?.id }
    private var firstName: String { member.displayName.split(separator: " ").first.map(String.init) ?? member.displayName }
    /// The palette, plus the member's current color if it's a custom one.
    private var palette: [String] { memberPalette.contains(member.color) ? memberPalette : memberPalette + [member.color] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        AvatarCircle(name: name, color: color, photo: store.avatarPath(for: member), size: 72)
                            .animation(Theme.springy, value: color)
                        if isMe {
                            Text("This is you").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $name)
                    if store.isParent {
                        Picker("Role", selection: $role) {
                            ForEach(MemberRole.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else {
                        LabeledContent("Role", value: member.role.title)
                    }
                }
                Section("Color") {
                    ColorPalettePicker(selection: $color, colors: palette)
                }
                Section("Account") {
                    if member.userId != nil {
                        Label(isMe ? "Signed in on this iPhone" : "Has an Ohana Display login", systemImage: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(Theme.text)
                    } else {
                        Label("No login. \(firstName) shows up on the family screen only.", systemImage: "person.crop.circle")
                            .foregroundStyle(Theme.muted)
                        if store.isParent {
                            Button("Invite \(firstName) to get a login") { inviting = true }
                        }
                    }
                }
                if store.isParent && !isMe {
                    Section {
                        Button("Remove from family", role: .destructive) { confirmingRemove = true }
                    } footer: {
                        Text("Their chores, completions and points are deleted too.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(isMe ? "You" : member.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
            .sheet(isPresented: $inviting) { CreateInviteView(preselected: member) }
            .showsStoreErrors()
            .confirmationDialog("Remove \(member.displayName)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await remove() } }
            } message: {
                Text("This deletes \(firstName) from the family, with their chores and points.")
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        let changed = name != member.displayName || color != member.color || role != member.role
        if changed {
            guard await store.updateMember(member, name: name, color: color, role: role) else { return }
        }
        dismiss()
    }

    private func remove() async {
        working = true
        defer { working = false }
        if await store.removeMember(member) { dismiss() }
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
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                        }
                } footer: {
                    Text("Turn on the display and enter the code it shows.")
                }
                TextField("Display name", text: $name)
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Pair a display")
            .navigationBarTitleDisplayMode(.inline)
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
            .showsStoreErrors()  // a failed pairing keeps this sheet open
        }
    }
}
