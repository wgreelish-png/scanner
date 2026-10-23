/*
 * motion.js - per-frame stability gate on a ~160 px gray thumbnail (+ optional quad corner drift).
 *
 * Exports
 *   thumbFromMat(mat, width=160) -> {data: Uint8Array, w, h}   RGBA/RGB/gray Mat, 2x2 point samples per pixel
 *   thumbFromImageData(imageData, width=160) -> {data, w, h}
 *   createMotionGate(opts) -> Gate
 *     opts: {stableMs=200, lowDiff=3.5, highDiff=8, lowDrift=0.012, highDrift=0.03}
 *     update(thumb, quad?, t=performance.now()) -> {state, diff, drift, changed}
 *       state: 'moving' | 'settling' | 'stable'. diff = mean |delta| (0..255) after removing the global
 *       brightness shift (auto-exposure); drift = max corner move / diagonal (1 when the quad appears/vanishes;
 *       quad omitted -> ignored). Stable after stableMs of low diff + low drift; hysteresis between low/high.
 *     on('state'|'stable'|'moving', fn(info)) -> off()     'stable' fires on each entry into stable
 *     reset(), state
 * Cost: one pass over w*h bytes (160x90: ~14k) - well under 1 ms. Thumbnails are JS-owned (no Mats).
 */
import { cornerDrift } from './geom.js';

function sampleThumb(src, sw, sh, ch, width) {
  const w = Math.min(width, sw);
  const h = Math.max(1, Math.round((sh * w) / sw));
  const out = new Uint8Array(w * h);
  const fx = sw / w, fy = sh / h;
  for (let y = 0; y < h; y++) {
    const y0 = Math.min(sh - 1, Math.floor((y + 0.25) * fy)) * sw, y1 = Math.min(sh - 1, Math.floor((y + 0.75) * fy)) * sw;
    for (let x = 0; x < w; x++) {
      const x0 = Math.min(sw - 1, Math.floor((x + 0.25) * fx)), x1 = Math.min(sw - 1, Math.floor((x + 0.75) * fx));
      let acc = 0;
      for (const o of [y0 + x0, y0 + x1, y1 + x0, y1 + x1]) {
        const i = o * ch;
        acc += ch >= 3 ? (src[i] * 77 + src[i + 1] * 150 + src[i + 2] * 29) >> 8 : src[i];
      }
      out[y * w + x] = acc >> 2;
    }
  }
  return { data: out, w, h };
}

export function thumbFromMat(mat, width = 160) {
  return sampleThumb(mat.data, mat.cols, mat.rows, mat.channels(), width);
}

export function thumbFromImageData(id, width = 160) {
  return sampleThumb(id.data, id.width, id.height, 4, width);
}

export function createMotionGate({ stableMs = 200, lowDiff = 3.5, highDiff = 8, lowDrift = 0.012, highDrift = 0.03 } = {}) {
  let prev = null, prevQuad, state = 'moving', lowSince = null, firedStable = false;
  const subs = { state: new Set(), stable: new Set(), moving: new Set() };
  const emit = (k, info) => { for (const fn of subs[k]) fn(info); };

  function measure(thumb) {
    if (!prev || prev.w !== thumb.w || prev.h !== thumb.h) return 255;
    const a = thumb.data, b = prev.data, n = a.length;
    let sum = 0;
    for (let i = 0; i < n; i++) sum += a[i] - b[i];
    const mu = sum / n;
    let acc = 0;
    for (let i = 0; i < n; i++) acc += Math.abs(a[i] - b[i] - mu);
    return acc / n;
  }

  return {
    get state() { return state; },
    update(thumb, quad, t = performance.now()) {
      const diff = measure(thumb);
      if (!prev || prev.data.length !== thumb.data.length) prev = { data: new Uint8Array(thumb.data.length), w: 0, h: 0 };
      prev.data.set(thumb.data);
      prev.w = thumb.w; prev.h = thumb.h;
      let drift = 0;
      if (quad !== undefined) {
        if (!quad !== !prevQuad) drift = prevQuad === undefined ? 0 : 1;
        else if (quad && prevQuad) drift = cornerDrift(prevQuad, quad);
        prevQuad = quad || null;
      }
      const high = diff > highDiff || drift > highDrift;
      const low = diff < lowDiff && drift < lowDrift;
      const before = state;
      if (high) {
        state = 'moving'; lowSince = null;
      } else if (low) {
        if (lowSince === null) lowSince = t;
        state = t - lowSince >= stableMs ? 'stable' : 'settling';
      } else {
        lowSince = null;
        if (state === 'stable') state = 'settling';
      }
      if (state !== 'stable') firedStable = false;
      const info = { state, diff, drift, changed: state !== before, t };
      if (info.changed) {
        emit('state', info);
        if (state === 'moving') emit('moving', info);
      }
      if (state === 'stable' && !firedStable) { firedStable = true; emit('stable', info); }
      return info;
    },
    on(k, fn) { subs[k].add(fn); return () => subs[k].delete(fn); },
    reset() { prev = null; prevQuad = undefined; state = 'moving'; lowSince = null; firedStable = false; },
  };
}
