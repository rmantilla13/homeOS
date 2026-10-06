import type { Metadata } from "next";
import { PRIVACY_UPDATED, SUPPORT_EMAIL } from "@/lib/site";
import styles from "../public.module.css";

export const metadata: Metadata = {
  title: "Privacy policy",
  description: "What Ohana Display stores about you and your family, who can see it, and how to delete it.",
};

// Keep this in step with what the apps actually do: the iOS privacy manifest
// (ios/OhanaOS/PrivacyInfo.xcprivacy), the App Store privacy answers in
// docs/IOS.md, and account deletion (delete_my_account). Update
// PRIVACY_UPDATED in lib/site.ts with every change.
export default function PrivacyPage() {
  return (
    <>
      <h1>Privacy policy</h1>
      <p className={styles.updated}>Last updated {PRIVACY_UPDATED}</p>

      <p>
        Ohana Display is a family calendar, chore chart and photo frame that runs on a wall display and in an iPhone
        app. It is made by OhanaOS (&ldquo;we&rdquo;). This page explains what we store, why, who can see it, and how
        to delete it. We don&apos;t sell your data, show ads, or track you across other apps and websites.
      </p>

      <h2>What we store</h2>
      <ul>
        <li>
          <strong>Your account:</strong> your email address, your name, and a password (stored only as a secure
          hash). Optionally, a profile photo.
        </li>
        <li>
          <strong>What your family adds:</strong> calendar events, chores and points, rewards, shopping lists, meal
          plans, notes saved to the family memory, and photos and videos.
        </li>
        <li>
          <strong>Assistant chats:</strong> the questions you ask the Ohana assistant, in the app, through Siri or at
          the wall display, and its replies.
        </li>
        <li>
          <strong>Wall displays:</strong> each paired display&apos;s name and when it last checked in.
        </li>
        <li>
          <strong>Usage counts:</strong> how many assistant questions a family asks each day, to keep within daily
          limits.
        </li>
      </ul>
      <p>
        The iPhone app reads only the photos and videos you pick, and uses the microphone only while you dictate. It
        doesn&apos;t use your location or contacts, and it has no analytics or advertising code.
      </p>

      <h2>How we use it</h2>
      <p>
        Only to run Ohana Display for your family: to show your family&apos;s calendar, chores and photos on the wall
        and in the app, to let the assistant answer questions about them, and to keep the service secure. We
        don&apos;t use your family&apos;s content to train AI models.
      </p>

      <h2>Who can see it</h2>
      <ul>
        <li>
          <strong>Your family:</strong> everything your family adds is shared with the people in that family and its
          paired wall displays. Your assistant chats in the app and through Siri are visible only to you; questions
          asked at the wall display stay on that display.
        </li>
        <li>
          <strong>Our administrators:</strong> a small number of people who run the service can see account and
          family details to support you and keep the service safe. Changes they make are logged.
        </li>
        <li>
          <strong>Service providers</strong> that host and process data for us, only to provide Ohana Display:
          Supabase (database, sign-in and file storage), Vercel (the ohanaos.co website and photo and video storage)
          and Anthropic (the AI model behind the assistant, which receives your question and the family details
          needed to answer it).
        </li>
        <li>
          <strong>Apple:</strong> dictation in the app uses Apple&apos;s speech recognition, which may send your
          recording to Apple. Siri requests go through Apple. Apple&apos;s privacy policy covers both. The wall
          display&apos;s wake word and speech recognition run on the display itself; its audio never leaves it.
        </li>
      </ul>
      <p>We share data with others only when the law requires it.</p>

      <h2>Security</h2>
      <p>
        Data travels over encrypted connections (HTTPS). Database rules let each person read only their own families,
        and photos and videos are stored privately and shown through links that expire.
      </p>

      <h2>Children</h2>
      <p>
        Children join Ohana Display only through an invite from a parent in their family. A parent can remove a child
        from the family at any time, and can ask us to delete a child&apos;s account and data.
      </p>

      <h2>Keeping and deleting your data</h2>
      <p>
        We keep your data while you have an account. To delete your account, open the iPhone app, tap your avatar at the
        top of Home, and choose <strong>Delete account</strong>. That removes your login, your profile and photo, and your assistant
        chats right away.
      </p>
      <ul>
        <li>
          If you are the only person with a login in a family, that family is deleted too, with its calendar, chores,
          lists, photos, videos and displays.
        </li>
        <li>
          In a family that other people still use, your name stays on its screen with your points and what you added,
          as when you leave a family. A parent can remove it.
        </li>
        <li>
          If you are the last parent in a family where others have logins, make someone else a parent first.
        </li>
      </ul>
      <p>
        You can also email us to delete your account, a family, or particular data, or to get a copy of your data.
        Deleted data may remain in encrypted backups for a short time before it is overwritten.
      </p>

      <h2>Changes</h2>
      <p>
        If this policy changes, we&apos;ll update it here and change the date above.
      </p>

      <h2>Contact</h2>
      <p>
        Questions or requests: <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
      </p>
    </>
  );
}
