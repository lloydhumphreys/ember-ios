// Pictures the seed draws itself, as PNGs, so it needs no image library: awkward shapes and sizes for
// the app's image views, and plain avatars for the people files/ has no picture of. Each is drawn by a
// function of its pixel's place, so its preview is the same picture drawn smaller.
import { deflateSync } from "node:zlib";

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(bytes) {
  let c = 0xffffffff;
  for (const byte of bytes) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "latin1");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/** A width × height RGBA PNG whose pixel at (x, y), as fractions of the picture, is `paint(u, v, x, y)` → [r, g, b, a]. */
export function png(width, height, paint) {
  const row = width * 4 + 1;
  const raw = Buffer.alloc(row * height);
  for (let y = 0; y < height; y++) {
    raw[y * row] = 0;
    for (let x = 0; x < width; x++) {
      const [r, g, b, a = 255] = paint(x / width, y / height, x, y);
      const at = y * row + 1 + x * 4;
      raw[at] = r;
      raw[at + 1] = g;
      raw[at + 2] = b;
      raw[at + 3] = a;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(raw, { level: 6 })), chunk("IEND", Buffer.alloc(0))]);
}

/** The size within 1200×800 that a browser would make a preview of a picture this size. */
export function previewSize(width, height) {
  const scale = Math.min(1, 1200 / width, 800 / height);
  return [Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale))];
}

const mix = (a, b, t) => Math.round(a + (b - a) * t);
const blend = (from, to, t) => [mix(from[0], to[0], t), mix(from[1], to[1], t), mix(from[2], to[2], t)];

/** A small seeded random number source, so the same picture is drawn on every run. */
export function random(seed) {
  let s = seed >>> 0 || 1;
  return () => ((s = (Math.imul(s ^ (s >>> 15), 0x2c1b3c6d) + 0x9e3779b9) >>> 0) / 2 ** 32);
}

/** The pictures the seed shares, each with a paint function, so it and its preview can be drawn. */
export const PICTURES = {
  // Taller than any screen: a 1:10 strip of sky over a fern-green ground, banded so scrolling shows.
  "very-tall-6000.png": { width: 600, height: 6000, paint: (u, v) => (Math.floor(v * 40) % 2 ? blend([40, 90, 160], [20, 120, 80], v) : blend([90, 150, 220], [60, 170, 110], v)) },
  // Wider than any screen: a 20:1 panorama.
  "very-wide-panorama.png": { width: 6000, height: 300, paint: (u, v) => blend([250, 180, 90], [120, 60, 160], u).map((c) => (Math.floor(u * 60) % 2 ? c : c - 25)) },
  // A picture of 8×8 pixels, which the app shouldn't blow up blurry or crash on.
  "tiny-8x8.png": { width: 8, height: 8, paint: (u, v, x, y) => ((x + y) % 2 ? [230, 80, 60] : [255, 255, 255]) },
  // One pixel.
  "one-pixel.png": { width: 1, height: 1, paint: () => [0, 160, 120] },
  // Twelve megapixels of gentle gradient: few bytes, many pixels to decode.
  "large-4000x3000.png": { width: 4000, height: 3000, paint: (u, v) => blend(blend([30, 60, 90], [200, 120, 40], u), [240, 240, 220], v * 0.6) },
  // Noise doesn't compress: about 4 MB of bytes for a 1200×900 picture.
  "heavy-noise-1200x900.png": (() => {
    const next = random(42);
    return { width: 1200, height: 900, paint: () => [Math.floor(next() * 256), Math.floor(next() * 256), Math.floor(next() * 256)] };
  })(),
  // Half see-through, to show what's behind a picture.
  "transparent-circle.png": {
    width: 512,
    height: 512,
    paint: (u, v) => {
      const d = Math.hypot(u - 0.5, v - 0.5);
      return d < 0.42 ? [255, 120, 40, Math.round(255 * (1 - d / 0.42))] : [0, 0, 0, 0];
    },
  },
};

/** A picture from PICTURES, as a file, with the preview a browser would make of it. */
export function drawPicture(name) {
  const { width, height, paint } = PICTURES[name];
  const bytes = png(width, height, paint);
  const [pw, ph] = previewSize(width, height);
  const preview = pw === width && ph === height ? bytes : png(pw, ph, (u, v) => paint(u, v, Math.floor(u * width), Math.floor(v * height)));
  return { file: { name, type: "image/png", bytes }, preview: { name: name.replace(/\.png$/, "-preview.png"), type: "image/png", bytes: preview } };
}

/** A plain 256×256 avatar in two colours that `seed` picks: a disc on a ground, as initials would sit on. */
export function avatar(seed, name) {
  const next = random(seed);
  const ground = [Math.floor(next() * 156) + 100, Math.floor(next() * 156) + 100, Math.floor(next() * 156) + 100];
  const disc = [Math.floor(next() * 120), Math.floor(next() * 120), Math.floor(next() * 120)];
  const [cx, cy, r] = [0.3 + next() * 0.4, 0.3 + next() * 0.4, 0.18 + next() * 0.15];
  return { name, type: "image/png", bytes: png(256, 256, (u, v) => (Math.hypot(u - cx, v - cy) < r ? disc : ground)) };
}
