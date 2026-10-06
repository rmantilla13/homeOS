"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { AuditIcon, FamilyIcon, InviteIcon, MediaIcon, OverviewIcon, SettingsIcon, UsersIcon } from "@/components/icons";
import styles from "./shell.module.css";

const LINKS = [
  { href: "/", label: "Overview", Icon: OverviewIcon },
  { href: "/families", label: "Families", Icon: FamilyIcon },
  { href: "/media", label: "Media", Icon: MediaIcon },
  { href: "/users", label: "Users", Icon: UsersIcon },
  { href: "/invites", label: "Invites", Icon: InviteIcon },
  { href: "/settings", label: "Settings", Icon: SettingsIcon },
  { href: "/audit", label: "Audit log", Icon: AuditIcon },
];

export function NavLinks() {
  const pathname = usePathname();
  return (
    <nav className={styles.nav} aria-label="Console">
      {LINKS.map(({ href, label, Icon }) => {
        const active = href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`);
        return (
          <Link key={href} href={href} className={styles.navLink} aria-current={active ? "page" : undefined}>
            <Icon />
            {label}
          </Link>
        );
      })}
    </nav>
  );
}
