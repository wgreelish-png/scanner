/**
 * scan-backends.js - where quick-scan frames are processed.
 *
 * createBackend() -> Promise<Backend>   module worker when possible, else the main thread
 * Backend: {kind: 'worker' | 'main', quadEveryMs, setPack(pack), scan(video, {reset}) -> Promise<Scan | null>,
 *           quad({data, width, height}) -> Promise<{quad, w, h} | null>, reset(), dispose()}
 *   Scan: scan-engine.js Scan plus ms.capture (main-thread frame capture) and, in the worker, ms.read.
 *   null = no video frame yet, backend switching, or a per-frame failure (logged).
 * Backend.setMeta(meta | null) / setAllow(Uint8Array(n) | null)   desktop only: OCR tie-break facts (null = OCR off)
 *   and the set lock / exclusion mask for scanImage; setPack clears the mask.
 * Backend.scanImage(bitmap, {maxCards, first?}) -> Promise<ImageScan | null>   first: scanImagePasses pass-1 size   still image (desktop uploads): bitmap is an
 *   ImageBitmap already EXIF-oriented and capped by the caller (~2048 long side); ownership passes here (closed).
 *   ImageScan: image-scan.js scanImagePasses result (cards with quad, thumb, result) plus ms.read.
 * Worker frames: ImageBitmap (transferred, created already scaled to 1280 px when the browser supports
 * createImageBitmap resize options) when the worker has OffscreenCanvas 2D, else a transferred 1280 px RGBA read. Pack typed arrays are copied once and transferred. If the worker fails to start (error or
 * INIT_TIMEOUT_MS) the main-thread backend is used; if it dies later, the backend swaps to main once.
 */
import { versioned, importMap } from './shared.js';
import { createFrameReader } from './video-frames.js';
import { pickSrc } from '../core/cv.js';

const LONG = 1280;
const WORKER_URL = '/newscanplus/assets/js/app/quickscan-worker.js';
const CV_SRC = pickSrc();
const INIT_TIMEOUT_MS = 30000;

export async function createBackend() {
    let worker = null;
    if (typeof Worker === 'function' && typeof createImageBitmap === 'function') {
        worker = await workerBackend().catch((err) => {
            console.warn('[quickscan] worker unavailable, scanning on the main thread:', err);
            return null;
        });
    }
    if (!worker) return mainBackend();

    let cur = worker;
    let pack = null;
    let meta = null;
    let allow = null;
    let switching = false;
    worker.onDead = (err) => {
        console.warn('[quickscan] worker died, switching to the main thread:', err);
        switching = true;
        mainBackend().then((m) => {
            if (pack) m.setPack(pack);
            if (meta) m.setMeta(meta);
            if (allow) m.setAllow(allow);
            cur = m;
        }).finally(() => { switching = false; });
    };
    return {
        get kind() { return cur.kind; },
        get quadEveryMs() { return cur.quadEveryMs; },
        setPack(p) { pack = p; allow = null; if (!switching) cur.setPack(p); },
        setMeta(m) { meta = m; if (!switching) cur.setMeta(m); },
        setAllow(a) { allow = a; if (!switching) cur.setAllow(a); },
        scan: (video, opts) => (switching ? Promise.resolve(null) : cur.scan(video, opts)),
        quad: (img) => (switching ? Promise.resolve(null) : cur.quad(img)),
        scanImage: (bitmap, opts) => (switching ? (bitmap.close(), Promise.resolve(null)) : cur.scanImage(bitmap, opts)),
        reset: () => { if (!switching) cur.reset(); },
        dispose: () => cur.dispose(),
    };
}

function workerBackend() {
    return new Promise((resolve, reject) => {
        const w = new Worker(versioned(WORKER_URL), { type: 'module' });
        const reader = createFrameReader();
        const pending = new Map();
        let seq = 0;
        let ready = false;
        let dead = false;
        let bitmapOK = false;

        const die = (err) => {
            if (dead) return;
            dead = true;
            clearTimeout(timer);
            w.terminate();
            for (const done of pending.values()) done(null);
            pending.clear();
            if (ready) api.onDead?.(err);
            else reject(err);
        };
        const timer = setTimeout(() => die(new Error('worker init timeout')), INIT_TIMEOUT_MS);
        w.onerror = (e) => {
            e.preventDefault?.();
            die(new Error(e.message || 'worker error'));
        };
        w.onmessage = ({ data }) => {
            if (data.type === 'ready') {
                ready = true;
                bitmapOK = !!data.bitmap;
                clearTimeout(timer);
                resolve(api);
                return;
            }
            if (data.type === 'error' && data.init) return die(new Error(data.message));
            if (data.type === 'error') console.warn('[quickscan] worker:', data.message);
            const done = pending.get(data.seq);
            if (!done) return;
            pending.delete(data.seq);
            done(data.type === 'error' ? null : data);
        };

        const request = (msg, transfer) => new Promise((done) => {
            if (dead) return done(null);
            const s = ++seq;
            pending.set(s, done);
            w.postMessage({ ...msg, seq: s }, transfer);
        });

        const api = {
            kind: 'worker',
            quadEveryMs: 80,
            onDead: null,
            setPack(p) {
                const lo = p.lo.slice(), hi = p.hi.slice(), cl = p.cl.slice();
                w.postMessage({ type: 'pack', n: p.n, lo: lo.buffer, hi: hi.buffer, cl: cl.buffer }, [lo.buffer, hi.buffer, cl.buffer]);
            },
            setMeta(m) { if (!dead) w.postMessage({ type: 'meta', meta: m }); },
            setAllow(a) {
                if (dead) return;
                const buf = a ? a.slice().buffer : null;
                w.postMessage({ type: 'allow', allow: buf }, buf ? [buf] : []);
            },
            async scan(video, { reset = false } = {}) {
                if (dead || !video.videoWidth || video.readyState < 2) return null;
                const t0 = performance.now();
                let msg;
                let transfer;
                if (bitmapOK) {
                    const bitmap = await videoBitmap(video);
                    msg = { type: 'scan', bitmap, longSide: LONG, reset };
                    transfer = [bitmap];
                } else {
                    const image = reader.read(video, LONG);
                    if (!image) return null;
                    msg = { type: 'scan', image, reset };
                    transfer = [image.data.buffer];
                }
                const capture = performance.now() - t0;
                const r = await request(msg, transfer);
                return r ? { ...r.scan, ms: { ...r.scan.ms, capture } } : null;
            },
            async quad(img) {
                const r = await request({ type: 'quad', image: img }, [img.data.buffer]);
                return r ? { quad: r.quad, w: r.w, h: r.h } : null;
            },
            async scanImage(bitmap, { maxCards = 9, first } = {}) {
                if (dead) { bitmap.close(); return null; }
                if (bitmapOK) {
                    const r = await request({ type: 'image', bitmap, maxCards, first }, [bitmap]);
                    return r ? r.scan : null;
                }
                const image = bitmapRGBA(bitmap);
                const r = await request({ type: 'image', image, maxCards, first }, [image.data.buffer]);
                return r ? r.scan : null;
            },
            reset() { if (!dead) w.postMessage({ type: 'reset' }); },
            dispose() { ready = false; die(new Error('disposed')); },
        };

        w.postMessage({ type: 'init', map: importMap(), cvUrl: versioned(CV_SRC), staticBase: globalThis.NSP_STATIC || '' });
    });
}

async function mainBackend() {
    const [{ cvReady }, { createGrabber }, { createScanEngine }] = await Promise.all([
        import('../core/cv.js'),
        import('../core/frame.js'),
        import('./scan-engine.js'),
    ]);
    await cvReady(versioned(CV_SRC));
    const engine = createScanEngine();
    let grabber = null;
    let grabVideo = null;
    let pack = null;
    let meta = null;
    let allow = null;
    let imageScan = null;
    return {
        kind: 'main',
        quadEveryMs: 160,
        setPack: (p) => { pack = p; allow = null; engine.setPack(p); imageScan?.scanner.setPack(p); },
        setMeta: (m) => { meta = m; },
        setAllow: (a) => { allow = a; engine.setAllow(a); imageScan?.scanner.setAllow(a); },
        async scanImage(bitmap, { maxCards = 9, first } = {}) {
            const t0 = performance.now();
            const image = bitmapRGBA(bitmap);
            const read = performance.now() - t0;
            if (!imageScan) {
                const mod = await import('./image-scan.js');
                imageScan = { mod, scanner: mod.createImageScanner() };
                if (pack) imageScan.scanner.setPack(pack);
                if (allow) imageScan.scanner.setAllow(allow);
            }
            await new Promise((r) => setTimeout(r, 0));
            try {
                const out = imageScan.mod.scanImagePasses(imageScan.scanner, image, first ? { maxCards, first } : { maxCards });
                out.ms.read = read;
                if (meta) {
                    const t1 = performance.now();
                    try {
                        const { refineWithOcr } = await import('./image-ocr.js');
                        await refineWithOcr(out, image, meta, pack);
                    } catch (err) {
                        out.ocrError = String((err && err.message) || err);
                    }
                    out.ms.ocr = Math.round(performance.now() - t1);
                }
                return out;
            } catch (err) {
                console.warn('[quickscan] image scan failed:', err);
                return null;
            }
        },
        async scan(video, { reset = false } = {}) {
            if (!video.videoWidth || video.readyState < 2) return null;
            if (grabVideo !== video) {
                grabber?.dispose();
                grabber = createGrabber(video, { longSide: LONG, ring: 2 });
                grabVideo = video;
            }
            await new Promise((r) => setTimeout(r, 0));
            const t0 = performance.now();
            const f = grabber.grab();
            if (!f) return null;
            const capture = performance.now() - t0;
            try {
                const out = engine.scanMat(f.mat, { reset });
                out.ms.capture = capture;
                return out;
            } catch (err) {
                console.warn('[quickscan] scan failed:', err);
                return null;
            } finally {
                grabber.release(f);
            }
        },
        async quad(img) {
            try {
                return engine.quadRGBA(img);
            } catch (err) {
                console.warn('[quickscan] quad failed:', err);
                return null;
            }
        },
        reset: () => engine.reset(),
        dispose() {
            grabber?.dispose();
            grabber = null;
            grabVideo = null;
            engine.dispose();
            imageScan?.scanner.dispose();
        },
    };
}

// The 1080p camera frame is scaled to LONG while the bitmap is created (browser fast path) instead of in the
// worker; browsers without resize options return the full frame and the worker scales it as before.
let resizeOK = true;
async function videoBitmap(video) {
    const s = LONG / Math.max(video.videoWidth, video.videoHeight);
    if (resizeOK && s < 1) {
        try {
            return await createImageBitmap(video, {
                resizeWidth: Math.round(video.videoWidth * s), resizeHeight: Math.round(video.videoHeight * s), resizeQuality: 'high',
            });
        } catch {
            resizeOK = false;
        }
    }
    return createImageBitmap(video);
}

function bitmapRGBA(bitmap) {
    const { width: w, height: h } = bitmap;
    const canvas = typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(bitmap, 0, 0);
    bitmap.close();
    return ctx.getImageData(0, 0, w, h);
}
