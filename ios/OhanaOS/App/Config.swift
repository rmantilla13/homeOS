import Foundation

// The anon key is designed to ship in client apps; row-level security does the
// protecting. A TestFlight or device build reads SupabaseURL, SupabaseAnonKey
// and MediaAPIURL from Info.plist (ios/Config/Local.xcconfig). The values
// below are the fallback for a simulator run that has no Local.xcconfig.
enum Config {
    static let unconfiguredMessage = "This build isn't connected to a Supabase project yet."

    static let supabaseURL: URL = url(forInfoKey: "SupabaseURL")
        ?? URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabaseAnonKey: String = string(forInfoKey: "SupabaseAnonKey") ?? "YOUR-ANON-KEY"
    static let mediaBucket = "family-media"
    static let avatarBucket = "avatars"
    /// The production admin app, which signs photo and video uploads.
    static let defaultMediaAPIURL = URL(string: "https://ohanaos.co")!
    /// Origin of the admin app that signs private photo and video uploads
    /// (Vercel Blob). Info.plist's MediaAPIURL (MEDIA_API_URL) when it names a
    /// real host, otherwise `defaultMediaAPIURL`: an empty value or the
    /// Local.xcconfig.example placeholder would send every upload nowhere.
    /// Only the origin is used. Profile avatars still use `avatarBucket`.
    static let mediaAPIURL: URL = {
        guard let configured = Config.url(forInfoKey: "MediaAPIURL"),
              let host = configured.host?.lowercased(),
              !host.contains("your-admin-app"), !host.contains("your-project") else {
            return Config.defaultMediaAPIURL
        }
        return configured
    }()
    /// Public pages on the production site, linked from Welcome and Profile.
    /// App Store Connect takes the same two URLs (docs/IOS.md → TestFlight).
    static let privacyPolicyURL = URL(string: "https://ohanaos.co/privacy")!
    static let supportURL = URL(string: "https://ohanaos.co/support")!
    /// Where email confirmations and admin email invites send people back to
    /// the app. Add it under Supabase → Authentication → URL Configuration →
    /// Redirect URLs.
    /// Software URL scheme. The app people see is Ohana Display.
    static let urlScheme = "ohanaos"
    static let authCallbackURL = URL(string: "\(urlScheme)://auth-callback")!

    static var isConfigured: Bool {
        let host = supabaseURL.host?.lowercased() ?? ""
        return !host.contains("your-project") && !supabaseAnonKey.isEmpty && supabaseAnonKey != "YOUR-ANON-KEY"
    }

    private static func string(forInfoKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = string(forInfoKey: key), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
