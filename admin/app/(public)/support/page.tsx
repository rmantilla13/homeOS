import type { Metadata } from "next";
import Link from "next/link";
import { SUPPORT_EMAIL } from "@/lib/site";

export const metadata: Metadata = {
  title: "Help and support",
  description: "Get started with Ohana Display, pair a wall display, and reach us.",
};

// Steps match the iPhone app's screens (docs/IOS.md → Screens).
export default function SupportPage() {
  return (
    <>
      <h1>Help and support</h1>
      <p>
        Something not working, or a question about your account? Email{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a> and we&apos;ll get back to you. Include the email you
        sign in with and what you were trying to do.
      </p>

      <h2>Getting started</h2>
      <p>
        Ohana Display is invite-only. Get an invite code from someone in your family, or use the one in your invite
        email. Open the app, enter the code, then create your account. A code that starts a new family makes you its
        first parent. To start a new family, ask for a code at <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
      </p>

      <h2>Common tasks</h2>
      <ul>
        <li>
          <strong>Invite someone:</strong> parents tap Family, then Invite, and share the code.
        </li>
        <li>
          <strong>Pair a wall display:</strong> parents tap Family, then Pair a display, and enter the 6-digit code
          the display shows.
        </li>
        <li>
          <strong>Add photos and videos:</strong> open Media and tap +.
        </li>
        <li>
          <strong>Ask Siri:</strong> say &ldquo;Ask Ohana Display&rdquo;, then your question.
        </li>
        <li>
          <strong>Leave a family:</strong> Family, then Leave family. Your name and points stay on its screen.
        </li>
        <li>
          <strong>Delete your account:</strong> tap your avatar at the top of Home or Family, then Delete account. See the{" "}
          <Link href="/privacy">privacy policy</Link> for what is deleted.
        </li>
      </ul>
    </>
  );
}
