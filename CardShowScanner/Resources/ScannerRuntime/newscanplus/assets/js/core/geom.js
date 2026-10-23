/*
 * geom.js - pure-JS quad geometry (no OpenCV). Quads are [[x,y] x4].
 *
 * Exports
 *   ASPECT = 0.716 (card w/h)
 *   clockwise(q) -> q          screen-clockwise, starting at the corner with min x+y
 *   roll(q, k) -> q            numpy roll: out[i] = q[(i - k) mod 4]
 *   orientVariants(q) -> q[]   card-order hypotheses: portrait [0, 180]; landscape [both 90s]
 *   polyArea(q), quadAspect(q), isConvex(q), angleScore(q), quadScore(q, W, H)
 *   plausible(q, W, H, {amin=0.05, amax=0.92, rmin=0.58, rmax=0.85}) -> boolean
 *   rectAspect(q, W, H) -> {aspect, f}   perspective-corrected min/max side ratio (Zhang-He rectangle
 *       rectification, principal point = frame centre, focal from the quad when sane else 0.8 x long side)
 *   cornerAngles(q) -> deg[4], oppositeRatios(q) -> [r02, r13], borderSides(q, W, H, tol=0.012) -> count
 *   GATE, gateQuad(q, W, H, opts?) -> {ok, why, aspect, minAngle, maxAngle, minRatio, area, border}
 *       card-shape gate: convex, area 3-97% of the frame, corner angles 55-125 deg, opposite sides >= 0.6 of
 *       each other, rectified aspect 0.60-0.84 (card 0.716, portrait or landscape), <= 1 side on the frame border
 *   lineIntersect([p,d], [p2,d2]) -> [x,y] | null
 *   cornerDrift(a, b) -> max corner distance / diagonal of a
 *   scaleQuad(q, s) -> q
 */

export const ASPECT = 0.716;
const ANGLE_TOL = 25;

const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

export function clockwise(q) {
  const cx = (q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4;
  const cy = (q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4;
  const s = q.map((p) => [p[0], p[1]]).sort((a, b) => Math.atan2(a[1] - cy, a[0] - cx) - Math.atan2(b[1] - cy, b[0] - cx));
  let k = 0;
  for (let i = 1; i < 4; i++) if (s[i][0] + s[i][1] < s[k][0] + s[k][1]) k = i;
  return [0, 1, 2, 3].map((i) => s[(i + k) % 4]);
}

export function roll(q, k) {
  return [0, 1, 2, 3].map((i) => q[(((i - k) % 4) + 4) % 4]);
}

export function orientVariants(q) {
  const c = clockwise(q);
  const w = dist(c[1], c[0]);
  const h = dist(c[3], c[0]);
  return w <= h ? [c, roll(c, 2)] : [roll(c, 1), roll(c, 3)];
}

export function polyArea(q) {
  let a = 0;
  for (let i = 0; i < q.length; i++) {
    const p = q[i], r = q[(i + 1) % q.length];
    a += p[0] * r[1] - r[0] * p[1];
  }
  return Math.abs(a) / 2;
}

export function quadAspect(q) {
  const w = (dist(q[1], q[0]) + dist(q[2], q[3])) / 2;
  const h = (dist(q[3], q[0]) + dist(q[2], q[1])) / 2;
  return Math.max(w, h) > 0 ? Math.min(w, h) / Math.max(w, h) : 0;
}

export function isConvex(q) {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    const z = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (z === 0) continue;
    const s = z > 0 ? 1 : -1;
    if (sign && s !== sign) return false;
    sign = s;
  }
  return sign !== 0;
}

export function angleScore(q) {
  let tot = 0;
  for (let i = 0; i < 4; i++) {
    const p1 = q[i], p2 = q[(i + 1) % 4], p3 = q[(i + 2) % 4];
    const v1x = p1[0] - p2[0], v1y = p1[1] - p2[1], v2x = p3[0] - p2[0], v2y = p3[1] - p2[1];
    const m1 = Math.hypot(v1x, v1y), m2 = Math.hypot(v2x, v2y);
    if (m1 > 0 && m2 > 0) {
      const c = Math.max(-1, Math.min(1, (v1x * v2x + v1y * v2y) / (m1 * m2)));
      tot += Math.abs((Math.acos(c) * 180) / Math.PI - 90);
    }
  }
  return Math.max(0, 1 - tot / 4 / ANGLE_TOL);
}

export function quadScore(q, W, H) {
  const r = quadAspect(q);
  return (polyArea(q) / (W * H)) * Math.max(0, 1 - Math.abs(r - ASPECT) / 0.15) * angleScore(q);
}

export function plausible(q, W, H, { amin = 0.05, amax = 0.92, rmin = 0.58, rmax = 0.85 } = {}) {
  if (!q || q.length !== 4) return false;
  for (const p of q) if (!Number.isFinite(p[0]) || !Number.isFinite(p[1])) return false;
  const a = polyArea(q);
  if (a < amin * W * H || a > amax * W * H) return false;
  if (!isConvex(q)) return false;
  const r = quadAspect(q);
  return r >= rmin && r <= rmax;
}

// Zhang & He rectangle rectification, principal point at the frame centre; f in units of the long side.
// Uses the quad's own focal estimate when it is sane, else F_PRIOR (phone main camera ~26 mm equivalent).
const F_PRIOR = 0.8;
export function rectAspect(q, W, H) {
  const L = Math.max(W, H), cx = W / 2, cy = H / 2;
  const m = (p) => [(p[0] - cx) / L, (p[1] - cy) / L, 1];
  const m1 = m(q[0]), m2 = m(q[1]), m4 = m(q[2]), m3 = m(q[3]);
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const dot3 = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const c14 = cross(m1, m4);
  const d2 = dot3(cross(m2, m4), m3), d3 = dot3(cross(m3, m4), m2);
  if (Math.abs(d2) < 1e-12 || Math.abs(d3) < 1e-12) return { aspect: quadAspect(q), f: null };
  const k2 = dot3(c14, m3) / d2, k3 = dot3(c14, m2) / d3;
  const n2 = [k2 * m2[0] - m1[0], k2 * m2[1] - m1[1], k2 - 1];
  const n3 = [k3 * m3[0] - m1[0], k3 * m3[1] - m1[1], k3 - 1];
  let f = null;
  if (Math.abs(n2[2] * n3[2]) > 1e-9) {
    const f2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2]);
    if (f2 > 0.16 && f2 < 9) f = Math.sqrt(f2);
  }
  const ff = (f || F_PRIOR) ** 2;
  const w2 = n2[0] * n2[0] + n2[1] * n2[1] + ff * n2[2] * n2[2];
  const h2 = n3[0] * n3[0] + n3[1] * n3[1] + ff * n3[2] * n3[2];
  if (!(w2 > 0 && h2 > 0)) return { aspect: 0, f };
  const r = Math.sqrt(w2 / h2);
  return { aspect: Math.min(r, 1 / r), f };
}

export function cornerAngles(q) {
  const out = [];
  for (let i = 0; i < 4; i++) {
    const p = q[(i + 3) % 4], c = q[i], n = q[(i + 1) % 4];
    const ax = p[0] - c[0], ay = p[1] - c[1], bx = n[0] - c[0], by = n[1] - c[1];
    const den = Math.hypot(ax, ay) * Math.hypot(bx, by);
    out.push(den > 0 ? (Math.acos(Math.max(-1, Math.min(1, (ax * bx + ay * by) / den))) * 180) / Math.PI : 0);
  }
  return out;
}

// min/max length of each pair of opposite sides (1 = parallelogram); perspective alone rarely goes below ~0.6
export function oppositeRatios(q) {
  const s = [0, 1, 2, 3].map((i) => dist(q[i], q[(i + 1) % 4]));
  const r = (a, b) => (Math.max(a, b) > 0 ? Math.min(a, b) / Math.max(a, b) : 0);
  return [r(s[0], s[2]), r(s[1], s[3])];
}

// sides lying along the frame border (both ends within tol * long side of the same frame edge)
export function borderSides(q, W, H, tol = 0.012) {
  const t = tol * Math.max(W, H);
  const near = (p) => [p[0] < t, p[1] < t, p[0] > W - 1 - t, p[1] > H - 1 - t];
  let n = 0;
  for (let i = 0; i < 4; i++) {
    const a = near(q[i]), b = near(q[(i + 1) % 4]);
    if (a.some((v, k) => v && b[k])) n++;
  }
  return n;
}

/*
 * gateQuad(q, W, H, opts) -> {ok, why, aspect, minAngle, maxAngle, minRatio, area, border}
 * A card is 63x88 mm. Accept only convex quads whose perspective-corrected aspect is within [amin, amax]
 * (min/max side, so portrait and landscape alike), whose corner angles a tilted rectangle can produce,
 * whose opposite sides are not wildly unequal (slivers / near-triangles), that cover a sane frame fraction
 * and do not run along the frame border.
 */
export const GATE = { amin: 0.6, amax: 0.84, angMin: 55, angMax: 125, ratioMin: 0.6, areaMin: 0.03, areaMax: 0.97, border: 1 };
export function gateQuad(q, W, H, opts = {}) {
  const g = { ...GATE, ...opts };
  const res = { ok: false, why: '', aspect: 0, minAngle: 0, maxAngle: 0, minRatio: 0, area: 0, border: 0 };
  if (!q || q.length !== 4 || q.some((p) => !Number.isFinite(p[0]) || !Number.isFinite(p[1]))) { res.why = 'invalid'; return res; }
  if (!isConvex(q)) { res.why = 'concave'; return res; }
  const ang = cornerAngles(q);
  res.area = polyArea(q) / (W * H);
  res.minAngle = Math.min(...ang);
  res.maxAngle = Math.max(...ang);
  res.minRatio = Math.min(...oppositeRatios(q));
  res.aspect = rectAspect(q, W, H).aspect;
  res.border = borderSides(q, W, H);
  if (res.area < g.areaMin || res.area > g.areaMax) res.why = 'area';
  else if (res.minAngle < g.angMin || res.maxAngle > g.angMax) res.why = 'angle';
  else if (res.minRatio < g.ratioMin) res.why = 'sliver';
  else if (res.aspect < g.amin || res.aspect > g.amax) res.why = 'aspect';
  else if (res.border > g.border) res.why = 'border';
  else res.ok = true;
  return res;
}

export function lineIntersect(l1, l2) {
  const [p, d] = l1, [q, e] = l2;
  const det = -d[0] * e[1] + e[0] * d[1];
  if (Math.abs(det) < 1e-9) return null;
  const qx = q[0] - p[0], qy = q[1] - p[1];
  const t = (-qx * e[1] + e[0] * qy) / det;
  return [p[0] + t * d[0], p[1] + t * d[1]];
}

export function cornerDrift(a, b) {
  let m = 0;
  for (let i = 0; i < 4; i++) m = Math.max(m, dist(a[i], b[i]));
  return m / (dist(a[2], a[0]) + 1e-6);
}

export function scaleQuad(q, s) {
  return q.map((p) => [p[0] * s, p[1] * s]);
}
