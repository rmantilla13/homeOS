import SwiftUI
import UIKit

// Design tokens shared with the wall display (display/qml/Theme.qml): warm
// off-white canvas, white rounded cards, a calm blue accent and a
// blue → coral → amber glow, with soft pastel member colors.
enum Theme {
    static let background = Color(light: 0xF1EFEB, dark: 0x121317)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1E24)
    static let sunken = Color(light: 0xE9E6E0, dark: 0x2C2F38)
    static let text = Color(light: 0x1C1C1F, dark: 0xECEDEF)
    static let muted = Color(light: 0x77767B, dark: 0x8F95A1)
    static let divider = Color(light: 0xE4E0D9, dark: 0x30333C)
    static let accent = Color(rgb: 0x4F7CF7)
    static let accentSoft = Color(light: 0xE3EAFE, dark: 0x2A3554)
    static let success = Color(rgb: 0x3DB37A)
    static let warning = Color(rgb: 0xF2A93B)
    static let danger = Color(rgb: 0xE5604D)
    static let glow: [Color] = [0x5B7CF5, 0xF07F5A, 0xF6B94A, 0xFBE6B0].map { Color(rgb: $0) }

    static let radius: CGFloat = 28
    static let radiusSm: CGFloat = 18
    static let page: CGFloat = 20

    static let springy = Animation.spring(response: 0.38, dampingFraction: 0.75)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.55)
}

// MARK: Colors

extension Color {
    init(rgb: Int, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: opacity)
    }

    /// A color that follows light/dark mode.
    init(light: Int, dark: Int) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// "#RRGGBB" → Color. Member colors are stored this way so the display and phone match.
    init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8E9CE6
        self.init(rgb: value)
    }

    /// Scales brightness and saturation, e.g. to derive tag text from a member color.
    func adjusted(brightness: CGFloat, saturation: CGFloat = 1) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s * saturation, 1)),
                     brightness: Double(min(b * brightness, 1)), opacity: Double(a))
    }
}

extension UIColor {
    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Pastel member colors offered when adding someone (same family as the display's seed data).
let memberPalette = ["#EF8A6F", "#5FB3B3", "#F2B84B", "#8E9CE6", "#E58FB5", "#7CC08B", "#B48EE0"]

// MARK: Mood

/// The time-of-day palette: warm coral mornings, blue days, violet evenings
/// and a dim indigo night. The accent and glow drift with it.
enum Mood: String, CaseIterable {
    case morning, day, evening, night

    init(date: Date) {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: self = .morning
        case 11..<17: self = .day
        case 17..<21: self = .evening
        default: self = .night
        }
    }

    var accent: Color {
        switch self {
        case .morning: return Color(rgb: 0xE9785B)
        case .day: return Color(rgb: 0x4F7CF7)
        case .evening: return Color(rgb: 0x7A66E8)
        case .night: return Color(rgb: 0x5A66C8)
        }
    }

    var accentSoft: Color { accent.opacity(0.14) }

    /// Four glow colors, left → right, plus a highlight on top.
    var glow: [Color] {
        switch self {
        case .morning: return [0xF07F5A, 0xF6A06A, 0xF6B94A, 0xFBE6B0].map { Color(rgb: $0) }
        case .day: return Theme.glow
        case .evening: return [0x6B5BE6, 0xB76AD8, 0xF07F5A, 0xF6C9A0].map { Color(rgb: $0) }
        case .night: return [0x27306E, 0x46398C, 0x6E4A8C, 0x2E3358].map { Color(rgb: $0) }
        }
    }

    var glowOpacity: Double { self == .night ? 0.55 : 0.9 }
}

private struct MoodKey: EnvironmentKey {
    static let defaultValue: Mood = .day
}

extension EnvironmentValues {
    var mood: Mood {
        get { self[MoodKey.self] }
        set { self[MoodKey.self] = newValue }
    }
}

/// Re-reads the clock every minute and eases the palette when the mood changes.
struct MoodProvider: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.everyMinute) { context in
            let mood = Mood(date: context.date)
            content
                .environment(\.mood, mood)
                .tint(mood.accent)
                .animation(.easeInOut(duration: 1.2), value: mood)
        }
    }
}

extension View {
    func providesMood() -> some View { modifier(MoodProvider()) }
}

// MARK: Glow

/// Soft layered glow (blurred circles in an arch) behind the assistant.
struct GlowView: View {
    @Environment(\.mood) private var mood
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let colors = mood.glow
            ZStack {
                Circle().fill(colors[0]).frame(width: w * 0.75, height: w * 0.75).offset(x: -w * 0.32, y: w * 0.12)
                Circle().fill(colors[1]).frame(width: w * 0.7, height: w * 0.7).offset(x: w * 0.02, y: w * 0.02)
                Circle().fill(colors[2]).frame(width: w * 0.7, height: w * 0.7).offset(x: w * 0.34, y: w * 0.12)
                Ellipse().fill(colors[3]).frame(width: w * 0.9, height: w * 0.35).offset(y: w * 0.32)
            }
            .frame(width: w, height: geo.size.height)
            .scaleEffect(breathe ? 1.05 : 0.97)
            .blur(radius: w * 0.16)
            .opacity(mood.glowOpacity)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: Cards, pills, tags

struct CardBackground: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 14, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Theme.radius) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }

    /// The screen canvas behind scroll views.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case prominent, soft, neutral, destructive }
    var kind: Kind = .prominent

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, kind: kind)
    }

    private struct PillLabel: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.mood) private var mood
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(foreground)
                .background(background, in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .prominent, .destructive: return .white
            case .soft: return mood.accent
            case .neutral: return Theme.text
            }
        }

        private var background: Color {
            switch kind {
            case .prominent: return mood.accent
            case .soft: return mood.accentSoft
            case .neutral: return Theme.sunken
            case .destructive: return Theme.danger
            }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillButtonStyle.Kind = .prominent) -> PillButtonStyle { PillButtonStyle(kind: kind) }
}

/// Slight press-down for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small uppercase tinted label, e.g. a member name on an activity card.
struct Tag: View {
    let text: String
    var color: Color = Theme.accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(scheme == .dark
                             ? color.adjusted(brightness: 1.3, saturation: 0.7)
                             : color.adjusted(brightness: 0.62, saturation: 1.2))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A member's circle: their profile photo if they have an account with one,
/// else their initial on their color.
struct MemberAvatar: View {
    let member: Member?
    var size: CGFloat = 36
    var ring = false
    @Environment(FamilyStore.self) private var store: FamilyStore?

    var body: some View {
        AvatarCircle(name: member?.displayName, color: member?.color, photo: store?.avatarPath(for: member),
                     size: size, ring: ring)
    }
}

/// A colored circle with an initial that fades to a photo from the
/// `avatars` bucket once it has loaded.
struct AvatarCircle: View {
    let name: String?
    var color: String?
    var photo: (path: String, version: String)?
    var size: CGFloat = 36
    var ring = false
    @State private var loaded: UIImage?

    private var photoKey: String? { photo.map { "\($0.path)#\($0.version)" } }

    var body: some View {
        let cached = photo.flatMap { AvatarCache.shared.cached(path: $0.path, version: $0.version) }
        let image = photo == nil ? nil : (cached ?? loaded)  // the current version first
        Circle()
            .fill(Color(hex: color ?? "#8E8E93"))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .transition(.opacity)
                } else {
                    Text(name?.prefix(1).uppercased() ?? "?")
                        .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                if ring { Circle().stroke(Theme.surface, lineWidth: 2) }
            }
            .task(id: photoKey) {
                guard let photo else {
                    loaded = nil
                    return
                }
                let image = await AvatarCache.shared.image(path: photo.path, version: photo.version)
                withAnimation(.easeOut(duration: 0.2)) { loaded = image }
            }
    }
}

/// Day / Week / Month style selector with a sliding pill.
struct SegmentedPill<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Namespace private var namespace
    @Environment(\.mood) private var mood

    init(_ options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Theme.springy) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white : Theme.text)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(mood.accent).matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
    }
}

/// Rounded suggestion chip ("Add activity", "Organize calendar").
struct Chip: View {
    let title: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
    }
}

/// Bold section title with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
            Spacer()
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

/// Thin rounded progress bar.
struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sunken)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 8)
        .animation(Theme.springy, value: value)
    }
}

/// Round accent button with an SF Symbol, e.g. the mic or "+".
struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color?
    let action: () -> Void
    @Environment(\.mood) private var mood

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint ?? mood.accent, in: Circle())
        }
        .buttonStyle(PressableStyle())
    }
}
