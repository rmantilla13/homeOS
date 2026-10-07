// Checks that a Vercel Sandbox on this project can make wall copies. It
// starts one the way a job does (lib/media/processing.ts), runs
// `worker.mjs --self-test` there (finds or downloads ffmpeg, then makes a
// copy of a made-up 4K60 HDR clip), prints the result and stops it.
//
//   cd admin && npx vercel link && npx vercel env pull .env.local
//   node --env-file=.env.local scripts/media-sandbox-check.mjs
//
// The last line is JSON; "ok": true means jobs will work. It costs about a
// minute of sandbox time.
import { mediaFfmpegEnv, mediaSandboxVcpus } from "../lib/env.ts";
import { startWorkerSandbox } from "../lib/media/processing.ts";

const name = `ohana-video-check-${Date.now().toString(36)}`;
const started = Date.now();
console.log(`starting sandbox ${name} (${mediaSandboxVcpus()} vCPUs)…`);
const sandbox = await startWorkerSandbox(name, null, { timeoutMs: 15 * 60_000, vcpus: mediaSandboxVcpus() });
try {
  console.log(`started in ${((Date.now() - started) / 1000).toFixed(1)} s, running the self-test…`);
  const result = await sandbox.runCommand({
    cmd: "node",
    args: ["worker.mjs", "--self-test"],
    cwd: "/vercel/sandbox",
    env: mediaFfmpegEnv(),
  });
  process.stdout.write(await result.stdout());
  const errors = await result.stderr();
  if (errors) process.stderr.write(errors);
  process.exitCode = result.exitCode === 0 ? 0 : 1;
} finally {
  await sandbox.stop().catch((err) => console.error("couldn't stop the sandbox:", err));
}
