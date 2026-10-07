// The sandbox worker (lib/media/worker.mjs): the plan, the ffmpeg arguments,
// and one whole job against a local stand-in for Blob and the callback.
// The job test needs ffmpeg with libx265 on PATH and is skipped without it.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  POSTER_MAX_BYTES,
  audioArgs,
  encoderArgs,
  frameRate,
  isFastStart,
  parseProbe,
  planFor,
  playsOnWall,
  transcodeArgs,
  videoFilters,
} from "../lib/media/worker.mjs";

const WORKER = fileURLToPath(new URL("../lib/media/worker.mjs", import.meta.url));

// What ffprobe says about an iPhone 4K60 HDR portrait clip.
const IPHONE_HDR = {
  streams: [
    {
      codec_type: "video",
      codec_name: "hevc",
      width: 3840,
      height: 2160,
      pix_fmt: "yuv420p10le",
      color_transfer: "arib-std-b67",
      avg_frame_rate: "60/1",
      r_frame_rate: "60/1",
      bit_rate: "48000000",
      side_data_list: [{ side_data_type: "Display Matrix", rotation: -90 }],
    },
    { codec_type: "audio", codec_name: "aac", channels: 2 },
  ],
  format: { format_name: "mov,mp4,m4a,3gp,3g2,mj2", duration: "10.0", bit_rate: "49000000" },
};

const video = (overrides = {}) => ({
  codec: "hevc",
  width: 1920,
  height: 1080,
  frameRate: 30,
  bitDepth: 8,
  transfer: "bt709",
  isHDR: false,
  videoBitsPerSecond: 9_000_000,
  bitsPerSecond: 9_200_000,
  durationSeconds: 10,
  container: "mov,mp4,m4a,3gp,3g2,mj2",
  audioCodec: "aac",
  audioChannels: 2,
  fileBytes: 11_500_000,
  ...overrides,
});

const tools = { ffmpeg: "ffmpeg", ffprobe: "ffprobe", x265: true, x264: true, zscale: true };

test("frame rates read like ffprobe writes them", () => {
  assert.equal(frameRate("30/1"), 30);
  assert.ok(Math.abs(frameRate("30000/1001") - 29.97) < 0.01);
  assert.equal(frameRate("0/0"), 0);
  assert.equal(frameRate(undefined), 0);
});

test("parseProbe: an iPhone HDR clip, turned upright", () => {
  const v = parseProbe(IPHONE_HDR, 61_250_000);
  assert.equal(v.codec, "hevc");
  assert.equal(v.width, 2160, "rotated 90°, so it shows portrait");
  assert.equal(v.height, 3840);
  assert.equal(v.frameRate, 60);
  assert.equal(v.bitDepth, 10);
  assert.equal(v.isHDR, true);
  assert.equal(v.videoBitsPerSecond, 48_000_000);
  assert.equal(v.audioCodec, "aac");
  assert.equal(parseProbe({ streams: [{ codec_type: "audio" }], format: {} }), null, "no video stream");
});

test("parseProbe: the bitrate falls back to size over duration", () => {
  const v = parseProbe({ streams: [{ codec_type: "video", codec_name: "h264", width: 640, height: 480 }], format: { duration: "8" } }, 8_000_000);
  assert.equal(v.bitsPerSecond, 8_000_000);
  assert.equal(v.bitDepth, 8);
  assert.equal(v.isHDR, false);
});

test("the plan matches the iPhone's", () => {
  assert.equal(planFor(video(), "mov", true), "asIs", "1080p30 SDR HEVC at 9 Mb/s plays as it is");
  assert.equal(planFor(video(), "mov", false), "remux", "only the index moves");
  assert.equal(planFor(video({ codec: "h264" }), "mp4", true), "asIs", "H.264 1080p is fine on the Pi's CPU");
  assert.equal(planFor(video({ width: 3840, height: 2160 }), "mov", true), "transcode", "4K is shrunk");
  assert.equal(planFor(video({ isHDR: true }), "mov", true), "transcode", "HDR becomes SDR");
  assert.equal(planFor(video({ bitDepth: 10 }), "mov", true), "transcode", "10-bit becomes 8-bit");
  assert.equal(planFor(video({ frameRate: 60 }), "mov", true), "transcode", "60 fps is capped");
  assert.equal(planFor(video({ frameRate: 29.97 }), "mov", true), "asIs", "29.97 fits");
  assert.equal(planFor(video({ bitsPerSecond: 25_000_000 }), "mov", true), "transcode", "a heavy 1080p is shrunk");
  assert.equal(planFor(video({ codec: "vp9" }), "webm", true), "transcode", "VP9 is re-encoded");
  assert.equal(planFor(video(), "mkv", true), "transcode", "only mov/mp4/m4v pass through");
  assert.equal(playsOnWall(video({ width: 1200, height: 1920 })), true, "portrait 1920 fits");
});

test("filters: cap, size, tone map, 8-bit", () => {
  const hdr = videoFilters(video({ width: 3840, height: 2160, isHDR: true, frameRate: 60 }), tools);
  assert.equal(
    hdr,
    "fps=30,scale=1920:-2,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p",
  );
  assert.equal(videoFilters(video({ width: 2160, height: 3840 }), tools), "scale=-2:1920,format=yuv420p", "portrait keeps its height");
  assert.equal(videoFilters(video({ width: 1081, height: 721 }), tools), "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p", "odd sizes become even");
  assert.equal(videoFilters(video({ codec: "vp9" }), tools), "format=yuv420p");
  assert.equal(
    videoFilters(video({ isHDR: true }), { ...tools, zscale: false }),
    "format=yuv420p",
    "without zscale the colors are off but it still plays",
  );
});

test("encoder: HEVC tagged for Apple, with a ceiling under the source", () => {
  const hevc = encoderArgs(video({ videoBitsPerSecond: 48_000_000 }), tools);
  assert.deepEqual(hevc.slice(0, 8), ["-c:v", "libx265", "-preset", "fast", "-crf", "26", "-tag:v", "hvc1"]);
  assert.match(hevc[9], /vbv-maxrate=8000:vbv-bufsize=16000/, "at most 8 Mb/s");
  assert.match(encoderArgs(video({ videoBitsPerSecond: 4_000_000 }), tools)[9], /vbv-maxrate=3200:/, "80% of a light source");
  assert.match(encoderArgs(video({ videoBitsPerSecond: 0 }), tools)[9], /vbv-maxrate=8000:/, "unknown bitrate");
  const h264 = encoderArgs(video(), { ...tools, x265: false });
  assert.equal(h264[1], "libx264");
});

test("audio: AAC stereo is copied, the rest becomes AAC stereo", () => {
  assert.deepEqual(audioArgs(video()), ["-c:a", "copy"]);
  assert.deepEqual(audioArgs(video({ audioChannels: 6 })), ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]);
  assert.deepEqual(audioArgs(video({ audioCodec: "pcm_s16le" })), ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]);
  assert.deepEqual(audioArgs(video({ audioCodec: null })), []);
});

test("transcode arguments drop metadata, tag HDR copies as BT.709 and put the index first", () => {
  const args = transcodeArgs("in.mov", "out.mp4", video({ isHDR: true, width: 3840, height: 2160 }), tools);
  for (const flag of ["-map_metadata", "-movflags", "-color_trc"]) assert.ok(args.includes(flag), flag);
  assert.equal(args[args.indexOf("-map_metadata") + 1], "-1");
  assert.equal(args[args.indexOf("-movflags") + 1], "+faststart");
  assert.equal(args[args.indexOf("-color_trc") + 1], "bt709");
  assert.equal(args.at(-1), "out.mp4");
  assert.ok(!transcodeArgs("in.mov", "out.mp4", video(), tools).includes("-color_trc"), "SDR keeps its own tags");
});

function box(type, size) {
  const b = Buffer.alloc(size);
  b.writeUInt32BE(size, 0);
  b.write(type, 4, "latin1");
  return b;
}

test("isFastStart reads the top-level boxes", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "worker-boxes-"));
  try {
    const first = path.join(dir, "first.mp4");
    const last = path.join(dir, "last.mov");
    await writeFile(first, Buffer.concat([box("ftyp", 24), box("moov", 64), box("mdat", 128)]));
    await writeFile(last, Buffer.concat([box("ftyp", 24), box("wide", 8), box("mdat", 128), box("moov", 64)]));
    assert.equal(await isFastStart(first), true);
    assert.equal(await isFastStart(last), false);
    assert.equal(await isFastStart(path.join(dir, "missing.mp4")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

function hasFfmpeg() {
  try {
    return /\slibx265\s/.test(execFileSync("ffmpeg", ["-hide_banner", "-encoders"], { encoding: "utf8" }));
  } catch {
    return false;
  }
}

function ffprobe(file) {
  return JSON.parse(
    execFileSync("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file], { encoding: "utf8" }),
  );
}

// Serves `source` at /source, keeps PUTs to /wall and /poster, records the
// callback, runs the worker on one job and hands back what it received.
async function runJob(dir, source, { poster = true } = {}) {
  const sourceBytes = (await stat(source)).size;
  const received = { puts: {}, callbacks: [], exit: null, sourceBytes };
  const server = createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/source") {
      res.writeHead(200, { "content-type": "video/quicktime", "content-length": sourceBytes });
      return createReadStream(source).pipe(res);
    }
    if (req.method === "PUT" && (req.url === "/wall" || req.url === "/poster")) {
      const file = path.join(dir, req.url === "/wall" ? "got-wall.mp4" : "got-poster.jpg");
      await pipeline(req, createWriteStream(file));
      received.puts[req.url] = { file, type: req.headers["content-type"] };
      res.writeHead(200, { "content-type": "application/json" });
      return res.end("{}");
    }
    if (req.method === "POST" && req.url === "/done") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      received.callbacks.push(JSON.parse(raw));
      res.writeHead(200, { "content-type": "application/json" });
      return res.end("{}");
    }
    res.writeHead(404).end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const jobDir = await mkdtemp(path.join(dir, "job-"));
    const jobFile = path.join(jobDir, "job.json");
    await writeFile(jobFile, JSON.stringify({
      media_id: "11111111-1111-4111-8111-111111111111",
      attempt: 1,
      token: "t0ken",
      source_url: `${origin}/source`,
      source_ext: path.extname(source).slice(1),
      output_url: `${origin}/wall`,
      poster_url: poster ? `${origin}/poster` : null,
      callback_url: `${origin}/done`,
      max_bytes: sourceBytes + 1048576,
    }));
    received.exit = await new Promise((resolve) => {
      const child = spawn(process.execPath, [WORKER, jobFile], { stdio: "inherit" });
      child.on("close", resolve);
    });
  } finally {
    server.close();
  }
  return received;
}

function makeClip(file, input, encoder, extra = []) {
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", input,
    "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
    ...encoder, "-c:a", "aac", "-shortest", ...extra,
    file,
  ]);
}

const noFfmpeg = !hasFfmpeg() && "ffmpeg with libx265 isn't installed";

test("a whole job: a 4K60 HDR clip in, a wall copy and a poster out", { skip: noFfmpeg }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "worker-job-"));
  try {
    const source = path.join(dir, "upload.mov");
    makeClip(source, "testsrc2=s=3840x2160:r=60:d=3,format=yuv420p10le", [
      "-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1",
      "-x265-params", "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
      "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc",
    ]);
    const received = await runJob(dir, source);
    assert.equal(received.exit, 0);

    assert.equal(received.callbacks.length, 1);
    const report = received.callbacks[0];
    assert.equal(report.status, "copy");
    assert.equal(report.plan, "transcode");
    assert.equal(report.token, "t0ken");
    assert.equal(report.attempt, 1);
    assert.equal(report.poster, true);
    assert.equal(report.width, 1920);
    assert.equal(report.height, 1080);

    assert.equal(received.puts["/wall"].type, "video/mp4");
    const wall = received.puts["/wall"].file;
    const probed = ffprobe(wall);
    const v = probed.streams.find((s) => s.codec_type === "video");
    assert.equal(v.codec_name, "hevc");
    assert.equal(v.codec_tag_string, "hvc1", "tagged so iOS plays it too");
    assert.equal(`${v.width}x${v.height}`, "1920x1080");
    assert.equal(v.pix_fmt, "yuv420p");
    assert.equal(v.color_transfer, "bt709");
    assert.ok(frameRate(v.avg_frame_rate) <= 30);
    assert.equal(probed.streams.find((s) => s.codec_type === "audio")?.codec_name, "aac");
    assert.equal(await isFastStart(wall), true, "index first");
    assert.ok((await stat(wall)).size < received.sourceBytes, "smaller than the upload");

    assert.equal(received.puts["/poster"].type, "image/jpeg");
    const poster = await readFile(received.puts["/poster"].file);
    assert.ok(poster.length > 0 && poster.length <= POSTER_MAX_BYTES);
    assert.equal(poster.subarray(0, 2).toString("hex"), "ffd8", "a JPEG");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a clip that already fits stays as it is; one with its index last is only remuxed", { skip: noFfmpeg }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "worker-fits-"));
  try {
    const hevc1080 = ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p"];
    const ready = path.join(dir, "ready.mp4");
    makeClip(ready, "testsrc2=s=1920x1080:r=30:d=3", hevc1080, ["-movflags", "+faststart"]);
    const fits = await runJob(dir, ready, { poster: false });
    assert.equal(fits.exit, 0);
    assert.equal(fits.callbacks[0].status, "fits");
    assert.equal(fits.callbacks[0].plan, "asIs");
    assert.equal(fits.callbacks[0].poster, false);
    assert.equal(fits.puts["/wall"], undefined, "nothing uploaded");

    const indexLast = path.join(dir, "index-last.mov");
    makeClip(indexLast, "testsrc2=s=1920x1080:r=30:d=3", hevc1080);
    assert.equal(await isFastStart(indexLast), false);
    const remuxed = await runJob(dir, indexLast);
    assert.equal(remuxed.exit, 0);
    assert.equal(remuxed.callbacks[0].status, "copy");
    assert.equal(remuxed.callbacks[0].plan, "remux");
    assert.equal(remuxed.callbacks[0].poster, true, "a row without a poster gets one");
    const copy = remuxed.puts["/wall"].file;
    assert.equal(await isFastStart(copy), true);
    assert.ok(Math.abs((await stat(copy)).size - remuxed.sourceBytes) < 1048576, "the same streams, within the 1 MiB slack");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a job that can't download reports a failure", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "worker-fail-"));
  const callbacks = [];
  const server = createServer(async (req, res) => {
    if (req.url === "/done") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      callbacks.push(JSON.parse(raw));
      res.writeHead(200).end("{}");
      return;
    }
    res.writeHead(404).end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const jobFile = path.join(dir, "job.json");
    await writeFile(jobFile, JSON.stringify({
      media_id: "11111111-1111-4111-8111-111111111111",
      attempt: 2,
      token: "t0ken",
      source_url: `${origin}/gone`,
      source_ext: "mov",
      output_url: `${origin}/wall`,
      poster_url: null,
      callback_url: `${origin}/done`,
      max_bytes: 1000,
    }));
    // Pretend ffmpeg is installed, so the test doesn't need it or the network.
    const bin = path.join(dir, "bin");
    await mkdir(bin);
    for (const name of ["ffmpeg", "ffprobe"]) {
      await writeFile(path.join(bin, name), "#!/bin/sh\necho ' V..... libx265 stub'\n", { mode: 0o755 });
    }
    const exit = await new Promise((resolve) => {
      const child = spawn(process.execPath, [WORKER, jobFile], {
        stdio: "ignore",
        env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` },
      });
      child.on("close", resolve);
    });
    assert.equal(exit, 1);
    assert.equal(callbacks.length, 1);
    assert.equal(callbacks[0].status, "failed");
    assert.equal(callbacks[0].attempt, 2);
    assert.equal(callbacks[0].retry, false, "a 404 won't get better by trying again");
    assert.match(callbacks[0].error, /404/);
  } finally {
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});
