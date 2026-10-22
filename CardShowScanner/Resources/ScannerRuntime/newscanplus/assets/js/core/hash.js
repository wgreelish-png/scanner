/*
 * hash.js - bh1 (block pHash, primary) and ph1 (region pHash set) exactly per NEWSCANPLUS.md.
 *
 * Exports
 *   bh1(rgb) -> string   324 lowercase hex (36 x 9 chars: gray[0..11], a[0..11], b[0..11])
 *   ph1(rgb) -> string   96 lowercase hex (6 x 16 chars: full, art, top, bottom, dhash, ahash)
 *   hashCard(rgb) -> {bh, ph, glare}
 *   bh1Blocks(hex) -> Array<[hi,lo]>    36 blocks as (4-bit hi, 32-bit lo) pairs
 *   bh1Distance(hexA, hexB) -> {g, a, b, d}   d = (g + 0.5a + 0.5b) / 2, 0..36
 *   ph1Distance(hexA, hexB) -> number[6]      per-region Hamming (f, a, t, b, d, ah)
 *   glareScore                re-export from quality.js
 *
 * rgb: CV_8UC3 RGB Mat, 200x280 (warp.js output). Not deleted here.
 * 36/64-bit values never pass through a JS number above 2^32: bits are packed into hi/lo uint32
 * halves and formatted per half. DCT is float64 in JS (cv.dct is not in the vendored build).
 */
import { cv } from './cv.js';
import { glareScore } from './quality.js';

export { glareScore };

const BH_W = 96, BH_H = 128, BS = 32, BK = 6;
const C6 = new Float64Array(BK * BS);
for (let k = 0; k < BK; k++) for (let s = 0; s < BS; s++) C6[k * BS + s] = Math.cos(Math.PI * k * (2 * s + 1) / 64);
const C32 = new Float64Array(8 * 32);
for (let k = 0; k < 8; k++) for (let s = 0; s < 32; s++) C32[k * 32 + s] = Math.cos(Math.PI * k * (2 * s + 1) / 64);

// wire order f, a(art), t(top), b
const REGIONS = [[0, 0, 1, 1], [0.05, 0.12, 0.90, 0.45], [0.05, 0.02, 0.90, 0.14], [0.05, 0.80, 0.90, 0.18]];
const DH_R = [0.10, 0.14, 0.80, 0.38];
const AH_R = [0.15, 0.18, 0.70, 0.30];

const T = new Float64Array(BK * BS);
const D = new Float64Array(BK * BK);
const SORT35 = new Float64Array(35);

// bits: array-like of 0/1, MSB first, length n <= 64 -> hex of ceil(n/4) chars
function packHex(bits, n) {
  const loBits = Math.min(32, n);
  const hiBits = n - loBits;
  let hi = 0, lo = 0;
  for (let i = 0; i < hiBits; i++) hi = (hi * 2 + bits[i]) >>> 0;
  for (let i = hiBits; i < n; i++) lo = (lo * 2 + bits[i]) >>> 0;
  const hiHex = hiBits ? hi.toString(16).padStart(Math.ceil(hiBits / 4), '0') : '';
  return hiHex + lo.toString(16).padStart(8, '0');
}

// one channel, 96x128 uint8 laid out with `stride` bytes per pixel and channel offset `off`
function blockHashes(data, stride, off, out) {
  const bits = new Uint8Array(36);
  for (let br = 0; br < 4; br++) {
    for (let bc = 0; bc < 3; bc++) {
      T.fill(0);
      for (let s = 0; s < BS; s++) {
        const row = ((br * BS + s) * BH_W + bc * BS) * stride + off;
        for (let k = 0; k < BK; k++) {
          const c = C6[k * BS + s];
          const tk = k * BS;
          for (let t = 0; t < BS; t++) T[tk + t] += c * data[row + t * stride];
        }
      }
      for (let k = 0; k < BK; k++) {
        for (let l = 0; l < BK; l++) {
          let v = 0;
          for (let t = 0; t < BS; t++) v += T[k * BS + t] * C6[l * BS + t];
          D[k * BK + l] = v;
        }
      }
      for (let i = 1; i < 36; i++) SORT35[i - 1] = D[i];
      SORT35.sort();
      const m = SORT35[17];
      for (let i = 0; i < 36; i++) bits[i] = D[i] > m ? 1 : 0;
      out.push(packHex(bits, 36));
    }
  }
}

export function bh1(rgb) {
  const gray = new cv.Mat();
  const lab = new cv.Mat();
  const gs = new cv.Mat();
  const ls = new cv.Mat();
  try {
    const size = new cv.Size(BH_W, BH_H);
    cv.cvtColor(rgb, gray, cv.COLOR_RGB2GRAY);
    cv.cvtColor(rgb, lab, cv.COLOR_RGB2Lab);
    cv.resize(gray, gs, size, 0, 0, cv.INTER_AREA);
    cv.resize(lab, ls, size, 0, 0, cv.INTER_AREA);
    const out = [];
    blockHashes(gs.data, 1, 0, out);
    const ld = ls.data;
    blockHashes(ld, 3, 1, out);
    blockHashes(ld, 3, 2, out);
    return out.join('');
  } finally {
    gray.delete(); lab.delete(); gs.delete(); ls.delete();
  }
}

function cropResize(rgb, r, w, h) {
  const W = rgb.cols, H = rgb.rows;
  const x = Math.floor(W * r[0]), y = Math.floor(H * r[1]);
  const rw = Math.min(Math.floor(W * r[2]), W - x), rh = Math.min(Math.floor(H * r[3]), H - y);
  const roi = rgb.roi(new cv.Rect(x, y, rw, rh));
  const small = new cv.Mat();
  try {
    cv.resize(roi, small, new cv.Size(w, h), 0, 0, cv.INTER_AREA);
    const d = small.data;
    const g = new Float64Array(w * h);
    for (let i = 0; i < w * h; i++) g[i] = 0.299 * d[i * 3] + 0.587 * d[i * 3 + 1] + 0.114 * d[i * 3 + 2];
    return g;
  } finally {
    roi.delete(); small.delete();
  }
}

function phashRegion(rgb, r) {
  const px = cropResize(rgb, r, 32, 32);
  for (let i = 0; i < px.length; i++) px[i] = Math.floor(px[i]);
  const t = new Float64Array(8 * 32);
  for (let s = 0; s < 32; s++) {
    for (let k = 0; k < 8; k++) {
      const c = C32[k * 32 + s];
      for (let x = 0; x < 32; x++) t[k * 32 + x] += c * px[s * 32 + x];
    }
  }
  const low = new Float64Array(64);
  for (let k = 0; k < 8; k++) {
    for (let l = 0; l < 8; l++) {
      let v = 0;
      for (let x = 0; x < 32; x++) v += t[k * 32 + x] * C32[l * 32 + x];
      low[k * 8 + l] = v;
    }
  }
  const sorted = low.slice(1).sort();
  const m = sorted[31];
  const bits = new Uint8Array(64);
  for (let i = 0; i < 64; i++) bits[i] = low[i] > m ? 1 : 0;
  return packHex(bits, 64);
}

function dhashRegion(rgb) {
  const g = cropResize(rgb, DH_R, 9, 8);
  const bits = new Uint8Array(64);
  for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) bits[y * 8 + x] = g[y * 9 + x] > g[y * 9 + x + 1] ? 1 : 0;
  return packHex(bits, 64);
}

function ahashRegion(rgb) {
  const g = cropResize(rgb, AH_R, 8, 8);
  let sum = 0;
  for (let i = 0; i < 64; i++) sum += g[i];
  const mean = sum / 64;
  const bits = new Uint8Array(64);
  for (let i = 0; i < 64; i++) bits[i] = g[i] > mean ? 1 : 0;
  return packHex(bits, 64);
}

export function ph1(rgb) {
  return REGIONS.map((r) => phashRegion(rgb, r)).join('') + dhashRegion(rgb) + ahashRegion(rgb);
}

export function hashCard(rgb) {
  return { bh: bh1(rgb), ph: ph1(rgb), glare: glareScore(rgb) };
}

function pop32(x) {
  x -= (x >>> 1) & 0x55555555;
  x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
  return (((x + (x >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24;
}

export function bh1Blocks(hex) {
  const out = [];
  for (let i = 0; i < 36; i++) {
    const s = hex.slice(i * 9, i * 9 + 9);
    out.push([parseInt(s.slice(0, 1), 16), parseInt(s.slice(1), 16) >>> 0]);
  }
  return out;
}

export function bh1Distance(hexA, hexB) {
  const A = bh1Blocks(hexA), B = bh1Blocks(hexB);
  const ch = [0, 0, 0];
  for (let i = 0; i < 36; i++) ch[(i / 12) | 0] += pop32(A[i][0] ^ B[i][0]) + pop32(A[i][1] ^ B[i][1]);
  const g = ch[0] / 12, a = ch[1] / 12, b = ch[2] / 12;
  return { g, a, b, d: (g + 0.5 * a + 0.5 * b) / 2 };
}

export function ph1Distance(hexA, hexB) {
  const out = [];
  for (let r = 0; r < 6; r++) {
    let n = 0;
    for (let h = 0; h < 2; h++) {
      const o = r * 16 + h * 8;
      n += pop32((parseInt(hexA.slice(o, o + 8), 16) ^ parseInt(hexB.slice(o, o + 8), 16)) >>> 0);
    }
    out.push(n);
  }
  return out;
}
