# Big videos: accept 500 MB+ clips and make a 1080p copy on the server

Status: **proposed, waiting for approval**. Branch `claude/elegant-lamport-rdwcm8`.

## The problem, measured

The size limit is not what stops big videos. `/api/media/upload` and
`media_items_guard` already accept a 2 GiB video (`VIDEO_MAX_BYTES`,
`platform_settings.media_max_bytes`). What happened in production on
2026-10-06/07 (Vercel runtime logs plus `media_items`, sizes only):

| Signed upload | Row created? |
|---|---|
| 1,347,165,801 B `video/quicktime` (02:49 UTC) | no |
| 1,347,165,801 B `video/quicktime` (04:59 UTC, retry) | no |
| 356,045,589 B `video/quicktime` (23:39 UTC) | no |
| 11–37 MB `video/quicktime` (5 clips) | yes: 4K and 2192×2928 originals, no poster |

So:

1. **Big uploads fail on the phone.** The PUT to Blob is one long request
   from a foreground `URLSession`. A 1.35 GB file takes minutes; any drop or
   app switch loses all of it, and the server never sees why (Blob PUTs don't
   pass through our functions).
2. **The installed iPhone app predates #35.** The uploads have no poster and
   keep their `.mov` original, so the phone is not yet running the build
   that makes a 1080p HEVC copy before uploading. #35 alone would turn that
   1.35 GB clip into roughly 100–150 MB, but only while Ohana stays open,
   and when its export fails the original still goes up as is.
3. **Nothing on the server makes a light copy.** Whatever the phone doesn't
   optimize (fallbacks, older app builds, the 5 originals already stored)
   stays heavy forever, and the Pi decodes 4K 10-bit HDR or software H.264.

Benchmark (this container, 4 cores, ffmpeg 6.1): 10 s of 4K60 10-bit HLG
HEVC at 40 Mb/s (50 MB) → 1080p30 8-bit SDR HEVC: **21 s wall, 77 CPU-s,
4.6 MB** (x265 `fast`, CRF 26, zscale + hable tone map). Decoding 4K and
tone mapping dominate. A 500 MB clip is about **13 CPU-minutes**, so about
3.5 min on 4 vCPU or 2 min on 8.

## What we build

Every video ends up **wall-ready**: HEVC (`hvc1`) Main 8-bit, long side
≤ 1920 (never upscaled), ≤ 30 fps, SDR BT.709, AAC, index first (`+faststart`),
location metadata dropped. That is the same target the phone already makes.

- The phone keeps its fast path (it optimizes before uploading and marks the
  row `processing = 'done'`).
- Anything else gets a server copy: a fallback original (`'pending'`), rows from
  older app builds (`null`), and the 5 originals already stored.
- A job runs in a **Vercel Sandbox** (a Firecracker microVM on the
  `homeos-admin` project, created with the project's OIDC token: no new
  vendor and no new credential for compute). The sandbox only gets presigned
  URLs: GET for the source, PUT for `<family>/<id>-wall.mp4` (capped at the
  source's size) and, if the row has none, a PUT for the poster. It never
  holds Blob or database credentials.
- When the job reports back, the admin app checks the copy with Blob `head()`
  (the real byte size, which must not exceed the original's). It then asks a new
  `media-jobs` edge function to swap the row: `storage_path` → the `-wall.mp4`,
  `byte_size` → its real size (the family quota shrinks), `content_type`,
  width and height, plus the poster when the row had none. The original is
  deleted at least 6 h later, because displays reuse a signed URL for up to
  4 h.
- Triggers: the phone calls `POST /api/media/process` after inserting a row
  it couldn't optimize, and a Vercel Cron sweep picks up anything missed
  (older apps, crashes, stuck jobs) and deletes replaced originals.
- **Off until configured.** With no `MEDIA_JOBS_SECRET`, the new routes
  answer 503 and uploads behave exactly as today.

```
phone ──PUT original──▶ Blob <family>/<id>.mov
  │ insert row (processing = pending)
  └─POST /api/media/process ─▶ admin app ─claim─▶ media-jobs fn ─▶ Postgres
                                   │ presign GET/PUT
                                   └─create sandbox, run worker.mjs (ffmpeg)
sandbox: GET source → ffprobe → ffmpeg → PUT <id>-wall.mp4 (+ poster)
         └─POST /api/media/process/done (HMAC token)
admin app: head(<id>-wall.mp4) → media-jobs finish → row swapped
cron sweep: retry stale/pending (max 3 tries), delete originals swapped ≥ 6 h ago
```

Cost per 500 MB clip: about 13 CPU-min plus about 0.55 GB of sandbox network,
so about **$0.10–0.15 on Pro** (CPU $0.128/h, network $0.15/GB). Hobby
includes 5 CPU-h, 20 GB of network and 5,000 sandboxes a month, which is
about 20–35 clips that size.

## Phases (risk first; each phase has its check)

| # | Phase | Size | Files | Verified by |
|---|---|---|---|---|
| 0 | **Spike: ffmpeg in a Sandbox.** One short-lived sandbox on `homeos-admin`: is ffmpeg (with libx265 + zimg) available, or how does it install (dnf, a static build pinned by sha256, or a VCR image)? Transcode a sample and time it. Stop it. Decides D3. | XS | none (notes in this file) | `ffmpeg -version` shows libx265 + zimg; sample timing recorded. **Gate:** if ffmpeg can't run there, stop and bring a Cloud Run or Fly worker as the alternative. |
| 1 | **Database.** `20261012000001_video_processing.sql`: `media_items.processing` (null, pending, processing, done or failed; a client may set only null, `pending` or `done`, and only on insert), service-only `media_jobs` (attempts, started_at, finished_at, replaced_path, error), guard freeze list, and RPCs `media_job_claim`, `media_job_finish`, `media_job_fail`, `media_job_replaced_due`, `media_job_replaced_cleared` (service_role only). | S | migration, `backend/tests/media_processing_test.sql` | `backend/tests/run.sh` green: the client freeze, allowed insert values, claim cap and staleness, finish only shrinks `byte_size`, canonical `-wall.mp4` path, stale attempt refused |
| 2 | **Edge function `media-jobs`.** A thin POST wrapper around those RPCs, with a constant-time compare of `x-media-jobs-secret` against `MEDIA_JOBS_SECRET` (unset gives 503). | S | `functions/media-jobs/{index,jobs,jobs.test}.ts` | `deno check` + `deno test` (CI) |
| 3 | **Worker.** `admin/lib/media/worker.mjs`, plain Node with no dependencies, which runs in the sandbox: download, ffprobe, plan (same rules as iOS `MediaTools.plan`), ffmpeg arguments, PUTs, callback. Pure functions are exported for tests. | M | `worker.mjs`, `tests/worker.test.mjs` | `npm test`: plan rules and arguments, plus a local end-to-end run on a 4K HDR sample with a fake HTTP server. The output must be HEVC 8-bit, BT.709, ≤ 1920, ≤ 30 fps, with `moov` first. Skipped where ffmpeg is missing. |
| 4 | **Orchestration and routes.** `lib/media/processing.ts` (claim, presign, sandbox start, HMAC callback token, finish/fail, sweep); routes `POST /api/media/process`, `POST /api/media/process/done` and `GET /api/media/process/sweep` (Vercel `CRON_SECRET`); `video.ts` accepts `-wall.mp4`; `/delete` also removes that id's leftovers (Blob `list` by `<family>/<id>` prefix); `vercel.json` cron; `next.config.ts` traces `worker.mjs`; `@vercel/sandbox` dependency. | M | above + `tests/processing.test.mjs` | `npm run lint && npm run typecheck && npm test && npm run build` |
| 5 | **iOS.** The insert sends `processing` (`done` after `prepareVideo`, `pending` for the original fallback) and retries without the field if the server is older (PostgREST unknown column). A `pending` row then calls `/api/media/process` without waiting on it. | S | `FamilyStore.swift`, `MediaView.swift` | iOS CI build green |
| 6 | **Docs.** ARCHITECTURE (Media), PLATFORM_SPEC (§1.13 processing, §2.5 `media-jobs`, §3 routes, §6 iOS), ADMIN (setup checklist), IOS (uploads), PLATFORM (migration list), README (function deploy). | S | docs | links resolve; reads as one story |
| 7 | **Rollout: production, only with a separate go-ahead.** Apply the migration, deploy `media-jobs`, set `MEDIA_JOBS_SECRET` in Supabase and Vercel, deploy the admin app, let the sweep backfill the 5 originals, then upload one real 500 MB+ clip. | — | — | That row ends `processing = 'done'` on a `-wall.mp4` with a smaller `byte_size` and a poster, and plays on the wall |

## Decision log

| # | Decision | Why |
|---|---|---|
| D1 | Keep the phone's optimizing and add server copies on top | Phone compute is free and makes the upload 5–10× smaller; the server makes sure everything ends up wall-ready. |
| D2 | Compute: Vercel Sandbox *(Q1)* | Same Vercel project; OIDC instead of a new credential; up to 8 vCPU; about $0.12 per 500 MB clip. |
| D3 | How ffmpeg gets into the sandbox: decided in Phase 0 | Can't be checked from here (vercel.com and github.com are blocked in this container). Preference: a fixed image, else a static build pinned by sha256. |
| D4 | Target: HEVC 8-bit `hvc1`, ≤ 1920 px, ≤ 30 fps, SDR BT.709, CRF 26 `fast`, AAC 128k, `+faststart`, metadata dropped. A file that already fits is left as is; one with its index at the end is only remuxed. | Matches the phone and the Pi's HEVC decoder; 11× smaller in the benchmark. |
| D5 | Replace the original *(Q3)*; delete it ≥ 6 h after the swap | Same "one file per item" rule as the phone; quota counts what is stored; the delay covers displays' 4 h signed-URL reuse. |
| D6 | Privileged row writes only through the `media-jobs` edge function, authenticated by a shared secret | The admin app still never holds the service role key. A leaked secret can only swap a video to its own `-wall.mp4` with a smaller size. |
| D7 | `byte_size` comes from Blob `head()`, never from the worker | The sandbox processes untrusted files; the quota must not depend on it. |
| D8 | Phone call to `/api/media/process` plus a cron sweep; at most 2 jobs at once, 3 tries | Fast when the phone is open; nothing gets lost when it isn't; bounded cost. |
| D9 | Off unless `MEDIA_JOBS_SECRET` is set | Merging and deploying changes nothing until setup is done. |
| D10 | The copy is `<family>/<id>-wall.mp4` | Keeps the media id in the name, so delete and poster logic keep working; never collides with an `.mp4` original. |

## Always / Never

- **Always:** the original stays playable until the swap; the quota uses the
  real Blob size; every phase lands with its check green.
- **Never:** Blob or database credentials inside the sandbox; the service role
  key in the admin app; display code changes (it re-signs by path already);
  deleting an original sooner than 6 h after its swap; production changes
  (migrations, functions, env, secrets) without the Phase 7 go-ahead.
- **Not in this change:**
  - iOS background `URLSession` uploads (surviving an app switch) and
    resumable multipart uploads from iOS. Both need testing on a device, and
    multipart uses Blob's undocumented `/mpu` protocol. Recommended next PR.
  - Keeping originals, HLS/adaptive streaming, and admin console UI for job
    state.

## Progress

| Phase | State | Notes |
|---|---|---|
| 0 Spike | not started | |
| 1 Database | not started | |
| 2 media-jobs | not started | |
| 3 Worker | not started | |
| 4 Routes | not started | |
| 5 iOS | not started | |
| 6 Docs | not started | |
| 7 Rollout | needs go-ahead | |
