import Foundation

// The anon key is designed to ship in client apps; row-level security does the
// protecting. Replace these with your project's values (Supabase → Settings → API).
enum Config {
    static let supabaseURL = URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR-ANON-KEY"
    static let mediaBucket = "family-media"
    static let avatarBucket = "avatars"
    /// Origin of the admin app that signs private photo and video uploads
    /// (Vercel Blob). Set this to the deployment URL, with no path. Nil means
    /// an upload fails instead of landing in Supabase Storage. Profile
    /// avatars still use `avatarBucket`.
    static let mediaAPIURL: URL? = nil
    /// Where email confirmations and admin email invites send people back to
    /// the app. Add it under Supabase → Authentication → URL Configuration →
    /// Redirect URLs.
    static let authCallbackURL = URL(string: "homeos://auth-callback")!
}
