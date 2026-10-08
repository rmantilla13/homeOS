import SwiftUI

/// Shows store errors as an alert on any screen.
struct ErrorAlert: ViewModifier {
    @Environment(FamilyStore.self) private var store

    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

extension View {
    func showsStoreErrors() -> some View { modifier(ErrorAlert()) }
}

/// Large screen title with a small line above it and optional trailing controls.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.muted)
                }
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.top, 8)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

extension FamilyStore {
    /// Event color: its own override, else its first member's, else the accent.
    func color(for event: FamilyEvent) -> Color {
        if let hex = event.color { return Color(hex: hex) }
        if let member = member(event.memberIds.first) { return Color(hex: member.color) }
        return Theme.accent
    }
}

func timeLabel(for event: FamilyEvent) -> String {
    if event.allDay { return "All day" }
    let start = event.startsAt.formatted(date: .omitted, time: .shortened)
    let end = event.endsAt.formatted(date: .omitted, time: .shortened)
    return "\(start) – \(end)"
}

func dayLabel(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
}

/// Member tags for an event, or FAMILY when it's for everyone.
struct MemberTags: View {
    @Environment(FamilyStore.self) private var store
    let memberIds: [UUID]

    var body: some View {
        let members = memberIds.compactMap { store.member($0) }
        HStack(spacing: 6) {
            if members.isEmpty {
                Tag(text: "Family", color: Theme.accent)
            } else {
                ForEach(members.prefix(3)) { member in
                    Tag(text: member.displayName, color: Color(hex: member.color))
                }
                if members.count > 3 {
                    Text("+\(members.count - 3)").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// "Your upcoming activities" card: tags, title, time and place.
struct ActivityCard: View {
    @Environment(FamilyStore.self) private var store
    let event: FamilyEvent
    var showsDay = true

    var body: some View {
        let color = store.color(for: event)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                MemberTags(memberIds: event.memberIds)
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label(showsDay ? "\(dayLabel(for: event.startsAt)) · \(timeLabel(for: event))" : timeLabel(for: event),
                          systemImage: "clock")
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .labelStyle(CompactLabelStyle())
            }
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 5, height: 44)
        }
        .card()
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption)
            configuration.title
        }
    }
}

/// A chore waiting for a parent's OK.
struct ApprovalCard: View {
    @Environment(FamilyStore.self) private var store
    let completion: TaskCompletion

    var body: some View {
        let task = store.task(completion.taskId)
        let member = store.member(completion.memberId)
        HStack(spacing: 12) {
            MemberAvatar(member: member, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task?.icon ?? "✔️") \(task?.title ?? "Chore")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(member?.displayName ?? "Someone") · +\(task?.points ?? 0) points")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button { Task { await store.review(completion, approve: false) } } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.pill(.neutral))
            .accessibilityLabel("Reject")
            Button { Task { await store.review(completion, approve: true) } } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.pill())
            .accessibilityLabel("Approve")
        }
        .card(padding: 14, radius: Theme.radiusSm + 4)
    }
}

/// Muted placeholder card for empty sections.
struct EmptyCard: View {
    let text: String
    var systemImage = "sparkles"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(Theme.muted)
            Text(text).font(.subheadline).foregroundStyle(Theme.muted)
        }
        .card(padding: 16)
    }
}

/// Animated points label (rolls digits when the value changes).
struct PointsText: View {
    let value: Int
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .contentTransition(.numericText(value: Double(value)))
                .animation(Theme.springy, value: value)
            Image(systemName: "star.fill").font(.caption)
        }
        .font(font.monospacedDigit())
        .foregroundStyle(Theme.warning)
    }
}

/// A soft blur that eases content out where it meets a screen edge or a bar:
/// a light material that fades from full to nothing, with a wash of the
/// screen color over it. Sits on top of scrolling content and never takes taps.
struct EdgeFade: View {
    let edge: VerticalEdge

    var body: some View {
        let fade = LinearGradient(colors: [.black, .black.opacity(0.7), .clear],
                                  startPoint: edge == .top ? .top : .bottom,
                                  endPoint: edge == .top ? .bottom : .top)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Theme.background.opacity(0.55)
        }
        .mask(fade)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Blurs content out under the status bar and above the bottom bar.
    /// `bottom` is how far the bottom fade reaches above the safe area.
    func softEdges(top: CGFloat = 28, bottom: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            if top > 0 {
                EdgeFade(edge: .top)
                    .frame(height: top)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .overlay(alignment: .bottom) {
            if bottom > 0 {
                EdgeFade(edge: .bottom)
                    .frame(height: bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}
