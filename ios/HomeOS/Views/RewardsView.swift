import SwiftUI

/// Point balances, rewards to spend them on, and redemptions waiting on a parent.
struct RewardsBoard: View {
    @Environment(FamilyStore.self) private var store
    @State private var redeeming: Reward?

    private var earners: [Member] {
        store.kids.isEmpty ? store.members : store.kids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            balances
            if store.isParent && !store.redemptions.isEmpty {
                pendingRedemptions
            }
            rewardsGrid
        }
        .animation(Theme.springy, value: store.redemptions)
        .animation(Theme.springy, value: store.rewards)
        .confirmationDialog("Redeem \(redeeming?.title ?? "reward")",
                            isPresented: Binding(get: { redeeming != nil }, set: { if !$0 { redeeming = nil } }),
                            titleVisibility: .visible,
                            presenting: redeeming) { reward in
            ForEach(earners) { member in
                let balance = store.points[member.id] ?? 0
                Button("\(member.displayName) · \(balance) ★") {
                    Task { await store.redeem(reward, for: member) }
                }
            }
        } message: { reward in
            Text("Costs \(reward.cost) points. A parent marks it done when it's been given.")
        }
    }

    private var balances: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Balances")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(earners) { member in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                MemberAvatar(member: member, size: 32)
                                Text(member.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                            }
                            PointsText(value: store.points[member.id] ?? 0, font: .system(size: 30, weight: .bold, design: .rounded))
                            if store.isParent {
                                HStack(spacing: 6) {
                                    Button("−5") { Task { await store.adjustPoints(member: member, delta: -5, reason: "Adjustment") } }
                                        .buttonStyle(.pill(.neutral))
                                    Button("+5") { Task { await store.adjustPoints(member: member, delta: 5, reason: "Bonus") } }
                                        .buttonStyle(.pill(.soft))
                                }
                            }
                        }
                        .frame(width: 160, alignment: .leading)
                        .card(padding: 16, radius: Theme.radiusSm + 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private var pendingRedemptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("To hand out")
            ForEach(store.redemptions) { redemption in
                let reward = store.reward(redemption.rewardId)
                let member = store.member(redemption.memberId)
                HStack(spacing: 12) {
                    Text(reward?.icon ?? "🎁")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Theme.sunken, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reward?.title ?? "Reward").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("\(member?.displayName ?? "Someone") · \(redemption.cost) ★")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    Button("Cancel") { Task { await store.resolve(redemption, fulfilled: false) } }
                        .buttonStyle(.pill(.neutral))
                    Button("Done") { Task { await store.resolve(redemption, fulfilled: true) } }
                        .buttonStyle(.pill())
                }
                .card(padding: 14, radius: Theme.radiusSm + 4)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    private var rewardsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Rewards")
            if store.rewards.isEmpty {
                EmptyCard(text: store.isParent ? "Add a reward with +." : "No rewards yet.", systemImage: "gift")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(store.rewards) { reward in
                    let affordable = earners.contains { (store.points[$0.id] ?? 0) >= reward.cost }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(reward.icon ?? "🎁").font(.system(size: 38))
                        Text(reward.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2, reservesSpace: true)
                        HStack {
                            PointsText(value: reward.cost, font: .subheadline.weight(.semibold))
                            Spacer()
                            Button("Redeem") { redeeming = reward }
                                .buttonStyle(.pill(affordable ? .prominent : .neutral))
                        }
                    }
                    .card(padding: 14, radius: Theme.radiusSm + 4)
                    .contextMenu {
                        if store.isParent {
                            Button("Remove reward", systemImage: "trash", role: .destructive) {
                                Task { await store.archiveReward(reward) }
                            }
                        }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

struct AddRewardView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = "🎁"
    @State private var cost = 50

    private let icons = ["🎁", "🍦", "🎮", "📺", "🍕", "🎬", "🛝", "🧁", "⏰", "📱"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reward", text: $title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(icons, id: \.self) { emoji in
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(emoji == icon ? Theme.accentSoft : Theme.sunken, in: Circle())
                                    .onTapGesture { withAnimation(Theme.springy) { icon = emoji } }
                            }
                        }
                    }
                }
                Section {
                    Stepper("Costs \(cost) points", value: $cost, in: 5...1000, step: 5)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("New reward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await store.addReward(title: title, icon: icon, cost: cost); dismiss() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
