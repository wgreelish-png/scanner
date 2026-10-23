/*
 * quadtrack.js - temporal stabiliser for the live outline (main thread, pure JS, no OpenCV).
 *
 * Exports
 *   createQuadTracker({holdMs=300, jump=0.15, confirm=2, minCutoff=1.5, beta=3, dCutoff=1}) -> Tracker
 *     update(quad | null, t, w, h)  quad: an already gated quad in a w x h frame (any corner order; outline 320 px
 *                                   and scan 1280 px frames of the same video mix freely), null = miss
 *     current(t) -> {quad, w, h} | null   smoothed quad in the px space of the latest update; null after holdMs
 *                                         without a measurement that agrees with the shown pose
 *     reset()
 * Corners are matched to the shown quad by the cyclic shift with the least total distance, then each coordinate
 * (normalised to the frame) goes through a one-euro filter. A measurement more than `jump` (max corner move /
 * diagonal) away from the shown pose is held as pending and only replaces it after `confirm` consecutive
 * agreeing measurements, or at once when the shown pose has gone stale; replacing snaps (no smoothing across).
 */
import { clockwise } from './geom.js';

function align(q, ref) {
  let best = q, bestE = Infinity;
  for (let k = 0; k < 4; k++) {
    let e = 0;
    for (let i = 0; i < 4; i++) {
      const p = q[(i + k) % 4];
      e += Math.hypot(p[0] - ref[i][0], p[1] - ref[i][1]);
    }
    if (e < bestE) { bestE = e; best = [0, 1, 2, 3].map((i) => q[(i + k) % 4]); }
  }
  return best;
}

function drift(a, b) {
  let m = 0;
  for (let i = 0; i < 4; i++) m = Math.max(m, Math.hypot(a[i][0] - b[i][0], a[i][1] - b[i][1]));
  const diag = Math.hypot(b[2][0] - b[0][0], b[2][1] - b[0][1]) + 1e-6;
  return m / diag;
}

export function createQuadTracker({ holdMs = 300, jump = 0.15, confirm = 2, minCutoff = 1.5, beta = 3, dCutoff = 1 } = {}) {
  let shown = null;    // normalised, filtered [[x,y]x4]
  let raw = null;      // last accepted raw measurement (normalised, aligned)
  let deriv = null;    // filtered derivative per coordinate
  let lastT = 0;
  let goodAt = -Infinity;
  let pending = null;
  let pendingN = 0;
  let w = 1, h = 1;

  const alpha = (cutoff, dt) => 1 / (1 + 1 / (2 * Math.PI * cutoff * dt));

  function snap(q, t) {
    shown = q.map((p) => [p[0], p[1]]);
    raw = q.map((p) => [p[0], p[1]]);
    deriv = q.map(() => [0, 0]);
    lastT = t;
    goodAt = t;
    pending = null;
    pendingN = 0;
  }

  function filter(q, t) {
    const dt = Math.max(1e-3, (t - lastT) / 1000);
    const ad = alpha(dCutoff, dt);
    for (let i = 0; i < 4; i++) {
      for (let c = 0; c < 2; c++) {
        const dx = (q[i][c] - raw[i][c]) / dt;
        deriv[i][c] += ad * (dx - deriv[i][c]);
        const a = alpha(minCutoff + beta * Math.abs(deriv[i][c]), dt);
        shown[i][c] += a * (q[i][c] - shown[i][c]);
        raw[i][c] = q[i][c];
      }
    }
    lastT = t;
    goodAt = t;
  }

  return {
    update(quad, t, fw, fh) {
      if (!quad) return;
      w = fw; h = fh;
      let q = clockwise(quad).map((p) => [p[0] / fw, p[1] / fh]);
      const stale = t - goodAt > holdMs;
      if (!shown || stale) { snap(shown ? align(q, shown) : q, t); return; }
      q = align(q, shown);
      if (drift(q, shown) <= jump) {
        pending = null;
        pendingN = 0;
        filter(q, t);
        return;
      }
      if (pending && drift(align(q, pending), pending) <= jump) pendingN++;
      else pendingN = 1;
      pending = q;
      if (pendingN >= confirm) snap(q, t);
    },
    current(t) {
      if (!shown || t - goodAt > holdMs) return null;
      return { quad: shown.map((p) => [p[0] * w, p[1] * h]), w, h };
    },
    reset() { shown = raw = deriv = pending = null; pendingN = 0; goodAt = -Infinity; },
  };
}
