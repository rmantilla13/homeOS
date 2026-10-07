import "server-only";
import type {
  Admin,
  AuditEntry,
  BootVideo,
  Device,
  Family,
  FamilyInvite,
  Member,
  MemberRole,
  PlatformInvite,
  Settings,
  UsageDay,
} from "@/lib/types";

// Fixture data for demo mode (NEXT_PUBLIC_ADMIN_DEMO=1). Deterministic (seeded)
// and relative to when the server started, so screenshots always look fresh.
// People use reserved example domains; nothing here is a real account.

export type DemoFamily = Family & {
  members: Member[];
  devices: Device[];
  invites: FamilyInvite[];
  usage: UsageDay[]; // the last USAGE_DAYS days, oldest first
};

export type DemoUser = {
  id: string;
  email: string;
  display_name: string;
  created_at: string;
  last_sign_in_at: string | null;
  banned: boolean;
  is_admin: boolean;
};

export type DemoState = {
  admin: Admin;
  families: DemoFamily[];
  users: DemoUser[];
  invites: PlatformInvite[];
  settings: Settings;
  bootVideo: BootVideo | null;
  audit: AuditEntry[];
  nextAuditId: number;
  bannedDevices: string[]; // device auth users that were banned
};

export const USAGE_DAYS = 90;
const INVITE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MEMBER_COLORS = ["#E9846F", "#5BAFA8", "#E9B44C", "#8E9CE6", "#D98CB3", "#7DB46C"];

// mulberry32: tiny seeded PRNG, good enough for fixtures.
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

type Spec = {
  name: string;
  tz: string;
  createdDaysAgo: number;
  perDay: number; // typical assistant requests per day
  lastActiveHours: number;
  suspended?: { daysAgo: number; reason: string };
  dailyLimit?: number;
  members: [name: string, role: MemberRole, email?: string, fullName?: string][];
  devices: [name: string, lastSeenMinutes: number][];
  invites?: { role: MemberRole; email?: string; claim?: string; state: "active" | "accepted" | "expired" | "revoked"; daysAgo: number }[];
};

const SPECS: Spec[] = [
  {
    name: "The Parks", tz: "America/Los_Angeles", createdDaysAgo: 142, perDay: 34, lastActiveHours: 0.2,
    members: [["Maya", "parent", "maya.park@example.com", "Maya Park"], ["Daniel", "parent", "daniel.park@example.com", "Daniel Park"], ["Emma", "child"], ["Leo", "child"]],
    devices: [["Kitchen display", 1], ["Hallway display", 6]],
    invites: [
      { role: "parent", email: "daniel.park@example.com", state: "accepted", daysAgo: 140 },
      { role: "other", email: "grandma.park@example.com", state: "active", daysAgo: 3 },
    ],
  },
  {
    name: "Rivera Family", tz: "America/Chicago", createdDaysAgo: 118, perDay: 22, lastActiveHours: 1.5,
    members: [["Sofia", "parent", "sofia.rivera@example.com", "Sofia Rivera"], ["Marco", "parent", "marco.rivera@example.org", "Marco Rivera"], ["Lucía", "child"], ["Mateo", "child"], ["Abuela Rosa", "other"]],
    devices: [["Kitchen", 3]],
    invites: [{ role: "parent", email: "marco.rivera@example.org", state: "accepted", daysAgo: 117 }],
  },
  {
    name: "The Okafors", tz: "Europe/London", createdDaysAgo: 96, perDay: 18, lastActiveHours: 3,
    members: [["Ada", "parent", "ada.okafor@example.com", "Ada Okafor"], ["Chidi", "parent", "chidi.okafor@example.com", "Chidi Okafor"], ["Tobi", "child"], ["Zara", "child"]],
    devices: [["Living room", 12]],
    invites: [
      { role: "parent", email: "chidi.okafor@example.com", state: "accepted", daysAgo: 95 },
      { role: "child", claim: "Tobi", state: "expired", daysAgo: 30 },
    ],
  },
  {
    name: "Patel Household", tz: "America/New_York", createdDaysAgo: 88, perDay: 27, lastActiveHours: 0.5,
    members: [["Priya", "parent", "priya.patel@example.com", "Priya Patel"], ["Raj", "parent", "raj.patel@example.com", "Raj Patel"], ["Anika", "child", "anika.patel@example.com", "Anika Patel"], ["Dev", "child"], ["Nani", "other"]],
    devices: [["Kitchen", 2], ["Upstairs landing", 45]],
    invites: [
      { role: "parent", email: "raj.patel@example.com", state: "accepted", daysAgo: 87 },
      { role: "child", claim: "Anika", state: "accepted", daysAgo: 40 },
    ],
  },
  {
    name: "Lindqvist House", tz: "Europe/Stockholm", createdDaysAgo: 74, perDay: 9, lastActiveHours: 212,
    members: [["Erik", "parent", "erik.lindqvist@example.net", "Erik Lindqvist"], ["Anna", "parent", "anna.lindqvist@example.net", "Anna Lindqvist"], ["Nils", "child"]],
    devices: [["Hall", 25]],
    invites: [{ role: "parent", email: "anna.lindqvist@example.net", state: "accepted", daysAgo: 70 }],
  },
  {
    name: "The Nguyens", tz: "America/Los_Angeles", createdDaysAgo: 63, perDay: 15, lastActiveHours: 5,
    members: [["Linh", "parent", "linh.nguyen@example.com", "Linh Nguyen"], ["Bao", "parent", "bao.nguyen@example.com", "Bao Nguyen"], ["Mai", "child"], ["An", "child"]],
    devices: [["Kitchen", 8], ["Office", 300]],
    invites: [
      { role: "parent", email: "bao.nguyen@example.com", state: "accepted", daysAgo: 62 },
      { role: "parent", email: "bao.n@example.com", state: "revoked", daysAgo: 62 },
    ],
  },
  {
    name: "The Bakers", tz: "Europe/London", createdDaysAgo: 57, perDay: 12, lastActiveHours: 98,
    suspended: { daysAgo: 4, reason: "Owner asked to pause the account while they move house." },
    members: [["Tom", "parent", "tom.baker@example.org", "Tom Baker"], ["Jess", "parent", "jess.baker@example.org", "Jess Baker"], ["Ollie", "child"]],
    devices: [["Kitchen", 5900]],
  },
  {
    name: "Chen-Morales", tz: "America/Denver", createdDaysAgo: 49, perDay: 11, lastActiveHours: 9,
    members: [["Wei", "parent", "wei.chen@example.com", "Wei Chen"], ["Lucia", "parent", "lucia.morales@example.com", "Lucia Morales"], ["Iris", "child"]],
    devices: [["Kitchen", 40]],
    invites: [{ role: "parent", email: "lucia.morales@example.com", state: "accepted", daysAgo: 48 }],
  },
  {
    name: "Hartley Family", tz: "Australia/Sydney", createdDaysAgo: 35, perDay: 14, lastActiveHours: 2,
    dailyLimit: 400,
    members: [["Grace", "parent", "grace.hartley@example.com", "Grace Hartley"], ["Ben", "child"], ["Ruby", "child"]],
    devices: [["Kitchen", 4]],
  },
  {
    name: "The O'Briens", tz: "Europe/Dublin", createdDaysAgo: 21, perDay: 16, lastActiveHours: 7,
    members: [["Siobhán", "parent", "siobhan.obrien@example.net", "Siobhán O'Brien"], ["Liam", "parent", "liam.obrien@example.net", "Liam O'Brien"], ["Aoife", "child"], ["Cian", "child"], ["Niamh", "child"]],
    devices: [["Kitchen", 30]],
    invites: [{ role: "parent", email: "liam.obrien@example.net", state: "accepted", daysAgo: 20 }],
  },
  {
    name: "The Kowalskis", tz: "Europe/Warsaw", createdDaysAgo: 9, perDay: 4, lastActiveHours: 30,
    members: [["Kasia", "parent", "kasia.kowalska@example.com", "Kasia Kowalska"], ["Piotr", "parent"], ["Zosia", "child"]],
    devices: [],
    invites: [{ role: "parent", email: "piotr.kowalski@example.com", claim: "Piotr", state: "active", daysAgo: 8 }],
  },
  {
    name: "Fischer Family", tz: "Europe/Berlin", createdDaysAgo: 2, perDay: 3, lastActiveHours: 26,
    members: [["Jonas", "parent", "jonas.fischer@example.com", "Jonas Fischer"], ["Lena", "parent"]],
    devices: [],
    invites: [{ role: "parent", email: "lena.fischer@example.com", claim: "Lena", state: "active", daysAgo: 2 }],
  },
];

export function buildDemoState(now = Date.now()): DemoState {
  const rand = rng(20261007);
  const ago = (ms: number) => new Date(now - ms).toISOString();
  const minutes = (m: number) => ago(m * 60_000);
  const hours = (h: number) => ago(h * 3_600_000);
  const days = (d: number) => ago(d * 86_400_000);
  const ahead = (d: number) => new Date(now + d * 86_400_000).toISOString();
  const uuid = () => {
    const hex = Array.from({ length: 32 }, () => Math.floor(rand() * 16).toString(16)).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
  };
  const code = () => {
    const c = Array.from({ length: 8 }, () => INVITE_ALPHABET[Math.floor(rand() * 32)]).join("");
    return `${c.slice(0, 4)}-${c.slice(4)}`;
  };
  const pick = <T,>(xs: T[]) => xs[Math.floor(rand() * xs.length)];

  // UTC days, oldest first, ending today.
  const today = new Date(new Date(now).toISOString().slice(0, 10) + "T00:00:00Z").getTime();
  const dayKeys = Array.from({ length: USAGE_DAYS }, (_, i) =>
    new Date(today - (USAGE_DAYS - 1 - i) * 86_400_000).toISOString().slice(0, 10),
  );

  const admin: DemoUser = {
    id: uuid(), email: "alex@homeos.example", display_name: "Alex Morgan",
    created_at: days(160), last_sign_in_at: minutes(12), banned: false, is_admin: true,
  };
  const users: DemoUser[] = [
    admin,
    { id: uuid(), email: "sam@homeos.example", display_name: "Sam Ito", created_at: days(158), last_sign_in_at: days(2), banned: false, is_admin: true },
  ];

  const families: DemoFamily[] = SPECS.map((spec) => {
    const id = uuid();
    const created = spec.createdDaysAgo;
    const members: Member[] = spec.members.map(([name, role, email, fullName], i) => {
      let user_id: string | null = null;
      if (email) {
        user_id = uuid();
        users.push({
          id: user_id, email, display_name: fullName ?? name,
          created_at: days(Math.max(created - i * 0.6, 0.2)),
          last_sign_in_at: hours(spec.lastActiveHours + i * 7 + rand() * 30),
          banned: false, is_admin: false,
        });
      }
      return {
        id: uuid(), user_id, display_name: name, role, color: MEMBER_COLORS[i % MEMBER_COLORS.length],
        created_at: days(Math.max(created - i * 0.5, 0.1)), email: email ?? null, profile_name: email ? fullName ?? name : null,
      };
    });
    const devices: Device[] = spec.devices.map(([name, lastSeen], i) => ({
      id: uuid(), user_id: uuid(), name, last_seen_at: minutes(lastSeen),
      created_at: days(Math.max(created - 1 - i * 5, 0.1)),
    }));
    const invites: FamilyInvite[] = (spec.invites ?? []).map((inv) => ({
      id: uuid(), code: code(), role: inv.role,
      member_id: inv.claim ? members.find((m) => m.display_name === inv.claim)?.id ?? null : null,
      email: inv.email ?? null,
      created_at: days(inv.daysAgo),
      expires_at: inv.state === "expired" ? days(inv.daysAgo - 14) : ahead(14 - inv.daysAgo),
      accepted_at: inv.state === "accepted" ? days(inv.daysAgo - 0.3) : null,
      revoked_at: inv.state === "revoked" ? days(inv.daysAgo - 0.1) : null,
      invited_by_email: members[0].email ?? null,
      status: inv.state,
    }));

    // Requests per day: weekends busier, a gentle upward trend, nothing
    // before the family existed or after it was suspended.
    const usage: UsageDay[] = dayKeys.map((day, i) => {
      const age = USAGE_DAYS - 1 - i;
      const quietDays = Math.floor(spec.lastActiveHours / 24);
      if (age > created || age < quietDays || (spec.suspended && age < spec.suspended.daysAgo)) {
        return { day, requests: 0, input_tokens: 0, output_tokens: 0 };
      }
      const weekday = new Date(day + "T00:00:00Z").getUTCDay();
      const weekend = weekday === 0 || weekday === 6 ? 1.35 : 1;
      const trend = 0.75 + 0.25 * (i / USAGE_DAYS);
      const requests = Math.max(0, Math.round(spec.perDay * weekend * trend * (0.6 + rand() * 0.8)));
      const input = requests * Math.round(3800 + rand() * 2400);
      const output = requests * Math.round(140 + rand() * 260);
      return { day, requests, input_tokens: input, output_tokens: output };
    });
    // Today is only partly over.
    const last = usage[usage.length - 1];
    const part = new Date(now).getUTCHours() / 24;
    usage[usage.length - 1] = {
      ...last, requests: Math.round(last.requests * part),
      input_tokens: Math.round(last.input_tokens * part), output_tokens: Math.round(last.output_tokens * part),
    };

    return {
      id, name: spec.name, timezone: spec.tz, created_at: days(created),
      status: spec.suspended ? "suspended" : "active",
      suspended_at: spec.suspended ? days(spec.suspended.daysAgo) : null,
      suspended_reason: spec.suspended?.reason ?? null,
      assistant_daily_limit: spec.dailyLimit ?? null,
      last_activity: hours(spec.lastActiveHours),
      members, devices, invites, usage,
    };
  });

  users.push(
    { id: uuid(), email: "hannah.weiss@example.org", display_name: "Hannah Weiss", created_at: days(1.2), last_sign_in_at: days(1.2), banned: false, is_admin: false },
    { id: uuid(), email: "deals4you@example.net", display_name: "deals4you", created_at: days(15), last_sign_in_at: days(15), banned: true, is_admin: false },
  );

  const invite = (p: Partial<PlatformInvite> & { status: PlatformInvite["status"] }): PlatformInvite => ({
    id: uuid(), code: code(), email: null, note: null, max_uses: 1, use_count: 0,
    expires_at: ahead(30), created_at: days(1), revoked_at: null,
    created_by_email: pick([admin.email, "sam@homeos.example"]), ...p,
  });
  const invites: PlatformInvite[] = [
    invite({ status: "active", email: "erin.andersen@example.com", note: "Andersen family, referred by the Parks", created_at: hours(5), expires_at: ahead(29.8) }),
    invite({ status: "active", note: "Beta wave 3 (newsletter)", max_uses: 25, use_count: 9, created_at: days(11), expires_at: ahead(19) }),
    invite({ status: "active", email: "kofi.mensah@example.org", note: "Met at the school fair", created_at: days(6), expires_at: ahead(24) }),
    invite({ status: "active", note: "Spare for support", created_at: days(27), expires_at: ahead(3) }),
    invite({ status: "used", email: "jonas.fischer@example.com", created_at: days(4), expires_at: ahead(26), use_count: 1 }),
    invite({ status: "used", email: "kasia.kowalska@example.com", created_at: days(12), expires_at: ahead(18), use_count: 1 }),
    invite({ status: "used", note: "Beta wave 2", max_uses: 20, use_count: 20, created_at: days(70), expires_at: days(40) }),
    invite({ status: "expired", email: "tom.h@example.net", note: "Follow up after the holidays", created_at: days(33), expires_at: days(3) }),
    invite({ status: "revoked", note: "Posted publicly by mistake", max_uses: 10, use_count: 2, created_at: days(16), expires_at: ahead(14), revoked_at: days(9) }),
    invite({ status: "used", email: "maya.park@example.com", note: "Founding family", created_at: days(150), expires_at: days(120), use_count: 1 }),
  ];

  const byName = (name: string) => families.find((f) => f.name === name)!;
  const a = (
    at: string, action: string, target_type: string | null, target_id: string | null,
    details: Record<string, unknown>, email = admin.email,
  ) => ({ created_at: at, admin_email: email, action, target_type, target_id, details });
  const auditRaw = [
    a(hours(5), "invite_email", "platform_invite", invites[0].id, { email: invites[0].email, email_sent: true }),
    a(hours(5), "create_platform_invite", "platform_invite", invites[0].id, { code: invites[0].code, email: invites[0].email, note: invites[0].note, max_uses: 1 }),
    a(hours(26), "update_settings", "settings", null, { assistant_daily_limit: 200 }, "sam@homeos.example"),
    a(days(4), "set_family_status", "family", byName("The Bakers").id, { status: "suspended", reason: byName("The Bakers").suspended_reason }),
    a(days(6), "create_platform_invite", "platform_invite", invites[2].id, { code: invites[2].code, email: invites[2].email, note: invites[2].note, max_uses: 1 }),
    a(days(9), "revoke_platform_invite", "platform_invite", invites[8].id, { code: invites[8].code }, "sam@homeos.example"),
    a(days(11), "create_platform_invite", "platform_invite", invites[1].id, { code: invites[1].code, note: invites[1].note, max_uses: 25 }),
    a(days(13), "delete_family", "family", uuid(), { name: "Test family (QA)", device_accounts_removed: 1 }),
    a(days(14), "ban_user", "user", users[users.length - 1].id, { email: "deals4you@example.net" }),
    a(days(15), "delete_user", "user", uuid(), { email: "qa+bot@homeos.example" }),
    a(days(18), "set_family_status", "family", byName("Hartley Family").id, { status: "active", reason: "Verified with Grace by email" }, "sam@homeos.example"),
    a(days(19), "set_family_status", "family", byName("Hartley Family").id, { status: "suspended", reason: "Unusual assistant volume, checking in" }, "sam@homeos.example"),
    a(days(22), "set_admin", "user", users[1].id, { make_admin: true, email: "sam@homeos.example" }),
    a(days(27), "create_platform_invite", "platform_invite", invites[3].id, { code: invites[3].code, note: invites[3].note, max_uses: 1 }),
    a(days(33), "invite_email", "platform_invite", invites[7].id, { email: invites[7].email, email_sent: true }),
    a(days(40), "update_settings", "settings", null, { invite_only: true }),
  ];
  const audit: AuditEntry[] = auditRaw.map((e, i) => ({ id: auditRaw.length - i + 40, ...e }));

  return {
    admin: { id: admin.id, email: admin.email },
    families,
    users,
    invites,
    settings: {
      invite_only: true, assistant_enabled: true, assistant_daily_limit: 200,
      updated_at: hours(26), updated_by: users[1].id,
    },
    bootVideo: {
      byte_size: 3285,
      duration_ms: 2000,
      updated_at: hours(2),
      preview_url: "/demo-boot.mp4",
    },
    audit,
    nextAuditId: auditRaw.length + 41,
    bannedDevices: [],
  };
}

