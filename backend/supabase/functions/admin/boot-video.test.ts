// Unit tests for the boot-video checks: `deno test admin/boot-video.test.ts`.

import { assertEquals } from "jsr:@std/assert@1";
import { assessBootVideo, BOOT_MAX_BYTES, isPendingBootPath, newPendingBootPath } from "./boot-video.ts";

function u32(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n);
  return b;
}

function u16(n: number): Uint8Array {
  const b = new Uint8Array(2);
  new DataView(b.buffer).setUint16(0, n);
  return b;
}

const ascii = (s: string) => new TextEncoder().encode(s);

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function box(type: string, payload: Uint8Array): Uint8Array {
  return concat(u32(8 + payload.length), ascii(type), payload);
}

function mvhd(timescale: number, duration: number): Uint8Array {
  return box("mvhd", concat(
    u32(0),
    u32(0),
    u32(0),
    u32(timescale),
    u32(duration),
    u32(0x00010000),
    u16(0x0100),
    u16(0),
    u32(0),
    u32(0),
    u32(0x00010000), u32(0), u32(0),
    u32(0), u32(0x00010000), u32(0),
    u32(0), u32(0), u32(0x40000000),
    u32(0), u32(0), u32(0), u32(0), u32(0), u32(0),
    u32(2),
  ));
}

function hdlr(kind: string): Uint8Array {
  return box("hdlr", concat(u32(0), u32(0), ascii(kind), u32(0), u32(0), u32(0), new Uint8Array([0])));
}

function clip(seconds: number, audio = false): Uint8Array {
  const trak = box("trak", box("mdia", hdlr("vide")));
  const parts = [mvhd(1000, Math.round(seconds * 1000)), trak];
  if (audio) parts.push(box("trak", box("mdia", hdlr("soun"))));
  return concat(box("ftyp", concat(ascii("isom"), u32(0x200), ascii("isom"), ascii("mp41"))), box("moov", concat(...parts)));
}

Deno.test("a short silent mp4 is accepted", () => {
  assertEquals(assessBootVideo(clip(6)), { durationMs: 6000 });
  assertEquals(assessBootVideo(clip(0.5)), { durationMs: 500 });
  assertEquals(assessBootVideo(clip(12)), { durationMs: 12000 });
});

Deno.test("other files, sound, and the wrong length are rejected", () => {
  assertEquals(assessBootVideo(ascii("hello world!!")), { error: "that file isn't an mp4" });
  assertEquals(assessBootVideo(clip(6, true)), { error: "boot video must be silent" });
  assertEquals(assessBootVideo(clip(0.2)), { error: "boot video must be between 0.5 and 12 seconds" });
  assertEquals(assessBootVideo(clip(13)), { error: "boot video must be between 0.5 and 12 seconds" });
  const ftyp = box("ftyp", concat(ascii("isom"), u32(0x200)));
  const audioOnly = concat(ftyp, box("moov", concat(mvhd(1000, 6000), box("trak", box("mdia", hdlr("soun"))))));
  assertEquals(assessBootVideo(audioOnly), { error: "boot video needs a video track" });
  const noTrack = concat(ftyp, box("moov", mvhd(1000, 6000)));
  assertEquals(assessBootVideo(noTrack), { error: "boot video needs a video track" });
});

Deno.test("a file over 20 MB is rejected before it is parsed", () => {
  const big = new Uint8Array(BOOT_MAX_BYTES + 1);
  big.set(ascii("xxxxftyp"), 0);
  assertEquals(assessBootVideo(big), { error: "boot video must be 20 MB or smaller" });
});

Deno.test("pending paths are one uuid mp4", () => {
  const path = newPendingBootPath();
  assertEquals(isPendingBootPath(path), true);
  assertEquals(isPendingBootPath("current.mp4"), false);
  assertEquals(isPendingBootPath("pending/../current.mp4"), false);
  assertEquals(isPendingBootPath("pending/not-a-uuid.mp4"), false);
});
