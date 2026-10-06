import Foundation

// The anon key is designed to ship in client apps; row-level security does the
// protecting. Replace these with your project's values (Supabase → Settings → API).
enum Config {
    static let supabaseURL = URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR-ANON-KEY"
    static let mediaBucket = "family-media"
}
