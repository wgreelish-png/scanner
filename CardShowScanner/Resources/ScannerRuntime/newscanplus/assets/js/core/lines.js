/*
 * lines.js - line segments -> card quads (port of lab methods._cluster_segments / lines_to_quad).
 *
 * Exports
 *   linesToQuads(segs, W, H, {maxLines=16, topk=6}) -> q[] (clockwise, best first)
 *       segs: Array<[x1,y1,x2,y2]> (already length-filtered). Collinear segments are merged
 *       (4 deg, 0.8% diag), pairs of near-parallel lines >= 15% apart are combined into quads that
 *       must be plausible with every side >= 20% covered by segments.
 *   lsdSegments(gray8, W, H) -> segs | null   cv.createLineSegmentDetector (only when the build has it)
 */
import { cv } from './cv.js';
import { ASPECT, angleScore, clockwise, lineIntersect, plausible, polyArea, quadAspect } from './geom.js';

const COS4 = Math.cos((4 * Math.PI) / 180);
const COS25 = Math.cos((25 * Math.PI) / 180);
const COS50 = Math.cos((50 * Math.PI) / 180);
const dot = (a, b) => a[0] * b[0] + a[1] * b[1];

function clusterSegments(segs, diag) {
  const sorted = segs.slice().sort((s, t) => Math.hypot(t[2] - t[0], t[3] - t[1]) - Math.hypot(s[2] - s[0], s[3] - s[1]));
  const lines = [];
  for (const [x1, y1, x2, y2] of sorted) {
    let d = [x2 - x1, y2 - y1];
    const L = Math.hypot(d[0], d[1]);
    if (L < 1e-6) continue;
    d = [d[0] / L, d[1] / L];
    const mid = [(x1 + x2) / 2, (y1 + y2) / 2];
    let placed = false;
    for (const ln of lines) {
      if (Math.abs(dot(ln.d, d)) < COS4) continue;
      const n = [-ln.d[1], ln.d[0]];
      if (Math.abs(dot([mid[0] - ln.p[0], mid[1] - ln.p[1]], n)) > 0.008 * diag) continue;
      const ta = dot([x1 - ln.p[0], y1 - ln.p[1]], ln.d), tb = dot([x2 - ln.p[0], y2 - ln.p[1]], ln.d);
      ln.ivals.push([Math.min(ta, tb), Math.max(ta, tb)]);
      ln.pts.push([x1, y1], [x2, y2]);
      ln.w.push(L, L);
      ln.length += L;
      placed = true;
      break;
    }
    if (!placed) lines.push({ p: mid, d, ivals: [[-L / 2, L / 2]], pts: [[x1, y1], [x2, y2]], w: [L, L], length: L });
  }
  for (const ln of lines) {
    let sw = 0, cx = 0, cy = 0;
    ln.pts.forEach((p, i) => { sw += ln.w[i]; cx += p[0] * ln.w[i]; cy += p[1] * ln.w[i]; });
    cx /= sw; cy /= sw;
    let sxx = 0, sxy = 0, syy = 0;
    ln.pts.forEach((p, i) => {
      const dx = p[0] - cx, dy = p[1] - cy, w = ln.w[i];
      sxx += w * dx * dx; sxy += w * dx * dy; syy += w * dy * dy;
    });
    const theta = 0.5 * Math.atan2(2 * sxy, sxx - syy);
    const d = [Math.cos(theta), Math.sin(theta)];
    const oldP = ln.p, oldD = ln.d;
    ln.ivals = ln.ivals.map(([t1, t2]) => {
      const a = dot([oldP[0] + t1 * oldD[0] - cx, oldP[1] + t1 * oldD[1] - cy], d);
      const b = dot([oldP[0] + t2 * oldD[0] - cx, oldP[1] + t2 * oldD[1] - cy], d);
      return [Math.min(a, b), Math.max(a, b)];
    });
    ln.p = [cx, cy];
    ln.d = d;
  }
  return lines.sort((a, b) => b.length - a.length);
}

function coverage(ln, a, b) {
  const lo = Math.min(a, b), hi = Math.max(a, b);
  if (hi - lo < 1e-6) return 0;
  const iv = ln.ivals.filter(([s, e]) => e > lo && s < hi).map(([s, e]) => [Math.max(lo, s), Math.min(hi, e)]).sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  let tot = 0, cs = null, ce = null;
  for (const [s, e] of iv) {
    if (ce === null || s > ce) {
      if (ce !== null) tot += ce - cs;
      cs = s; ce = e;
    } else ce = Math.max(ce, e);
  }
  if (ce !== null) tot += ce - cs;
  return tot / (hi - lo);
}

export function linesToQuads(segs, W, H, { maxLines = 16, topk = 6 } = {}) {
  const lines = clusterSegments(segs, Math.hypot(W, H)).slice(0, maxLines);
  const n = lines.length;
  if (n < 4) return [];
  const pairs = [];
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (Math.abs(dot(lines[i].d, lines[j].d)) < COS25) continue;
      const nrm = [-lines[i].d[1], lines[i].d[0]];
      const sep = Math.abs(dot([lines[j].p[0] - lines[i].p[0], lines[j].p[1] - lines[i].p[1]], nrm));
      if (sep < 0.15 * Math.min(W, H)) continue;
      pairs.push([i, j]);
    }
  }
  const found = [];
  for (let a = 0; a < pairs.length; a++) {
    const [i, j] = pairs[a];
    for (let b = a + 1; b < pairs.length; b++) {
      const [k, l] = pairs[b];
      if (new Set([i, j, k, l]).size < 4) continue;
      if (Math.abs(dot(lines[i].d, lines[k].d)) > COS50) continue;
      const L = [lines[i], lines[k], lines[j], lines[l]];
      const q = [0, 1, 2, 3].map((m) => lineIntersect([L[m].p, L[m].d], [L[(m + 1) % 4].p, L[(m + 1) % 4].d]));
      if (q.some((p) => p === null)) continue;
      if (q.some((p) => p[0] < -0.08 * W || p[0] > 1.08 * W || p[1] < -0.08 * H || p[1] > 1.08 * H)) continue;
      if (!plausible(q, W, H, { amin: 0.04 })) continue;
      const cov = [0, 1, 2, 3].map((m) => {
        const ln = L[m], pa = q[(m + 3) % 4], pb = q[m];
        return coverage(ln, dot([pa[0] - ln.p[0], pa[1] - ln.p[1]], ln.d), dot([pb[0] - ln.p[0], pb[1] - ln.p[1]], ln.d));
      });
      if (Math.min(...cov) < 0.2) continue;
      const area = polyArea(q) / (W * H);
      const mcov = cov.reduce((s, v) => s + v, 0) / 4;
      const s = mcov * mcov * (1 - Math.abs(quadAspect(q) - ASPECT) / 0.15) * Math.sqrt(area) * angleScore(q);
      found.push([s, q]);
    }
  }
  return found.sort((x, y) => y[0] - x[0]).slice(0, topk).map(([, q]) => clockwise(q));
}

// A detector reused across detect() calls grows the WASM heap ~256 B per call (LSD_REFINE_STD keeps internal
// buffers); a fresh one per call is free to construct and leaks nothing.
export function lsdSegments(gray8, W, H) {
  if (typeof cv.createLineSegmentDetector !== 'function') return null;
  const lsd = cv.createLineSegmentDetector(cv.LSD_REFINE_STD ?? 1);
  const blur = new cv.Mat();
  const out = new cv.Mat();
  try {
    cv.GaussianBlur(gray8, blur, new cv.Size(3, 3), 0);
    lsd.detect(blur, out);
    const f = out.data32F;
    const minLen = 0.05 * Math.min(W, H);
    const segs = [];
    for (let i = 0; i + 3 < f.length; i += 4) {
      if (Math.hypot(f[i + 2] - f[i], f[i + 3] - f[i + 1]) > minLen) segs.push([f[i], f[i + 1], f[i + 2], f[i + 3]]);
    }
    return segs;
  } finally {
    blur.delete(); out.delete(); lsd.delete();
  }
}
