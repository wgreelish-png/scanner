/**
 * quickscan-worker.js - module worker for the phone quick scan: holds OpenCV + the game's hash pack and runs
 * scan-engine.js off the main thread. Messages are handled strictly in arrival order.
 *
 *   {type:'init', map, cvUrl, staticBase}              -> {type:'ready', bitmap}   bitmap: OffscreenCanvas 2D usable;
 *                                                         staticBase becomes self.NSP_STATIC (core/static.js)
 *   {type:'pack', n, lo, hi, cl}                       (ArrayBuffers transferred; no reply)
 *   {type:'scan', seq, bitmap | image, longSide, reset} -> {type:'scan', seq, scan}  bitmap is closed here
 *   {type:'quad', seq, image}                          -> {type:'quad', seq, quad, w, h}
 *   {type:'reset'}
 *   {type:'image', seq, bitmap | image, maxCards}      -> {type:'image', seq, scan}  still image (desktop upload):
 *                                                         image-scan.js scanImagePasses; bitmap is closed here
 *   {type:'meta', meta}                                (desktop only) per-index refs/numbers enabling the
 *                                                         collector-corner OCR tie-break on 'image' scans; null = off
 *   {type:'allow', allow}                              (desktop only) Uint8Array(n) buffer or null: set lock /
 *                                                         exclusions for 'image' scans; reset by 'pack'
 *   failure                                            -> {type:'error', seq, message}
 * image = {data: Uint8ClampedArray RGBA, width, height}. No static imports: everything after init is loaded
 * through module-graph.js with the page's versioned URLs (see that file for why).
 */
const BASE = '/newscanplus/assets/js/';
let engine = null;
let canvas = null;
let ctx = null;
let chain = Promise.resolve();
let load = null;
let pack = null;
let imageScan = null;
let meta = null;
let ocr = null;
let allow = null;

self.onmessage = (e) => {
    const msg = e.data || {};
    chain = chain
        .then(() => handle(msg))
        .then((reply) => reply && self.postMessage(reply))
        .catch((err) => {
            if (msg.bitmap) msg.bitmap.close();
            self.postMessage({ type: 'error', seq: msg.seq, init: msg.type === 'init', message: String((err && err.message) || err) });
        });
};

async function handle(msg) {
    switch (msg.type) {
        case 'init': return init(msg);
        case 'pack':
            pack = { n: msg.n, lo: new Uint32Array(msg.lo), hi: new Uint8Array(msg.hi), cl: new Int32Array(msg.cl) };
            allow = null;
            engine.setPack(pack);
            imageScan?.scanner.setPack(pack);
            return null;
        case 'image': return scanImage(msg);
        case 'meta': meta = msg.meta || null; return null;
        case 'allow':
            allow = msg.allow ? new Uint8Array(msg.allow) : null;
            engine.setAllow(allow);
            imageScan?.scanner.setAllow(allow);
            return null;
        case 'reset': engine.reset(); return null;
        case 'quad': return { type: 'quad', seq: msg.seq, ...engine.quadRGBA(msg.image) };
        case 'scan': return scan(msg);
        default: return null;
    }
}

async function init({ map, cvUrl, staticBase }) {
    self.NSP_STATIC = staticBase || '';
    const graph = BASE + 'app/module-graph.js';
    const { createModuleLoader } = await import(new URL(map[graph] || graph, self.location.origin).href);
    load = createModuleLoader(map);
    const res = await fetch(cvUrl);
    if (!res.ok) throw new Error(`opencv.js HTTP ${res.status}`);
    // Module workers cannot importScripts(); OpenCV's UMD wrapper assigns self.cv under indirect eval.
    (0, eval)(await res.text());
    const cvMod = await load(BASE + 'core/cv.js');
    cvMod.setCv(await cvMod.settle(self.cv));
    const { createScanEngine } = await load(BASE + 'app/scan-engine.js');
    engine = createScanEngine();
    return { type: 'ready', bitmap: canDraw() };
}

function canDraw() {
    try {
        return typeof OffscreenCanvas === 'function' && !!new OffscreenCanvas(1, 1).getContext('2d');
    } catch {
        return false;
    }
}

function bitmapToImage(bitmap, longSide) {
    const s = Math.min(1, longSide / Math.max(bitmap.width, bitmap.height));
    const w = Math.round(bitmap.width * s);
    const h = Math.round(bitmap.height * s);
    if (!canvas || canvas.width !== w || canvas.height !== h) {
        canvas = new OffscreenCanvas(w, h);
        ctx = canvas.getContext('2d', { willReadFrequently: true });
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
    }
    ctx.drawImage(bitmap, 0, 0, w, h);
    bitmap.close();
    return ctx.getImageData(0, 0, w, h);
}

function scan(msg) {
    const t0 = performance.now();
    const image = msg.bitmap ? bitmapToImage(msg.bitmap, msg.longSide || 1280) : msg.image;
    const read = performance.now() - t0;
    const out = engine.scanRGBA(image, { reset: !!msg.reset });
    out.ms.read = read;
    return { type: 'scan', seq: msg.seq, scan: out };
}

async function scanImage(msg) {
    if (!imageScan) {
        const mod = await load(BASE + 'app/image-scan.js');
        imageScan = { mod, scanner: mod.createImageScanner() };
        if (pack) imageScan.scanner.setPack(pack);
        if (allow) imageScan.scanner.setAllow(allow);
    }
    const t0 = performance.now();
    let image = msg.image;
    if (msg.bitmap) {
        const { width: w, height: h } = msg.bitmap;
        const c = new OffscreenCanvas(w, h).getContext('2d', { willReadFrequently: true });
        c.drawImage(msg.bitmap, 0, 0);
        msg.bitmap.close();
        image = c.getImageData(0, 0, w, h);
    }
    const read = performance.now() - t0;
    const out = imageScan.mod.scanImagePasses(imageScan.scanner, image, msg.first ? { maxCards: msg.maxCards || 9, first: msg.first } : { maxCards: msg.maxCards || 9 });
    out.ms.read = read;
    if (meta) {
        const t1 = performance.now();
        try {
            ocr ||= await load(BASE + 'app/image-ocr.js');
            await ocr.refineWithOcr(out, image, meta, pack);
        } catch (err) {
            out.ocrError = String((err && err.message) || err);
        }
        out.ms.ocr = Math.round(performance.now() - t1);
    }
    return { type: 'image', seq: msg.seq, scan: out };
}
