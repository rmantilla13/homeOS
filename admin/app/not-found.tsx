import Link from "next/link";
import styles from "./login/login.module.css";

export default function NotFound() {
  return (
    <main className={styles.page}>
      <div className={styles.card}>
        <h1 className={styles.title}>Page not found</h1>
        <p className={styles.subtitle}>
          <Link href="/">Back to the console</Link>
        </p>
      </div>
    </main>
  );
}
