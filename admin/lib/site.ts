// The public pages on ohanaos.co, /privacy and /support. The iOS app links
// them (Config.privacyPolicyURL, Config.supportURL), App Store Connect lists
// them, and the proxy lets them through without a sign-in.

export const PUBLIC_PATHS = ["/privacy", "/support"] as const;

/** Where people write to about their account, their data or the app. */
export const SUPPORT_EMAIL = "support@ohanaos.co";

/** Shown on the privacy policy. Change it whenever the policy changes. */
export const PRIVACY_UPDATED = "October 6, 2026";

// The iOS app's URL scheme (Config.urlScheme in ios/OhanaOS/App/Config.swift).

/** Opens the app with an invite code filled in. */
export const appInviteLink = (code: string) => `ohanaos://invite/${code}`;

/** Where Supabase Auth's invite emails send people: the app signs them in.
 *  Listed under Authentication → URL Configuration → Redirect URLs. */
export const APP_AUTH_CALLBACK_URL = "ohanaos://auth-callback";
