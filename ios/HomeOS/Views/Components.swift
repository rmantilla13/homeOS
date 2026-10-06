import SwiftUI

extension Color {
    /// "#RRGGBB" → Color. Member colors are stored this way so the display and phone match.
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x7C6CF2
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

struct MemberAvatar: View {
    let member: Member?
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(Color(hex: member?.color ?? "#8E8E93"))
            .frame(width: size, height: size)
            .overlay {
                Text(member?.displayName.prefix(1).uppercased() ?? "?")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

let memberPalette = ["#E86A92", "#4F8EF7", "#F5A623", "#3DBE7A", "#7C6CF2", "#14B8A6", "#F97316"]

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
