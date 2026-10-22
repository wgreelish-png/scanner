/*
 * edgefit.js - full-resolution quad refinement (port of lab methods.refine_edgefit / pipeline.edge_support).
 *
 * Exports
 *   grayImage(mat) -> {data: Uint8Array, w, h}        copy of a CV_8UC1 Mat (safe across WASM heap growth)
 *   refineEdgefit(gray, q, {search=0.02, passes=2, nSamples=48, cornerExcl=0.1, peakRel=0.5}) -> q (clockwise)
 *       Per side: 3 averaged normal profiles at nSamples points (corner zones excluded), nearest gradient
 *       peak >= peakRel * row max of the dominant polarity, Huber line fit with outlier rejection, intersect.
 *       Returns the input quad when a pass diverges (> 3x search radius); strict: null if the first pass does.
 *   edgeSupport(gray, q, {n=64, excl=0.1, step=12, rel=0.1, floor=5, taps=3}) -> 0..1
 *       fraction of perimeter samples whose inside/outside step (taps averaged along the side, dominant polarity)
 *       beats min(step, max(floor, rel * local mean)): 12 levels on bright scenes, down to 5 on dark ones
 *       (black border on a dark table). 0 when any side is under 15%. rel=0, taps=1 = the original fixed >12 test.
 *   interiorContrast(gray, q) -> gray std over a 10x14 grid inside the quad (12% margin); empty sleeves and
 *       bare table patches are flat, cards are not
 * gray: {data, w, h}. Uses cv.fitLine (DIST_HUBER) to match the lab/OpenCV fit exactly.
 */
import { cv } from './cv.js';
import { clockwise, lineIntersect } from './geom.js';

const GK = [0.05448868454964294, 0.24420134200323332, 0.40261994689424746, 0.24420134200323332, 0.05448868454964294];

export function grayImage(mat) {
  return { data: new Uint8Array(mat.data), w: mat.cols, h: mat.rows };
}

function sample(g, x, y) {
  const { data, w, h } = g;
  if (x < 0) x = 0; else if (x > w - 1) x = w - 1;
  if (y < 0) y = 0; else if (y > h - 1) y = h - 1;
  const x0 = Math.floor(x), y0 = Math.floor(y);
  const x1 = x0 + 1 < w ? x0 + 1 : x0, y1 = y0 + 1 < h ? y0 + 1 : y0;
  const fx = x - x0, fy = y - y0;
  const r0 = y0 * w, r1 = y1 * w;
  const top = data[r0 + x0] + (data[r0 + x1] - data[r0 + x0]) * fx;
  const bot = data[r1 + x0] + (data[r1 + x1] - data[r1 + x0]) * fx;
  return top + (bot - top) * fy;
}

function median(arr) {
  const s = Float64Array.from(arr).sort();
  const n = s.length;
  if (!n) return 0;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

function linspace(a, b, n) {
  const out = new Float64Array(n);
  if (n === 1) { out[0] = a; return out; }
  for (let i = 0; i < n; i++) out[i] = a + ((b - a) * i) / (n - 1);
  return out;
}

function fitLineHuber(pts) {
  const m = cv.matFromArray(pts.length, 1, cv.CV_32FC2, pts.flat());
  const line = new cv.Mat();
  try {
    cv.fitLine(m, line, cv.DIST_HUBER, 0, 0.01, 0.01);
    const f = line.data32F;
    return [[f[2], f[3]], [f[0], f[1]]];
  } finally {
    m.delete(); line.delete();
  }
}

function sideFrame(q, m, c) {
  const a = q[m], b = q[(m + 1) % 4];
  let dx = b[0] - a[0], dy = b[1] - a[1];
  const L = Math.hypot(dx, dy);
  dx /= L; dy /= L;
  let nx = -dy, ny = dx;
  if ((c[0] - a[0]) * nx + (c[1] - a[1]) * ny > 0) { nx = -nx; ny = -ny; }
  return { a, d: [dx, dy], n: [nx, ny], L };
}

function fitSide(g, q, m, c, rad, nSamples, cornerExcl, peakRel) {
  const { a, d, n, L } = sideFrame(q, m, c);
  const S = Math.trunc(Math.max(6, rad)) * 2 + 1;
  const offs = linspace(-rad, rad, S);
  const ts = linspace(cornerExcl, 1 - cornerExcl, nSamples);
  const prof = new Float64Array(nSamples * S);
  for (let i = 0; i < nSamples; i++) {
    const bx = a[0] + ts[i] * L * d[0], by = a[1] + ts[i] * L * d[1];
    for (let j = 0; j < S; j++) {
      let v = 0;
      for (let tang = -1; tang <= 1; tang++) {
        v += sample(g, bx + offs[j] * n[0] + tang * d[0], by + offs[j] * n[1] + tang * d[1]);
      }
      prof[i * S + j] = v / 3;
    }
  }
  const blur = new Float64Array(nSamples * S);
  for (let i = 0; i < nSamples; i++) {
    for (let j = 0; j < S; j++) {
      let v = 0;
      for (let t = -2; t <= 2; t++) {
        let jj = j + t;
        if (jj < 0) jj = -jj; else if (jj >= S) jj = 2 * S - 2 - jj;
        v += GK[t + 2] * prof[i * S + jj];
      }
      blur[i * S + j] = v;
    }
  }
  const grad = new Float64Array(nSamples * S);
  for (let i = 0; i < nSamples; i++) {
    const r = i * S;
    grad[r] = blur[r + 1] - blur[r];
    grad[r + S - 1] = blur[r + S - 1] - blur[r + S - 2];
    for (let j = 1; j < S - 1; j++) grad[r + j] = (blur[r + j + 1] - blur[r + j - 1]) / 2;
  }
  const peakSigns = new Float64Array(nSamples);
  for (let i = 0; i < nSamples; i++) {
    let bj = 0;
    for (let j = 1; j < S; j++) if (Math.abs(grad[i * S + j]) > Math.abs(grad[i * S + bj])) bj = j;
    peakSigns[i] = grad[i * S + bj];
  }
  let pol = Math.sign(median(peakSigns));
  if (pol === 0) pol = 1;

  const pts = [];
  const strength = new Float64Array(nSamples);
  const step = offs[1] - offs[0];
  for (let i = 0; i < nSamples; i++) {
    const r = i * S;
    let mx = -Infinity, amx = 0;
    for (let j = 0; j < S; j++) {
      const v = grad[r + j] * pol;
      if (v > mx) { mx = v; amx = j; }
    }
    let k = -1, best = Infinity;
    if (mx > 0) {
      for (let j = 1; j < S - 1; j++) {
        const v = grad[r + j] * pol;
        if (v >= grad[r + j - 1] * pol && v >= grad[r + j + 1] * pol && v >= peakRel * mx) {
          const dd = Math.abs(offs[j]);
          if (dd < best) { best = dd; k = j; }
        }
      }
    }
    if (k < 0) k = amx;
    strength[i] = grad[r + k] * pol;
    const kk = Math.min(Math.max(k, 1), S - 2);
    const y0 = grad[r + kk - 1] * pol, y1 = grad[r + kk] * pol, y2 = grad[r + kk + 1] * pol;
    const den = y0 - 2 * y1 + y2;
    const sub = Math.abs(den) > 1e-6 ? (0.5 * (y0 - y2)) / den : 0;
    const off = offs[0] + (kk + Math.max(-1, Math.min(1, sub))) * step;
    const bx = a[0] + ts[i] * L * d[0], by = a[1] + ts[i] * L * d[1];
    pts.push([bx + off * n[0], by + off * n[1]]);
  }
  const thr = Math.max(2.0, 0.25 * median(strength));
  let good = pts.filter((_, i) => strength[i] > thr);
  if (good.length < 6) return [a, d];
  let line = null;
  for (let it = 0; it < 3; it++) {
    line = fitLineHuber(good);
    const [pp, dd] = line;
    const res = good.map((p) => Math.abs((p[0] - pp[0]) * -dd[1] + (p[1] - pp[1]) * dd[0]));
    const t = Math.max(1.0, 2.5 * median(res));
    const keep = good.filter((_, i) => res[i] < t);
    if (keep.length === good.length || keep.length < 6) break;
    good = keep;
  }
  return line;
}

export function refineEdgefit(g, q0, { search = 0.02, passes = 2, nSamples = 48, cornerExcl = 0.1, peakRel = 0.5, strict = false } = {}) {
  if (!q0) return null;
  let q = q0.map((p) => [p[0], p[1]]);
  const c = [(q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4, (q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4];
  let rad = (search * (Math.hypot(q[2][0] - q[0][0], q[2][1] - q[0][1]) + Math.hypot(q[3][0] - q[1][0], q[3][1] - q[1][1]))) / 2;
  for (let p = 0; p < passes; p++) {
    const lines = [0, 1, 2, 3].map((m) => fitSide(g, q, m, c, rad, nSamples, cornerExcl, peakRel));
    const nq = [0, 1, 2, 3].map((m) => lineIntersect(lines[(m + 3) % 4], lines[m]));
    if (nq.some((x) => x === null)) return strict && !p ? null : q;
    let drift = 0;
    for (let i = 0; i < 4; i++) drift = Math.max(drift, Math.hypot(nq[i][0] - q[i][0], nq[i][1] - q[i][1]));
    if (drift > 3 * rad) return strict && !p ? null : q;
    q = nq;
    rad *= 0.4;
  }
  return clockwise(q);
}

export function edgeSupport(g, q, { n = 64, excl = 0.1, step = 12, rel = 0.1, floor = 5, taps = 3 } = {}) {
  const c = [(q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4, (q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4];
  const sup = [];
  const tr = (taps - 1) / 2;
  for (let m = 0; m < 4; m++) {
    const { a, d, n: nr, L } = sideFrame(q, m, c);
    const o = Math.max(2.0, 0.004 * L);
    const diff = new Float64Array(n);
    const thr = new Float64Array(n);
    const ts = linspace(excl, 1 - excl, n);
    for (let i = 0; i < n; i++) {
      const px = a[0] + ts[i] * L * d[0], py = a[1] + ts[i] * L * d[1];
      let vi = 0, vo = 0;
      for (let k = -tr; k <= tr; k++) {
        const tx = px + k * 1.5 * d[0], ty = py + k * 1.5 * d[1];
        vi += sample(g, tx - nr[0] * o, ty - nr[1] * o);
        vo += sample(g, tx + nr[0] * o, ty + nr[1] * o);
      }
      vi /= taps; vo /= taps;
      diff[i] = vi - vo;
      thr[i] = rel ? Math.min(step, Math.max(rel * 0.5 * (vi + vo), floor)) : step;
    }
    const pol = Math.sign(median(diff)) || 1;
    let cnt = 0;
    for (let i = 0; i < n; i++) if (diff[i] * pol > thr[i]) cnt++;
    sup.push(cnt / n);
  }
  const mean = sup.reduce((s, v) => s + v, 0) / 4;
  return Math.min(...sup) > 0.15 ? mean : 0;
}

export function interiorContrast(g, q, { nu = 10, nv = 14, margin = 0.12 } = {}) {
  let s = 0, s2 = 0;
  for (let j = 0; j < nv; j++) {
    const v = margin + ((1 - 2 * margin) * j) / (nv - 1);
    for (let i = 0; i < nu; i++) {
      const u = margin + ((1 - 2 * margin) * i) / (nu - 1);
      const x = (1 - v) * ((1 - u) * q[0][0] + u * q[1][0]) + v * ((1 - u) * q[3][0] + u * q[2][0]);
      const y = (1 - v) * ((1 - u) * q[0][1] + u * q[1][1]) + v * ((1 - u) * q[3][1] + u * q[2][1]);
      const p = sample(g, x, y);
      s += p; s2 += p * p;
    }
  }
  const n = nu * nv, m = s / n;
  return Math.sqrt(Math.max(0, s2 / n - m * m));
}
