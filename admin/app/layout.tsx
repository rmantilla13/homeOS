import type { Metadata, Viewport } from "next";
import { inter } from "./fonts";
import "./globals.css";

export const metadata: Metadata = {
  title: { default: "Ohana Admin", template: "%s · Ohana Admin" },
  description: "Platform administration for Ohana.",
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#f1efeb" },
    { media: "(prefers-color-scheme: dark)", color: "#121214" },
  ],
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={inter.variable}>
      <body>{children}</body>
    </html>
  );
}
