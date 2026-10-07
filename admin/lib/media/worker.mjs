// Runs inside a Vercel Sandbox for one video. It makes the copy the wall
// plays well (HEVC 8-bit SDR, at most 1920 px and 30 fps, index first, no
// location) and reports back. It only gets presigned URLs for this one
// video, never Blob or database credentials. Plain Node with no
// dependencies: the admin app writes this file and job.json into the
// sandbox and runs it (lib/media/processing.ts).
//
//   node worker.mjs job.json     do the job, then POST the result to job.callback_url
//   node worker.mjs --self-test  check ffmpeg here on a made-up 4K HDR clip
//                                (scripts/media-sandbox-check.mjs runs this in a sandbox)
//
// The rules match the iPhone's (MediaTools.plan in
// ios/OhanaOS/Services/MediaTools.swift), so a video comes out the same
// whichever side made it.

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, createWriteStream, openAsBlob } from "node:fs";
import { mkdir, open, readFile, readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { pathToFileURL } from "node:url";

/** The wall panel is 1920×1200: more pixels are only more bytes to send. */
export const WALL_MAX_LONG_SIDE = 1920;
/** An iPhone's own 1080p30 is about 6–12 Mb/s. Above this, shrinking pays. */
export const PASSTHROUGH_MAX_BITS_PER_SECOND = 16_000_000;
/** 30 fps, with room for 29.97 and variable frame rates. */
export const MAX_FRAME_RATE = 31;
/** The largest poster the media service signs (THUMB_MAX_BYTES in video.ts). */
export const POSTER_MAX_BYTES = 256 * 1024;
/** Used when the sandbox image has no ffmpeg. MEDIA_FFMPEG_URL overrides it. */
export const DEFAULT_FFMPEG_URL =
  "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz";

const HDR_TRANSFERS = new Set(["smpte2084", "arib-std-b67"]);
const FFMPEG_TIMEOUT_MS = 40 * 60 * 1000;

/** A failure another try wouldn't fix (not a video, a copy that won't shrink). */
export class FinalError extends Error {}

// ───────────────────────────── Reading the file ─────────────────────────────

const num = (value) => {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
};

/** "30000/1001" → 29.97; "0/0" or garbage → 0. */
export function frameRate(value) {
  if (typeof value !== "string") return 0;
  const [top, bottom = "1"] = value.split("/");
  const rate = Number(top) / Number(bottom);
  return Number.isFinite(rate) && rate > 0 ? rate : 0;
}

function rotationOf(stream) {
  for (const data of stream.side_data_list ?? []) {
    if (typeof data.rotation === "number") return data.rotation;
  }
  return Number(stream.tags?.rotate) || 0;
}

function bitDepthOf(stream) {
  const raw = Number(stream.bits_per_raw_sample);
  if (Number.isInteger(raw) && raw > 0) return raw;
  const match = /p(\d+)(le|be)?$/.exec(stream.pix_fmt ?? "");
  return match ? Number(match[1]) : 8;
}

/**
 * What ffprobe's JSON (-show_streams -show_format) says about the first
 * video stream, in the terms the plan uses. Width and height are as shown,
 * after rotation. Null when there is no video stream.
 */
export function parseProbe(probe, fileBytes = 0) {
  const streams = Array.isArray(probe?.streams) ? probe.streams : [];
  const video = streams.find((s) => s.codec_type === "video" && !s.disposition?.attached_pic);
  if (!video) return null;
  const audio = streams.find((s) => s.codec_type === "audio") ?? null;
  const width = Number(video.width) || 0;
  const height = Number(video.height) || 0;
  const sideways = Math.abs(rotationOf(video)) % 180 === 90;
  const durationSeconds = num(probe.format?.duration) ?? num(video.duration) ?? 0;
  const bitsPerSecond = num(probe.format?.bit_rate) ?? (durationSeconds > 0 ? (fileBytes * 8) / durationSeconds : 0);
  return {
    codec: video.codec_name ?? null,
    width: sideways ? height : width,
    height: sideways ? width : height,
    frameRate: frameRate(video.avg_frame_rate) || frameRate(video.r_frame_rate),
    bitDepth: bitDepthOf(video),
    transfer: video.color_transfer ?? null,
    isHDR: HDR_TRANSFERS.has(video.color_transfer),
    videoBitsPerSecond: num(video.bit_rate) ?? bitsPerSecond,
    bitsPerSecond,
    durationSeconds,
    container: probe.format?.format_name ?? "",
    audioCodec: audio?.codec_name ?? null,
    audioChannels: Number(audio?.channels) || 0,
    fileBytes,
  };
}

/** Whether the index (`moov`) comes before the media (`mdat`), so a player can start before the whole file has arrived. */
export async function isFastStart(file) {
  let handle;
  try {
    handle = await open(file, "r");
    const header = Buffer.alloc(16);
    let offset = 0n;
    for (let i = 0; i < 64; i++) {
      const { bytesRead } = await handle.read(header, 0, 16, offset);
      if (bytesRead < 8) return false;
      let size = BigInt(header.readUInt32BE(0));
      const type = header.toString("latin1", 4, 8);
      if (type === "moov") return true;
      if (type === "mdat") return false;
      if (size === 1n) {
        if (bytesRead < 16) return false;
        size = header.readBigUInt64BE(8); // the real size follows as 64 bits
      }
      if (size < 8n) return false; // 0 means "to the end of the file"
      offset += size;
    }
    return false;
  } catch {
    return false;
  } finally {
    await handle?.close();
  }
}

// ───────────────────────────── The plan ─────────────────────────────

/** The Pi plays it well as it is: HEVC (its decoder block) or H.264 (on the CPU, fine at 1080p), 8-bit SDR, at most 1920 px and 31 fps. */
export function playsOnWall(video) {
  return (
    (video.codec === "hevc" || video.codec === "h264") &&
    !video.isHDR &&
    video.bitDepth <= 8 &&
    Math.max(video.width, video.height) <= WALL_MAX_LONG_SIDE &&
    video.frameRate <= MAX_FRAME_RATE
  );
}

/**
 * asIs: the file already fits (the job only adds a missing poster).
 * remux: it fits, but its index is at the end; copy it with the index first.
 * transcode: make a new file.
 */
export function planFor(video, extension, fastStart) {
  const ready =
    playsOnWall(video) &&
    video.bitsPerSecond <= PASSTHROUGH_MAX_BITS_PER_SECOND &&
    ["mov", "mp4", "m4v"].includes(String(extension).toLowerCase());
  if (ready) return fastStart ? "asIs" : "remux";
  return "transcode";
}

/** The -vf chain: frame rate cap, size, HDR tone mapping, 8-bit 4:2:0. ffmpeg rotates the frames upright before these run. */
export function videoFilters(video, tools) {
  const filters = [];
  if (video.frameRate > MAX_FRAME_RATE) filters.push("fps=30");
  if (Math.max(video.width, video.height) > WALL_MAX_LONG_SIDE) {
    filters.push(video.width >= video.height ? `scale=${WALL_MAX_LONG_SIDE}:-2` : `scale=-2:${WALL_MAX_LONG_SIDE}`);
  } else if (video.width % 2 || video.height % 2) {
    filters.push("scale=trunc(iw/2)*2:trunc(ih/2)*2");
  }
  if (video.isHDR && tools.zscale) {
    // HLG or PQ to SDR Rec. 709, after the resize so it runs on fewer pixels.
    filters.push(
      "zscale=t=linear:npl=100",
      "format=gbrpf32le",
      "zscale=p=bt709",
      "tonemap=tonemap=hable:desat=0",
      "zscale=t=bt709:m=bt709:r=tv",
    );
  }
  filters.push("format=yuv420p");
  return filters.join(",");
}

/**
 * HEVC (what the Pi decodes in hardware), or H.264 when this ffmpeg has no
 * libx265. Quality-targeted, with a ceiling under the source's own bitrate
 * so the copy comes out smaller.
 */
export function encoderArgs(video, tools) {
  const source = video.videoBitsPerSecond > 0 ? video.videoBitsPerSecond * 0.8 : 8_000_000;
  const maxrate = Math.round(Math.min(Math.max(source, 1_500_000), 8_000_000));
  if (tools.x265) {
    const kbps = Math.round(maxrate / 1000);
    return [
      "-c:v", "libx265", "-preset", "fast", "-crf", "26", "-tag:v", "hvc1",
      "-x265-params", `log-level=error:vbv-maxrate=${kbps}:vbv-bufsize=${kbps * 2}`,
    ];
  }
  return [
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-profile:v", "high",
    "-maxrate", String(maxrate), "-bufsize", String(maxrate * 2),
  ];
}

/** AAC stereo stays as it is; anything else becomes AAC 128k stereo. */
export function audioArgs(video) {
  if (!video.audioCodec) return [];
  if (video.audioCodec === "aac" && video.audioChannels > 0 && video.audioChannels <= 2) return ["-c:a", "copy"];
  return ["-c:a", "aac", "-b:a", "128k", "-ac", "2"];
}

export function transcodeArgs(input, output, video, tools) {
  return [
    "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
    "-i", input,
    "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1", "-map_chapters", "-1",
    "-vf", videoFilters(video, tools),
    ...encoderArgs(video, tools),
    "-pix_fmt", "yuv420p",
    ...(video.isHDR ? ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"] : []),
    ...audioArgs(video),
    "-movflags", "+faststart", "-max_muxing_queue_size", "1024",
    output,
  ];
}

/** The same streams with the index first, and no metadata (location). */
export function remuxArgs(input, output, video) {
  return [
    "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
    "-i", input,
    "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1", "-map_chapters", "-1",
    "-c", "copy",
    ...(video.codec === "hevc" ? ["-tag:v", "hvc1"] : []),
    "-movflags", "+faststart",
    output,
  ];
}

/** A JPEG from the first few seconds: the most typical frame, so not a black fade-in. */
export function posterArgs(input, output, video, longSide, quality) {
  const size = video.width >= video.height ? `'min(iw,${longSide})':-2` : `-2:'min(ih,${longSide})'`;
  return [
    "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
    "-t", "4", "-i", input,
    "-vf", `thumbnail=60,scale=${size}`,
    "-frames:v", "1", "-q:v", String(quality),
    output,
  ];
}

// ───────────────────────────── Running things ─────────────────────────────

function run(command, args, { timeoutMs = FFMPEG_TIMEOUT_MS, capture = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      if (capture) stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk).slice(-4000);
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout);
      else {
        const last = stderr.trim().split("\n").slice(-3).join(" | ");
        reject(new Error(`${path.basename(command)} ${signal ? `killed (${signal})` : `exited ${code}`}: ${last}`));
      }
    });
  });
}

async function works(command) {
  try {
    await run(command, ["-hide_banner", "-version"], { timeoutMs: 30_000 });
    return true;
  } catch {
    return false;
  }
}

async function findFile(dir, name) {
  for (const entry of await readdir(dir, { withFileTypes: true, recursive: true })) {
    if (entry.isFile() && entry.name === name) return path.join(entry.parentPath ?? entry.path, entry.name);
  }
  return null;
}

async function sha256(file) {
  const hash = createHash("sha256");
  await pipeline(createReadStream(file), hash);
  return hash.digest("hex");
}

/** ffmpeg and ffprobe, from PATH or downloaded, with what they can do. */
export async function ensureFfmpeg(workDir, env = process.env) {
  let tools = { ffmpeg: "ffmpeg", ffprobe: "ffprobe", source: "PATH" };
  if (!(await works("ffmpeg")) || !(await works("ffprobe"))) {
    const url = env.MEDIA_FFMPEG_URL || DEFAULT_FFMPEG_URL;
    const archive = path.join(workDir, "ffmpeg.tar.xz");
    const dir = path.join(workDir, "ffmpeg");
    const started = Date.now();
    await download(url, archive);
    const want = env.MEDIA_FFMPEG_SHA256?.trim().toLowerCase();
    if (want && (await sha256(archive)) !== want) throw new Error("ffmpeg download doesn't match MEDIA_FFMPEG_SHA256");
    await mkdir(dir, { recursive: true });
    await run("tar", ["-xJf", archive, "-C", dir], { timeoutMs: 5 * 60 * 1000 });
    await rm(archive, { force: true });
    const ffmpeg = await findFile(dir, "ffmpeg");
    const ffprobe = await findFile(dir, "ffprobe");
    if (!ffmpeg || !ffprobe) throw new Error(`no ffmpeg and ffprobe in ${url}`);
    tools = { ffmpeg, ffprobe, source: url };
    log(`ffmpeg installed from ${url} in ${seconds(started)}`);
  }
  const [encoders, filters] = await Promise.all([
    run(tools.ffmpeg, ["-hide_banner", "-encoders"], { capture: true, timeoutMs: 30_000 }),
    run(tools.ffmpeg, ["-hide_banner", "-filters"], { capture: true, timeoutMs: 30_000 }),
  ]);
  tools.x265 = /\slibx265\s/.test(encoders);
  tools.x264 = /\slibx264\s/.test(encoders);
  tools.zscale = /\szscale\s/.test(filters);
  if (!tools.x265 && !tools.x264) throw new Error("this ffmpeg has neither libx265 nor libx264");
  return tools;
}

async function probe(tools, file) {
  const out = await run(tools.ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file], {
    capture: true,
    timeoutMs: 5 * 60 * 1000,
  });
  return parseProbe(JSON.parse(out), (await stat(file)).size);
}

async function retrying(what, attempt) {
  let last;
  for (let i = 0; i < 3; i++) {
    try {
      return await attempt();
    } catch (err) {
      last = err;
      if (err instanceof FinalError) throw err;
      log(`${what} failed (${err.message}), ${i < 2 ? "trying again" : "giving up"}`);
      await new Promise((r) => setTimeout(r, 2000 * (i + 1)));
    }
  }
  throw last;
}

async function download(url, file) {
  await retrying("download", async () => {
    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok || !response.body) {
      const error = new Error(`download answered ${response.status}`);
      throw response.status >= 400 && response.status < 500 && response.status !== 429 ? new FinalError(error.message) : error;
    }
    await pipeline(Readable.fromWeb(response.body), createWriteStream(file));
  });
}

async function upload(url, file, contentType) {
  await retrying("upload", async () => {
    const body = await openAsBlob(file, { type: contentType });
    const response = await fetch(url, { method: "PUT", headers: { "content-type": contentType }, body });
    if (!response.ok) {
      const text = (await response.text().catch(() => "")).slice(0, 200);
      throw new Error(`upload answered ${response.status} ${text}`.trim());
    }
  });
}

async function postJson(url, body) {
  await retrying("callback", async () => {
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (response.status >= 500 || response.status === 429) throw new Error(`callback answered ${response.status}`);
    if (!response.ok) log(`callback refused: ${response.status} ${(await response.text().catch(() => "")).slice(0, 200)}`);
  });
}

function log(message) {
  console.log(`[worker] ${message}`);
}

const seconds = (since) => `${((Date.now() - since) / 1000).toFixed(1)} s`;
const megabytes = (bytes) => `${(bytes / 1_000_000).toFixed(1)} MB`;

// ───────────────────────────── The job ─────────────────────────────

async function makePoster(tools, input, video, workDir) {
  const file = path.join(workDir, "poster.jpg");
  for (const side of [960, 640]) {
    for (const quality of [4, 7, 10]) {
      try {
        await run(tools.ffmpeg, posterArgs(input, file, video, side, quality), { timeoutMs: 5 * 60 * 1000 });
        const { size } = await stat(file);
        if (size > 0 && size <= POSTER_MAX_BYTES) return file;
      } catch (err) {
        log(`poster: ${err.message}`);
        return null;
      }
    }
  }
  return null;
}

/**
 * Makes the wall copy of `source`. Returns the file to upload (or null when
 * the source already fits), the plan that was followed, and what the result
 * holds.
 */
export async function prepare(tools, source, extension, workDir) {
  const video = await probe(tools, source);
  if (!video) throw new FinalError("the file has no video stream");
  const plan = planFor(video, extension, await isFastStart(source));
  const output = path.join(workDir, "wall.mp4");
  const remux = async () => {
    await run(tools.ffmpeg, remuxArgs(source, output, video));
    return { output, plan: "remux", video: await probe(tools, output), source: video };
  };
  if (plan === "asIs") return { output: null, plan, video, source: video };
  if (plan === "remux") {
    try {
      return await remux();
    } catch (err) {
      log(`remux failed (${err.message}), transcoding instead`);
    }
  }
  const started = Date.now();
  await run(tools.ffmpeg, transcodeArgs(source, output, video, tools));
  const made = await probe(tools, output);
  log(`transcoded ${megabytes(video.fileBytes)} to ${megabytes(made.fileBytes)} in ${seconds(started)}`);
  // A small, low-bitrate clip can come out bigger. Then keep the source.
  if (playsOnWall(video) && made.fileBytes >= 0.9 * video.fileBytes) {
    await rm(output, { force: true });
    if (await isFastStart(source)) return { output: null, plan: "asIs", video, source: video };
    return await remux();
  }
  return { output, plan: "transcode", video: made, source: video };
}

export async function runJob(job, workDir) {
  const started = Date.now();
  // The token covers these four, so the admin app knows which job and sandbox this is.
  const report = (result) =>
    postJson(job.callback_url, {
      media_id: job.media_id,
      family_id: job.family_id,
      attempt: job.attempt,
      sandbox: job.sandbox,
      token: job.token,
      ...result,
    });
  try {
    const tools = await ensureFfmpeg(workDir);
    const extension = String(job.source_ext || "mov").toLowerCase();
    const source = path.join(workDir, `source.${extension}`);
    let step = Date.now();
    await download(job.source_url, source);
    log(`downloaded ${megabytes((await stat(source)).size)} in ${seconds(step)}`);

    const result = await prepare(tools, source, extension, workDir);
    log(`plan: ${result.plan}`);
    if (result.output && result.video.fileBytes > job.max_bytes) {
      throw new FinalError("the copy came out bigger than the original");
    }

    let poster = false;
    if (job.poster_url) {
      const file = await makePoster(tools, result.output ?? source, result.video, workDir);
      if (file) {
        try {
          await upload(job.poster_url, file, "image/jpeg");
          poster = true;
        } catch (err) {
          log(`poster upload: ${err.message}`); // a poster never fails the job
        }
      }
    }
    if (result.output) {
      step = Date.now();
      await upload(job.output_url, result.output, "video/mp4");
      log(`uploaded ${megabytes(result.video.fileBytes)} in ${seconds(step)}`);
    }
    await report({
      status: result.output ? "copy" : "fits",
      plan: result.plan,
      width: result.video.width || null,
      height: result.video.height || null,
      poster,
      seconds: Math.round((Date.now() - started) / 1000),
    });
    log(`done in ${seconds(started)}`);
  } catch (err) {
    log(`failed: ${err.message}`);
    await report({
      status: "failed",
      retry: !(err instanceof FinalError),
      error: String(err.message || err).slice(0, 400),
    }).catch((e) => log(`couldn't report the failure: ${e.message}`));
    process.exitCode = 1;
  }
}

/** Installs or finds ffmpeg, makes a 4 s 4K60 10-bit HLG clip, and checks the copy is what the wall wants. Prints one JSON line. */
export async function selfTest(workDir) {
  const started = Date.now();
  const tools = await ensureFfmpeg(workDir);
  const source = path.join(workDir, "self-test.mov");
  await run(tools.ffmpeg, [
    "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
    "-f", "lavfi", "-i", "testsrc2=s=3840x2160:r=60:d=4,format=yuv420p10le",
    "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
    ...(tools.x265
      ? ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1",
         "-x265-params", "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"]
      : ["-c:v", "libx264", "-preset", "ultrafast"]),
    "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc",
    "-c:a", "pcm_s16le", "-shortest",
    source,
  ]);
  const step = Date.now();
  const result = await prepare(tools, source, "mov", workDir);
  const out = result.video;
  const ok =
    result.plan === "transcode" &&
    out.codec === (tools.x265 ? "hevc" : "h264") &&
    Math.max(out.width, out.height) === WALL_MAX_LONG_SIDE &&
    out.frameRate <= MAX_FRAME_RATE &&
    out.bitDepth === 8 &&
    !out.isHDR &&
    out.audioCodec === "aac" &&
    (await isFastStart(result.output));
  const report = {
    ok,
    ffmpeg: tools.source,
    x265: tools.x265,
    zscale: tools.zscale,
    plan: result.plan,
    output: { codec: out.codec, width: out.width, height: out.height, fps: out.frameRate, bitDepth: out.bitDepth, transfer: out.transfer },
    transcodeSeconds: Math.round((Date.now() - step) / 100) / 10,
    totalSeconds: Math.round((Date.now() - started) / 100) / 10,
  };
  console.log(JSON.stringify(report));
  if (!ok) process.exitCode = 1;
  return report;
}

async function main(args) {
  if (args[0] === "--self-test") {
    await selfTest(process.cwd());
    return;
  }
  if (!args[0]) {
    console.error("usage: node worker.mjs job.json | --self-test");
    process.exitCode = 2;
    return;
  }
  const job = JSON.parse(await readFile(args[0], "utf8"));
  await runJob(job, path.dirname(path.resolve(args[0])));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}
