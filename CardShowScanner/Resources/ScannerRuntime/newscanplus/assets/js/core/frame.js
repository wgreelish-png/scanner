/*
 * frame.js - camera stream, pooled frame grabs, and file/image -> Mat.
 *
 * Exports
 *   openCamera({video?, longSide=1280, facingMode='environment'}) -> Promise<Camera>
 *     Camera: {video, stream, track, width, height, torchSupported, setTorch(on) -> Promise<bool>,
 *              refocus() -> Promise, stop()}
 *   createGrabber(video, {longSide=1280, smallSide=320, ring=6}) -> Grabber
 *     grab() -> Frame | null     full-res RGBA Mat from a fixed ring; null when all ring slots are held.
 *                                The caller MUST release(frame) (never mat.delete()).
 *     grabSmall() -> Frame       one reused small RGBA Mat (fastQuad / motion); valid until the next call.
 *     release(frame), dispose()  dispose deletes every pooled Mat (held frames included).
 *     Frame: {mat, w, h, t, scale}   scale = video px per frame px.
 *   MatPool(rows, cols, type, max)  acquire() -> Mat | null, release(mat), dispose()
 *   imageToMat(source, {longSide=1280}) -> Promise<{mat, w, h, scale}>   File/Blob/img/bitmap/canvas/ImageData,
 *     EXIF orientation applied; longSide=0 keeps native size. Caller deletes mat.
 *   matFromImageData(imageData) -> Mat CV_8UC4 (caller deletes)
 * Frames are filled with mat.data.set(getImageData()) into pre-allocated Mats; cv.imread is never used.
 */
import { cv } from './cv.js';

const now = () => performance.now();

export class MatPool {
  constructor(rows, cols, type, max) {
    this.rows = rows; this.cols = cols; this.type = type; this.max = max;
    this.free = []; this.held = new Set();
  }
  acquire() {
    let m = this.free.pop();
    if (!m) {
      if (this.held.size >= this.max) return null;
      m = new cv.Mat(this.rows, this.cols, this.type);
    }
    this.held.add(m);
    return m;
  }
  release(m) {
    if (!this.held.delete(m)) return;
    if (this.disposed) m.delete(); else this.free.push(m);
  }
  dispose() {
    this.disposed = true;
    for (const m of this.free) m.delete();
    for (const m of this.held) m.delete();
    this.free = []; this.held.clear();
  }
}

function makeCanvas(w, h) {
  if (typeof OffscreenCanvas === 'function') return new OffscreenCanvas(w, h);
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  return c;
}

function ctx2d(canvas) {
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  return ctx;
}

function fitLong(w, h, L) {
  if (!L || Math.max(w, h) <= L) return [w, h, 1];
  const s = L / Math.max(w, h);
  return [Math.round(w * s), Math.round(h * s), s];
}

function isAndroid() {
  return typeof navigator !== 'undefined' && /Android/i.test(navigator.userAgent || '');
}

export async function openCamera({ video = null, longSide = 1280, facingMode = 'environment' } = {}) {
  const base = { facingMode: { ideal: facingMode }, width: { ideal: longSide }, height: { ideal: Math.round((longSide * 9) / 16) } };
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: isAndroid() ? { ...base, advanced: [{ focusMode: 'continuous' }] } : base });
  } catch (e) {
    if (e && (e.name === 'NotAllowedError' || e.name === 'SecurityError')) throw e;
    stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: base });
  }
  const track = stream.getVideoTracks()[0];
  const caps = typeof track.getCapabilities === 'function' ? track.getCapabilities() : {};
  if (caps.focusMode && caps.focusMode.includes('continuous')) {
    try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch (_) { /* optional */ }
  }
  const v = video || document.createElement('video');
  v.playsInline = true; v.muted = true; v.autoplay = true;
  v.setAttribute('playsinline', '');
  v.srcObject = stream;
  if (v.readyState < 1) await new Promise((r) => v.addEventListener('loadedmetadata', r, { once: true }));
  await v.play().catch(() => {});

  let torchOn = false;
  return {
    video: v, stream, track,
    get width() { return v.videoWidth; },
    get height() { return v.videoHeight; },
    torchSupported: !!caps.torch,
    async setTorch(on) {
      if (!caps.torch) return false;
      try { await track.applyConstraints({ advanced: [{ torch: !!on }] }); torchOn = !!on; return true; } catch (_) { return false; }
    },
    get torch() { return torchOn; },
    async refocus() {
      if (!caps.focusMode) return;
      try {
        if (caps.focusMode.includes('single-shot')) {
          await track.applyConstraints({ advanced: [{ focusMode: 'single-shot' }] });
          await new Promise((r) => setTimeout(r, 450));
        }
        if (caps.focusMode.includes('continuous')) await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] });
      } catch (_) { /* optional */ }
    },
    stop() {
      for (const t of stream.getTracks()) t.stop();
      if (v.srcObject === stream) v.srcObject = null;
    },
  };
}

export function createGrabber(video, { longSide = 1280, smallSide = 320, ring = 6 } = {}) {
  let pool = null, canvas = null, ctx = null, key = '';
  let small = null, sCanvas = null, sCtx = null, sKey = '';
  const owner = new Map();

  function ensure() {
    const [w, h, s] = fitLong(video.videoWidth, video.videoHeight, longSide);
    if (!w || !h) return null;
    const k = w + 'x' + h;
    if (k !== key) {
      if (pool) pool.dispose();
      pool = new MatPool(h, w, cv.CV_8UC4, ring);
      canvas = makeCanvas(w, h); ctx = ctx2d(canvas);
      key = k;
    }
    return [w, h, s];
  }

  return {
    grab() {
      const dims = ensure();
      if (!dims) return null;
      const [w, h, s] = dims;
      const mat = pool.acquire();
      if (!mat) return null;
      ctx.drawImage(video, 0, 0, w, h);
      mat.data.set(ctx.getImageData(0, 0, w, h).data);
      const f = { mat, w, h, t: now(), scale: 1 / s };
      owner.set(f, pool);
      return f;
    },
    grabSmall() {
      const [w, h, s] = fitLong(video.videoWidth, video.videoHeight, smallSide);
      if (!w || !h) return null;
      const k = w + 'x' + h;
      if (k !== sKey) {
        if (small) small.delete();
        small = new cv.Mat(h, w, cv.CV_8UC4);
        sCanvas = makeCanvas(w, h); sCtx = ctx2d(sCanvas);
        sKey = k;
      }
      sCtx.drawImage(video, 0, 0, w, h);
      small.data.set(sCtx.getImageData(0, 0, w, h).data);
      return { mat: small, w, h, t: now(), scale: 1 / s };
    },
    release(f) {
      const p = f && owner.get(f);
      if (!p) return;
      owner.delete(f);
      p.release(f.mat);
    },
    dispose() {
      if (pool) pool.dispose();
      if (small) small.delete();
      pool = null; small = null; key = ''; sKey = '';
      owner.clear();
    },
  };
}

export function matFromImageData(id) {
  const m = new cv.Mat(id.height, id.width, cv.CV_8UC4);
  m.data.set(id.data);
  return m;
}

async function toDrawable(source) {
  if (typeof Blob !== 'undefined' && source instanceof Blob) {
    try { return await createImageBitmap(source, { imageOrientation: 'from-image' }); } catch (_) { return createImageBitmap(source); }
  }
  if (typeof HTMLImageElement !== 'undefined' && source instanceof HTMLImageElement && !source.complete) {
    await new Promise((res, rej) => { source.onload = res; source.onerror = rej; });
  }
  return source;
}

export async function imageToMat(source, { longSide = 1280 } = {}) {
  if (typeof ImageData !== 'undefined' && source instanceof ImageData && (!longSide || Math.max(source.width, source.height) <= longSide)) {
    return { mat: matFromImageData(source), w: source.width, h: source.height, scale: 1 };
  }
  let src = source;
  if (typeof ImageData !== 'undefined' && source instanceof ImageData) {
    const c = makeCanvas(source.width, source.height);
    c.getContext('2d').putImageData(source, 0, 0);
    src = c;
  }
  const d = await toDrawable(src);
  const sw = d.naturalWidth || d.videoWidth || d.width, sh = d.naturalHeight || d.videoHeight || d.height;
  const [w, h, s] = fitLong(sw, sh, longSide);
  const c = makeCanvas(w, h);
  const ctx = ctx2d(c);
  ctx.drawImage(d, 0, 0, w, h);
  if (typeof d.close === 'function' && d !== source) d.close();
  const mat = new cv.Mat(h, w, cv.CV_8UC4);
  mat.data.set(ctx.getImageData(0, 0, w, h).data);
  return { mat, w, h, scale: s };
}
