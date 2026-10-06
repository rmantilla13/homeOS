import SwiftUI

struct RewardsView: View {
    @Environment(FamilyStore.self) private var store
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Balances") {
                    ForEach(store.kids) { kid in
                        HStack {
                            MemberAvatar(member: kid)
                            Text(kid.displayName)
                            Spacer()
                            Text("\(store.points[kid.id] ?? 0) ★").bold().foregroundStyle(.orange)
                        }
                        .swipeActions {
                            if store.isParent {
                                Button("+10") { Task { await store.adjustPoints(member: kid, delta: 10, reason: "Bonus") } }.tint(.green)
                                Button("−10") { Task { await store.adjustPoints(member: kid, delta: -10, reason: "Adjustment") } }.tint(.red)
                            }
                        }
                    }
                }
                Section("Rewards") {
                    ForEach(store.rewards) { reward in
                        HStack {
                            Text(reward.icon ?? "🎁")
                            Text(reward.title)
                            Spacer()
                            Text("\(reward.cost) ★").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Rewards")
            .toolbar {
                if store.isParent { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showingAdd) { AddRewardView() }
            .refreshable { await store.refresh() }
            .showsStoreErrors()
        }
    }
}

struct AddRewardView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = "🎁"
    @State private var cost = 50

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Icon", text: $icon).frame(width: 44)
                    TextField("Reward", text: $title)
                }
                Stepper("Costs \(cost) points", value: $cost, in: 5...1000, step: 5)
            }
            .navigationTitle("New reward")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await store.addReward(title: title, icon: icon, cost: cost); dismiss() } }
                        .disabled(title.isEmpty)
                }
            }
        }
    }
}
