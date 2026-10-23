/*
 * detect.js - card quad candidates (port of lab pipeline.candidates + refine_all) and a per-frame fast quad.
 *
 * Exports
 *   SOLID = 0.5   edge support (edgefit.edgeSupport) at which a gated quad counts as "a card is here"
 *   detectCandidates(frame, {det=480, maxCands=8, refine=true, expand=true, lsd=true}) ->
 *       {cands: [{quad, base, orient, support}], quads: q[], support: number[], present, raw, rejected, lsd,
 *        ms: {cand, refine, lsd, total}}
 *     lsd: true = LSD always a source; false = never; 'auto' = contours only, and the result carries
 *     withLSD() -> the same detection with the LSD quads added (contours and refits reused; ms covers the added
 *     work only). The live scan calls it when the contour-only frame shows no card or is not accepted: LSD often
 *     adds the winning quad (outer edge, tighter fit) even when contour quads look solid, so it is deferred, not
 *     predicted.
 *     frame: CV_8UC4 RGBA (or RGB) Mat, long side ~1280 (refinement runs at this resolution).
 *     Every raw quad is edge-fitted; the refined quad (else the raw one) must pass geom.gateQuad or it is
 *     dropped (rejected counts those). Ranked by edge support x geometry; when the top quad has a solid nested
 *     partner (outer edge vs inner frame) it is moved to second place so both reach the hash vote.
 *     expand: the top quad, when solid, is also grown by EXPAND (black border width of an inner-frame fit) and
 *     re-fitted with a tight search; that extrapolated outer edge goes second. It needs no edge support of its
 *     own (a black border on a dark table has none) and never makes a frame "present" by itself.
 *     quads/support: ranked clockwise quads with support >= CAND_MIN plus the extrapolated one (all hashed).
 *     cands: card-order (TL,TR,BR,BL) quads, <= maxCands (+2 when the extrapolated quad is in), two orientation
 *       hypotheses per quad, 180 deg apart (portrait 0/180, landscape both 90s); the hash vote picks.
 *     present: some gated quad has support >= SOLID and interior contrast >= CONTRAST_MIN (an empty sleeve or a
 *     bare table patch is flat inside). Callers must not match or show a card otherwise.
 *   trackCandidates(frame, seeds: q[] card order, {drift=0.04}) -> detectCandidates shape (+ tracked: true) | null
 *     re-fits last frame's quads only (no frame-wide search); null when the first seed no longer fits.
 *   rawCandidates(frame, det=480, grayFull?, {lsd=true}) -> q[]   unrefined deduped candidates (frame coords,
 *     clockwise);  lsdCandidates(grayFull, det=480) -> q[]   the LSD source alone
 *   fastQuad(frame, {det=320}) -> q | null  CLAHE+Canny contour pass (Otsu fallback) for the live overlay; only
 *     a gated quad with support >= SOLID is returned. Pass a frame already <= ~350 px long (frame.js
 *     grabSmall) to skip the resize; quad is in that frame's coordinates.
 * Sources: CLAHE+Canny contours, saturation-Canny contours, Otsu (both polarities), LSD when available.
 * All Mats are freed before return; the frame is not modified.
 */
import { cv, features } from './cv.js';
import { clockwise, cornerDrift, gateQuad, lineIntersect, orientVariants, plausible, quadScore, scaleQuad } from './geom.js';
import { edgeSupport, grayImage, interiorContrast, refineEdgefit } from './edgefit.js';
import { linesToQuads, lsdSegments } from './lines.js';

export const SOLID = 0.5;
const CAND_MIN = 0.3;
const CONTRAST_MIN = 8;
const EXPAND = 0.095;
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

class Scope {
  constructor() { this.m = []; }
  mat(...a) { const m = new cv.Mat(...a); this.m.push(m); return m; }
  add(m) { this.m.push(m); return m; }
  free() { for (const m of this.m) { try { m.delete(); } catch (_) { /* already freed */ } } this.m = []; }
}

function toGray(src, dst) {
  const ch = src.channels();
  if (ch === 4) cv.cvtColor(src, dst, cv.COLOR_RGBA2GRAY);
  else if (ch === 3) cv.cvtColor(src, dst, cv.COLOR_RGB2GRAY);
  else src.copyTo(dst);
}

function resizeLong(src, dst, L) {
  const s = L / Math.max(src.cols, src.rows);
  if (Math.abs(s - 1) < 1e-3) { src.copyTo(dst); return 1; }
  cv.resize(src, dst, new cv.Size(0, 0), s, s, cv.INTER_AREA);
  return s;
}

function median8(mat) {
  const d = mat.data, n = d.length, hist = new Uint32Array(256);
  for (let i = 0; i < n; i++) hist[d[i]]++;
  const at = (k) => { let c = 0; for (let v = 0; v < 256; v++) { c += hist[v]; if (c > k) return v; } return 255; };
  return n % 2 ? at((n - 1) / 2) : (at(n / 2 - 1) + at(n / 2)) / 2;
}

function edges(S, gray) {
  const g = S.mat();
  const clahe = new cv.CLAHE(2.0, new cv.Size(8, 8));
  try { clahe.apply(gray, g); } finally { clahe.delete(); }
  cv.GaussianBlur(g, g, new cv.Size(5, 5), 0);
  const med = median8(g);
  const e = S.mat(), e2 = S.mat();
  cv.Canny(g, e, Math.trunc(Math.max(10, 0.4 * med)), Math.trunc(Math.min(255, 1.0 * med + 30)));
  cv.Canny(g, e2, 30, 90);
  cv.bitwise_or(e, e2, e);
  return e;
}

function readPts(m) {
  const d = m.data32S, out = [];
  for (let i = 0; i < m.rows; i++) out.push([d[i * 2], d[i * 2 + 1]]);
  return out;
}

function contourToQuad(c) {
  const hull = new cv.Mat();
  const approx = new cv.Mat();
  try {
    cv.convexHull(c, hull, false, true);
    const peri = cv.arcLength(hull, true);
    for (const eps of [0.01, 0.015, 0.02, 0.03, 0.04, 0.05, 0.07]) {
      cv.approxPolyDP(hull, approx, eps * peri, true);
      if (approx.rows === 4) return { q: clockwise(readPts(approx)), hullArea: cv.contourArea(hull) };
      if (approx.rows < 4) break;
    }
    const pts = cv.RotatedRect.points(cv.minAreaRect(c)).map((p) => [p.x, p.y]);
    return { q: clockwise(pts), hullArea: cv.contourArea(hull) };
  } finally {
    hull.delete(); approx.delete();
  }
}

function contourCandidates(binary, W, H, k, mode) {
  const contours = new cv.MatVector();
  const hier = new cv.Mat();
  try {
    cv.findContours(binary, contours, hier, mode, cv.CHAIN_APPROX_SIMPLE);
    const items = [];
    for (let i = 0; i < contours.size(); i++) {
      const c = contours.get(i);
      items.push({ i, a: cv.contourArea(c) });
      c.delete();
    }
    items.sort((x, y) => y.a - x.a);
    const out = [];
    for (const it of items.slice(0, 30)) {
      if (it.a < 0.04 * W * H) break;
      const c = contours.get(it.i);
      try {
        const { q, hullArea } = contourToQuad(c);
        if (plausible(q, W, H)) {
          const sol = it.a / Math.max(hullArea, 1);
          out.push([quadScore(q, W, H) * (0.5 + 0.5 * sol), q]);
        }
      } finally {
        c.delete();
      }
    }
    return out.sort((x, y) => y[0] - x[0]).slice(0, k).map(([, q]) => q);
  } finally {
    contours.delete(); hier.delete();
  }
}

function dedupe(qs, thr = 0.02) {
  const out = [];
  for (const q of qs) if (out.every((o) => cornerDrift(q, o) > thr)) out.push(q);
  return out;
}

function lsdQuads(gray, s) {
  const segs = lsdSegments(gray, gray.cols, gray.rows);
  return segs && segs.length ? linesToQuads(segs, gray.cols, gray.rows, { topk: 6 }).map((q) => scaleQuad(q, 1 / s)) : [];
}

// LSD candidates alone (frame coords) from a full-size CV_8UC1; [] without LSD in the build.
export function lsdCandidates(grayFull, det = 480) {
  if (!features.hasLSD) return [];
  const gray = new cv.Mat();
  try {
    const s = resizeLong(grayFull, gray, det);
    return lsdQuads(gray, s);
  } finally {
    gray.delete();
  }
}

// grayFull: optional CV_8UC1 of the frame (reused from detectCandidates). The gray copy is area-resized
// (lab parity); the colour copy only feeds the blurred saturation edges, so it uses the much cheaper
// INTER_LINEAR (INTER_AREA on RGBA at 0.375x costs ~20 ms in the vendored WASM build).
export function rawCandidates(frame, det = 480, grayFull = null, { lsd = true } = {}) {
  const S = new Scope();
  try {
    let gf = grayFull;
    if (!gf) { gf = S.mat(); toGray(frame, gf); }
    const gray = S.mat();
    const s = resizeLong(gf, gray, det);
    const W = gray.cols, H = gray.rows;
    const small = S.mat();
    if (Math.abs(s - 1) < 1e-3) frame.copyTo(small);
    else cv.resize(frame, small, new cv.Size(W, H), 0, 0, cv.INTER_LINEAR);
    const k3 = S.add(cv.Mat.ones(3, 3, cv.CV_8U));
    const k5 = S.add(cv.Mat.ones(5, 5, cv.CV_8U));
    let cands = [];

    const e = edges(S, gray);
    cv.dilate(e, e, k3);
    cv.morphologyEx(e, e, cv.MORPH_CLOSE, k5);
    cands = cands.concat(contourCandidates(e, W, H, 6, cv.RETR_LIST));

    const rgb = S.mat(), hsv = S.mat(), sat = S.mat();
    if (small.channels() === 4) cv.cvtColor(small, rgb, cv.COLOR_RGBA2RGB); else small.copyTo(rgb);
    cv.cvtColor(rgb, hsv, cv.COLOR_RGB2HSV);
    const planes = S.add(new cv.MatVector());
    cv.split(hsv, planes);
    const sp = planes.get(1);
    sp.copyTo(sat);
    sp.delete();
    cv.GaussianBlur(sat, sat, new cv.Size(5, 5), 0);
    cv.Canny(sat, sat, 20, 80);
    cv.dilate(sat, sat, k3);
    cands = cands.concat(contourCandidates(sat, W, H, 3, cv.RETR_LIST));

    const b = S.mat(), otsu = S.mat(), inv = S.mat();
    cv.GaussianBlur(gray, b, new cv.Size(5, 5), 0);
    cv.threshold(b, otsu, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
    cv.bitwise_not(otsu, inv);
    for (const th of [otsu, inv]) {
      cv.morphologyEx(th, th, cv.MORPH_OPEN, k3);
      cands = cands.concat(contourCandidates(th, W, H, 2, cv.RETR_EXTERNAL));
    }

    cands = cands.map((q) => scaleQuad(q, 1 / s));
    if (lsd && features.hasLSD) cands = cands.concat(lsdQuads(gray, s));
    return dedupe(cands);
  } finally {
    S.free();
  }
}

function expandQuad(q, e) {
  const X = lineIntersect([q[0], [q[2][0] - q[0][0], q[2][1] - q[0][1]]], [q[1], [q[3][0] - q[1][0], q[3][1] - q[1][1]]]);
  if (!X) return null;
  return q.map((p) => [X[0] + (p[0] - X[0]) * (1 + e), X[1] + (p[1] - X[1]) * (1 + e)]);
}

function inside(q, p) {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const a = q[i], b = q[(i + 1) % 4];
    const z = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
    const s = z > 0 ? 1 : z < 0 ? -1 : 0;
    if (s && sign && s !== sign) return false;
    if (s) sign = s;
  }
  return true;
}

// outer card edge vs the inner frame / art border of the same card (black borders put both in play)
function nestedPair(outer, inner) {
  const d = cornerDrift(outer, inner);
  return d > 0.015 && d < 0.12 && inner.every((p) => inside(outer, p));
}

export function detectCandidates(frame, { det = 480, maxCands = 8, refine = true, expand = true, lsd = true } = {}) {
  const t0 = now();
  const gm = new cv.Mat();
  const W = frame.cols, H = frame.rows;
  const items = [];
  let rejected = 0, nraw = 0, lsdMs = 0, refineMs = 0, lsdRan = false;
  let g;
  const add = (q) => {
    if (!q || !gateQuad(q, W, H).ok) return false;
    if (items.some((it) => cornerDrift(q, it.q) <= 0.02)) return true;
    const support = edgeSupport(g, q);
    items.push({ q, support, score: support * Math.sqrt(0.6 + (0.4 * quadScore(q, W, H)) / 0.9) });
    return true;
  };
  const addAll = (qs) => {
    const a = now();
    nraw += qs.length;
    for (const q of qs) {
      const r = refine ? refineEdgefit(g, q) : null;
      if (!add(r && clockwise(r)) && !add(q)) rejected++;
    }
    refineMs += now() - a;
  };
  try {
    toGray(frame, gm);
    g = grayImage(gm);
    addAll(rawCandidates(frame, det, gm, { lsd: lsd === true }));
    lsdRan = lsd === true && features.hasLSD;
    // Fallback for square/wide single-card photos where heavy foil glare (e.g. Surge Foil) breaks internal
    // Canny/Otsu contours or causes LSD to latch onto the title bar instead of the outer top border:
    // probe centered card-aspect seeds with strict edgefit and accept only solid quads.
    if (refine && lsd === true && (!items.some((it) => it.support >= SOLID) || Math.min(W, H) / Math.max(W, H) > 0.75)) {
      const a = now();
      for (const my of [0.025, 0.06]) {
        const y0 = Math.round(my * H), y1 = Math.round((1 - my) * H) - 1;
        const ch = y1 - y0 + 1;
        const cw = Math.round(ch * (200 / 280));
        if (cw > 20 && cw <= W * 0.98) {
          const x0 = Math.round((W - cw) / 2), x1 = x0 + cw - 1;
          const seed = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
          nraw++;
          const r = refineEdgefit(g, seed, { search: 0.04, strict: true });
          const q = r && clockwise(r);
          if (q && gateQuad(q, W, H).ok && edgeSupport(g, q) >= SOLID && interiorContrast(g, q) >= CONTRAST_MIN) {
            add(q);
            break;
          } else {
            rejected++;
          }
        }
      }
      refineMs += now() - a;
    }
  } finally {
    gm.delete();
  }

  function finish(t1) {
    const its = items.slice().sort((a, b) => b.score - a.score);
    if (its.length > 2) {
      const k = its.findIndex((it, i) => i > 0 && it.support >= SOLID
        && (nestedPair(it.q, its[0].q) || nestedPair(its[0].q, it.q)));
      if (k > 1) its.splice(1, 0, its.splice(k, 1)[0]);
    }
    const voted = its.filter((it) => it.support >= CAND_MIN);
    const present = its.some((it) => it.support >= SOLID && interiorContrast(g, it.q) >= CONTRAST_MIN);
    if (expand && present && voted[0].support >= SOLID) {
      const e = expandQuad(voted[0].q, EXPAND);
      const r = e && (refineEdgefit(g, e, { search: 0.012, strict: true }) || e);
      const q = r && clockwise(r);
      if (q && gateQuad(q, W, H).ok && its.every((it) => cornerDrift(q, it.q) > 0.01)) {
        voted.splice(1, 0, { q, support: edgeSupport(g, q), derived: true });
      }
    }
    const cands = [];
    voted.forEach((r, base) => {
      orientVariants(r.q).forEach((quad, orient) => cands.push({ quad, base, orient, support: r.support, derived: !!r.derived }));
    });
    const t2 = now();
    const out = {
      cands: cands.slice(0, maxCands + (voted[1]?.derived ? 2 : 0)),
      quads: voted.map((r) => r.q),
      support: voted.map((r) => r.support),
      present,
      raw: nraw,
      rejected,
      lsd: lsdRan,
      ms: { cand: t1 - t0 - refineMs, refine: refineMs + t2 - t1, lsd: lsdMs, total: t2 - t0 },
    };
    if (lsd === 'auto' && !lsdRan && features.hasLSD) out.withLSD = withLSD;
    return out;
  }

  // the same detection plus the LSD source (contours and their refits are reused)
  function withLSD() {
    const a = now();
    const gl = new cv.Mat();
    let extra;
    try {
      toGray(frame, gl);
      extra = lsdCandidates(gl, det);
    } finally {
      gl.delete();
    }
    lsdMs = now() - a;
    lsdRan = true;
    addAll(extra);
    const t1 = now();
    const out = finish(t1);
    out.ms = { cand: lsdMs, refine: now() - a - lsdMs, lsd: lsdMs, total: now() - a };
    return out;
  }

  return finish(now());
}

// Re-fit last frame's card quads (card order, frame px) instead of searching the whole frame: the caller vouches
// that the scene is still (motion gate + a recent accepted match). Each seed is edge-fitted, gated, must keep
// support >= SOLID and stay within drift of the seed; the first seed must also pass the interior contrast test.
// Returns detectCandidates' shape (cands ordered with the seed's orientation first) or null -> full detection.
export function trackCandidates(frame, seeds, { drift = 0.04 } = {}) {
  const t0 = now();
  const W = frame.cols, H = frame.rows;
  const gm = new cv.Mat();
  let g;
  try {
    toGray(frame, gm);
    g = grayImage(gm);
  } finally {
    gm.delete();
  }
  const voted = [];
  for (const [k, s] of seeds.entries()) {
    const cw = clockwise(s);
    const r = refineEdgefit(g, cw);
    const q = r ? clockwise(r) : cw;
    const ok = gateQuad(q, W, H).ok && cornerDrift(q, cw) <= drift;
    const support = ok ? edgeSupport(g, q) : 0;
    if (!ok || support < SOLID || (k === 0 && interiorContrast(g, q) < CONTRAST_MIN)) {
      if (k === 0) return null;
      continue;
    }
    if (voted.some((v) => cornerDrift(q, v.q) <= 0.01)) continue;
    const vs = orientVariants(q);
    if (cornerDrift(vs[1], s) < cornerDrift(vs[0], s)) vs.reverse();
    voted.push({ q, support, vs });
  }
  const cands = [];
  voted.forEach((v, base) => v.vs.forEach((quad, orient) => cands.push({ quad, base, orient, support: v.support, derived: false })));
  const t1 = now();
  return {
    cands, quads: voted.map((v) => v.q), support: voted.map((v) => v.support), present: true, raw: 0, rejected: 0,
    lsd: false, tracked: true, ms: { cand: 0, refine: t1 - t0, lsd: 0, total: t1 - t0 },
  };
}

export function fastQuad(frame, { det = 320, k = 3, solid = SOLID } = {}) {
  const S = new Scope();
  try {
    const gray = S.mat();
    let s = 1;
    if (Math.max(frame.cols, frame.rows) <= det * 1.1) {
      toGray(frame, gray);
    } else {
      const gf = S.mat();
      toGray(frame, gf);
      s = resizeLong(gf, gray, det);
    }
    const W = gray.cols, H = gray.rows;
    const k3 = S.add(cv.Mat.ones(3, 3, cv.CV_8U));
    const k5 = S.add(cv.Mat.ones(5, 5, cv.CV_8U));
    const g = grayImage(gray);
    const pickSolid = (qs) => {
      let best = null;
      for (const q of qs) {
        if (!gateQuad(q, W, H).ok) continue;
        const sup = edgeSupport(g, q, { n: 32 });
        if (sup >= solid && (!best || sup > best.sup + 0.05) && interiorContrast(g, q) >= CONTRAST_MIN) best = { q, sup };
      }
      return best;
    };
    const e = edges(S, gray);
    cv.dilate(e, e, k3);
    cv.morphologyEx(e, e, cv.MORPH_CLOSE, k5);
    let best = pickSolid(contourCandidates(e, W, H, k, cv.RETR_LIST));
    if (!best) {
      const b = S.mat(), th = S.mat();
      cv.GaussianBlur(gray, b, new cv.Size(5, 5), 0);
      cv.threshold(b, th, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
      for (let pass = 0; pass < 2 && !best; pass++) {
        if (pass) cv.bitwise_not(th, th);
        const t = S.mat();
        cv.morphologyEx(th, t, cv.MORPH_OPEN, k3);
        best = pickSolid(contourCandidates(t, W, H, 2, cv.RETR_EXTERNAL));
      }
    }
    return best ? scaleQuad(best.q, 1 / s) : null;
  } finally {
    S.free();
  }
}
