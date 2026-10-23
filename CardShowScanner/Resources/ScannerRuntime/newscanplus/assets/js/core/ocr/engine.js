/**
 * engine.js - PP-OCR det on a collector corner, then PP-OCRv6-tiny rec.
 *
 * ONNX Runtime Web (WASM) is loaded from /newscanplus/assets/vendor/ort/ (or the static host, core/static.js).
 * Models are the fp32 files in /newscanplus/assets/vendor/ocr/ (int8 does not execute: no ConvInteger in ort-web 1.22).
 * Colour order into both models is BGR, matching the lab's OpenCV path (scripts/ocr/engines.py).
 *
 * Works in the desktop worker and on the main thread. The worker's module-graph rewrites static
 * imports onto blob: URLs, so runtime assets are absolute paths in the browser and file URLs in
 * Node. Call loadOcr after core/cv.js setCv(); detection uses that OpenCV for contours and warps.
 *
 * loadOcr({threads=1}) -> {threads, charsetLength, detBytes, recBytes}
 *   Thread count is fixed for the life of the JS realm (WASM initialises once).
 * recognizeCorner(image, game) -> {text, number, conf, ms, nDet, skipped?}
 *   image: {data, width, height, channels?} RGBA (4) or RGB (3). game: layout key or tcgp:N.
 *   number is canonNumber (layouts.js). conf is the mean CTC peak of the line that produced it.
 *   skipped when the game has no OCR layout (generic, yugioh).
 */
import { cv } from '../cv.js';
import { cropPixels, layoutFor, parseNumber, numberExact } from './layouts.js';
import { staticUrl } from '../static.js';

const PUBLIC = '/newscanplus/assets/vendor/';
const DET_NAME = 'ocr/ppocr_det.onnx';
const REC_NAME = 'ocr/ppocr_rec_tiny.onnx';

let runtime = null;
let loading = null;

function isNode() {
    return typeof process !== 'undefined' && process.release?.name === 'node';
}

function vendorFile(rel) {
    return new URL('../../../vendor/' + rel, import.meta.url);
}

let nodeOrtDir = null;

async function importOrt() {
    if (isNode()) {
        // The browser WASM bundle starts threaded workers from a blob: URL, which Node cannot import.
        // The node entry of the same package uses worker_threads and reads the wasm file from disk.
        const { createRequire } = await import('node:module');
        const { pathToFileURL } = await import('node:url');
        const require = createRequire('/home/master/newscanplus-lab/node_modules/jpeg-js/package.json');
        const dir = new URL('./', pathToFileURL(require.resolve('onnxruntime-web')));
        nodeOrtDir = dir;
        return import(new URL('ort.node.min.mjs', dir).href);
    }
    // Absolute: in the desktop worker this module runs from a blob: URL, which cannot resolve '/newscanplus/...'.
    return import(new URL(staticUrl(PUBLIC + 'ort/ort.wasm.min.js'), self.location.origin).href);
}

function wasmPaths() {
    if (isNode() && nodeOrtDir) {
        return {
            mjs: new URL('ort-wasm-simd-threaded.mjs', nodeOrtDir).href,
            wasm: new URL('ort-wasm-simd-threaded.wasm', nodeOrtDir).href,
        };
    }
    const origin = (typeof self !== 'undefined' && self.location && self.location.origin) || '';
    const abs = (rel) => (origin ? new URL(staticUrl(PUBLIC + rel), origin).href : staticUrl(PUBLIC + rel));
    return {
        mjs: abs('ort/ort-wasm-simd-threaded.js'),
        wasm: abs('ort/ort-wasm-simd-threaded.wasm'),
    };
}

async function modelBytes(rel) {
    if (isNode()) {
        const { readFile } = await import('node:fs/promises');
        const { fileURLToPath } = await import('node:url');
        return new Uint8Array(await readFile(fileURLToPath(vendorFile(rel))));
    }
    const res = await fetch(new URL(staticUrl(PUBLIC + rel), self.location.origin).href);
    if (!res.ok) throw new Error(`OCR model ${rel} HTTP ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
}

function charsetFromOnnx(u8) {
    const key = [0x0a, 0x09, 0x63, 0x68, 0x61, 0x72, 0x61, 0x63, 0x74, 0x65, 0x72];
    let idx = -1;
    for (let i = 0; i + key.length < u8.length; i++) {
        let ok = true;
        for (let k = 0; k < key.length; k++) if (u8[i + k] !== key[k]) { ok = false; break; }
        if (ok) { idx = i; break; }
    }
    if (idx < 0) throw new Error('PP-OCR rec model has no character list');
    let p = idx + key.length;
    if (u8[p++] !== 0x12) throw new Error('PP-OCR charset field missing');
    let len = 0, shift = 0;
    for (;;) {
        const b = u8[p++];
        len |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7;
    }
    const lines = new TextDecoder().decode(u8.subarray(p, p + len)).split('\n');
    if (lines.length && lines[lines.length - 1] === '') lines.pop();
    if (lines.length < 100) throw new Error('PP-OCR charset too short');
    return lines;
}

export async function loadOcr(opts = {}) {
    const threads = opts.threads ?? 1;
    if (runtime) {
        if (opts.threads != null && runtime.threads !== opts.threads) {
            throw new Error(`OCR already loaded with ${runtime.threads} thread(s); start a fresh worker to change it`);
        }
        return runtime.info;
    }
    if (!loading) {
        loading = (async () => {
            const ort = await importOrt();
            ort.env.logLevel = 'error';
            ort.env.wasm.numThreads = threads;
            ort.env.wasm.wasmPaths = wasmPaths();
            const detBytes = await modelBytes(DET_NAME);
            const recBytes = await modelBytes(REC_NAME);
            const opts = { executionProviders: ['wasm'] };
            const det = await ort.InferenceSession.create(detBytes, opts);
            const rec = await ort.InferenceSession.create(recBytes, opts);
            const charset = charsetFromOnnx(recBytes);
            runtime = {
                ort, det, rec, charset,
                threads: ort.env.wasm.numThreads,
                info: {
                    threads: ort.env.wasm.numThreads,
                    charsetLength: charset.length,
                    detBytes: detBytes.byteLength,
                    recBytes: recBytes.byteLength,
                },
            };
            return runtime.info;
        })().catch((err) => { loading = null; throw err; });
    }
    return loading;
}

function channelsOf(img) {
    if (img.channels) return img.channels;
    return (img.data.length / (img.width * img.height)) | 0;
}

function toBGR(img) {
    const w = img.width, h = img.height, ch = channelsOf(img);
    const src = img.data;
    const out = new Uint8Array(w * h * 3);
    for (let i = 0, p = 0; i < w * h; i++, p += ch) {
        out[i * 3] = src[p + 2];
        out[i * 3 + 1] = src[p + 1];
        out[i * 3 + 2] = src[p];
    }
    return out;
}

function drop(mats) {
    for (const m of mats) {
        try { m && m.delete && m.delete(); } catch { /* already gone */ }
    }
}

function detSize(w, h) {
    const limit = 96;
    let ratio = 1;
    if (Math.min(h, w) < limit) ratio = (h < w ? limit / h : limit / w);
    let rw = Math.round((w * ratio) / 32) * 32;
    let rh = Math.round((h * ratio) / 32) * 32;
    if (rw < 32) rw = 32;
    if (rh < 32) rh = 32;
    return { rw, rh };
}

function pointInPoly(x, y, poly) {
    let inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        const xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1];
        if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / ((yj - yi) || 1e-9) + xi) inside = !inside;
    }
    return inside;
}

function boxScore(map, mw, pts) {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const [x, y] of pts) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
    }
    const mh = map.length / mw;
    const x0 = Math.max(0, Math.floor(minX));
    const y0 = Math.max(0, Math.floor(minY));
    const x1 = Math.min(mw - 1, Math.ceil(maxX));
    const y1 = Math.min(mh - 1, Math.ceil(maxY));
    if (x1 < x0 || y1 < y0) return 0;
    const poly = pts.map(([x, y]) => [x - x0, y - y0]);
    let sum = 0, n = 0;
    for (let y = y0; y <= y1; y++) {
        for (let x = x0; x <= x1; x++) {
            if (!pointInPoly(x + 0.5 - x0, y + 0.5 - y0, poly)) continue;
            sum += map[y * mw + x];
            n++;
        }
    }
    return n ? sum / n : 0;
}

function shoelace(pts) {
    let s = 0;
    for (let i = 0; i < pts.length; i++) {
        const j = (i + 1) % pts.length;
        s += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1];
    }
    return s;
}

function unclip(pts, ratio) {
    const area = Math.abs(shoelace(pts)) / 2;
    let peri = 0;
    for (let i = 0; i < pts.length; i++) {
        const j = (i + 1) % pts.length;
        peri += Math.hypot(pts[j][0] - pts[i][0], pts[j][1] - pts[i][1]);
    }
    if (peri < 1e-3) return pts;
    const dist = (area * ratio) / peri;
    const sign = shoelace(pts) >= 0 ? 1 : -1;
    const lines = pts.map((a, i) => {
        const b = pts[(i + 1) % pts.length];
        const dx = b[0] - a[0], dy = b[1] - a[1];
        const len = Math.hypot(dx, dy) || 1;
        const nx = (sign * dy) / len, ny = (sign * -dx) / len;
        const px = a[0] + nx * dist, py = a[1] + ny * dist;
        return { nx, ny, c: nx * px + ny * py };
    });
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        const L1 = lines[(i + lines.length - 1) % lines.length];
        const L2 = lines[i];
        const det = L1.nx * L2.ny - L2.nx * L1.ny;
        if (Math.abs(det) < 1e-6) continue;
        out.push([(L1.c * L2.ny - L2.c * L1.ny) / det, (L1.nx * L2.c - L2.nx * L1.c) / det]);
    }
    return out.length >= 3 ? out : pts;
}

function orderClockwise(pts) {
    const s = pts.map((p) => [p[0], p[1]]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    if (s.length < 4) return s;
    const left = s.slice(0, 2).sort((a, b) => a[1] - b[1]);
    const right = s.slice(-2).sort((a, b) => a[1] - b[1]);
    return [left[0], right[0], right[1], left[1]];
}

function rectPoints(rect) {
    return cv.RotatedRect.points(rect).map((p) => [p.x, p.y]);
}

function dist(a, b) {
    return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

function rot90(bgr, w, h) {
    const out = new Uint8Array(w * h * 3);
    for (let r = 0; r < w; r++) {
        for (let c = 0; c < h; c++) {
            const s = (c * w + (w - 1 - r)) * 3;
            const d = (r * h + c) * 3;
            out[d] = bgr[s];
            out[d + 1] = bgr[s + 1];
            out[d + 2] = bgr[s + 2];
        }
    }
    return { data: out, width: h, height: w };
}

function detectLines(bgr, w, h) {
    const { rw, rh } = detSize(w, h);
    const owned = [];
    const src = new cv.Mat(h, w, cv.CV_8UC3);
    owned.push(src);
    src.data.set(bgr);
    const resized = new cv.Mat();
    owned.push(resized);
    cv.resize(src, resized, new cv.Size(rw, rh), 0, 0, cv.INTER_LINEAR);
    const plane = rw * rh;
    const input = new Float32Array(3 * plane);
    const px = resized.data;
    for (let i = 0; i < plane; i++) {
        input[i] = (px[i * 3] / 255 - 0.5) / 0.5;
        input[plane + i] = (px[i * 3 + 1] / 255 - 0.5) / 0.5;
        input[2 * plane + i] = (px[i * 3 + 2] / 255 - 0.5) / 0.5;
    }
    return { input, rw, rh, owned, src };
}

async function boxesFromMap(map, mw, mh, srcW, srcH) {
    const bin = new cv.Mat(mh, mw, cv.CV_8UC1);
    const dil = new cv.Mat();
    const kernel = new cv.Mat(2, 2, cv.CV_8UC1);
    const contours = new cv.MatVector();
    const hier = new cv.Mat();
    const scratch = [];
    try {
        kernel.data.set([1, 1, 1, 1]);
        for (let i = 0; i < mw * mh; i++) bin.data[i] = map[i] > 0.3 ? 255 : 0;
        cv.dilate(bin, dil, kernel);
        cv.findContours(dil, contours, hier, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
        const found = [];
        const n = Math.min(contours.size(), 64);
        for (let i = 0; i < n; i++) {
            const c = contours.get(i);
            scratch.push(c);
            if (c.rows < 3) continue;
            const rect = cv.minAreaRect(c);
            const side = Math.min(rect.size.width, rect.size.height);
            if (side < 3) continue;
            const pts = rectPoints(rect);
            const score = boxScore(map, mw, pts);
            if (score < 0.5) continue;
            const grown = unclip(pts, 1.6);
            const gm = cv.matFromArray(grown.length, 1, cv.CV_32FC2, grown.flat());
            scratch.push(gm);
            const rect2 = cv.minAreaRect(gm);
            if (Math.min(rect2.size.width, rect2.size.height) < 5) continue;
            const box = orderClockwise(rectPoints(rect2)).map(([x, y]) => [
                Math.max(0, Math.min(srcW - 1, Math.round((x / mw) * srcW))),
                Math.max(0, Math.min(srcH - 1, Math.round((y / mh) * srcH))),
            ]);
            const bw = Math.hypot(box[0][0] - box[1][0], box[0][1] - box[1][1]);
            const bh = Math.hypot(box[0][0] - box[3][0], box[0][1] - box[3][1]);
            if (bw <= 3 || bh <= 3) continue;
            const cy = (box[0][1] + box[1][1] + box[2][1] + box[3][1]) / 4;
            found.push({ box, cy, score });
        }
        found.sort((a, b) => a.cy - b.cy);
        return found.length > 3 ? found.slice(-3) : found;
    } finally {
        drop([bin, dil, kernel, hier, ...scratch]);
        contours.delete();
    }
}

function warpBox(src, box) {
    const cw = Math.max(2, Math.round(Math.max(dist(box[0], box[1]), dist(box[2], box[3]))));
    const ch = Math.max(2, Math.round(Math.max(dist(box[0], box[3]), dist(box[1], box[2]))));
    const sp = cv.matFromArray(4, 1, cv.CV_32FC2, box.flat());
    const dp = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, cw, 0, cw, ch, 0, ch]);
    const M = cv.getPerspectiveTransform(sp, dp);
    const dst = new cv.Mat();
    try {
        cv.warpPerspective(src, dst, M, new cv.Size(cw, ch), cv.INTER_CUBIC, cv.BORDER_REPLICATE, new cv.Scalar());
        const data = new Uint8Array(dst.data);
        if (ch * 1.0 / cw >= 1.5) return rot90(data, cw, ch);
        return { data, width: cw, height: ch };
    } finally {
        drop([sp, dp, M, dst]);
    }
}

function lumaMean(bgr, w, h) {
    let s = 0;
    for (let i = 0; i < w * h; i++) {
        const b = bgr[i * 3], g = bgr[i * 3 + 1], r = bgr[i * 3 + 2];
        s += 0.299 * r + 0.587 * g + 0.114 * b;
    }
    return s / (w * h);
}

function prepLine(line) {
    let { data, width, height } = line;
    if (lumaMean(data, width, height) < 118) {
        const inv = new Uint8Array(data.length);
        for (let i = 0; i < data.length; i++) inv[i] = 255 - data[i];
        data = inv;
    }
    let rw = Math.max(8, Math.ceil(48 * (width / Math.max(1, height))));
    if (rw > 1280) rw = 1280;
    const src = new cv.Mat(height, width, cv.CV_8UC3);
    const dst = new cv.Mat();
    try {
        src.data.set(data);
        cv.resize(src, dst, new cv.Size(rw, 48), 0, 0, cv.INTER_LINEAR);
        return { data: new Uint8Array(dst.data), width: rw, height: 48 };
    } finally {
        drop([src, dst]);
    }
}

function ctcDecode(logits, T, C, charset) {
    const chars = C >= charset.length + 2 ? charset.concat([' ']) : charset;
    // PP-OCRv6 tiny already returns probabilities. Softmax of those is almost uniform.
    let peekSum = 0, peekMax = -Infinity;
    for (let c = 0; c < C; c++) {
        const v = logits[c];
        if (v > peekMax) peekMax = v;
        peekSum += v;
    }
    const ready = peekMax <= 1.01 && peekSum > 0.5 && peekSum < 1.5;
    let prev = -1, text = '', conf = 0, n = 0;
    const row = ready ? null : new Float64Array(C);
    for (let t = 0; t < T; t++) {
        const base = t * C;
        let best = 0, bestP = -1;
        if (ready) {
            for (let c = 0; c < C; c++) {
                const p = logits[base + c];
                if (p > bestP) { bestP = p; best = c; }
            }
        } else {
            let m = -Infinity;
            for (let c = 0; c < C; c++) if (logits[base + c] > m) m = logits[base + c];
            let sum = 0;
            for (let c = 0; c < C; c++) { row[c] = Math.exp(logits[base + c] - m); sum += row[c]; }
            for (let c = 0; c < C; c++) {
                const p = row[c] / sum;
                if (p > bestP) { bestP = p; best = c; }
            }
        }
        if (best !== 0 && best !== prev) {
            const ch = chars[best - 1];
            if (ch && ch !== 'blank') text += ch;
            conf += bestP;
            n++;
        }
        prev = best;
    }
    return { text, conf: n ? conf / n : 0 };
}

async function recognizeLines(lines) {
    if (!lines.length) return [];
    const prepped = lines.map(prepLine).filter((l) => l.width >= 2 && l.height >= 2);
    if (!prepped.length) return [];
    let maxW = 0;
    for (const l of prepped) if (l.width > maxW) maxW = l.width;
    if (maxW % 8) maxW += 8 - (maxW % 8);
    const n = prepped.length;
    const batch = new Float32Array(n * 3 * 48 * maxW);
    for (let i = 0; i < n; i++) {
        const { data, width } = prepped[i];
        for (let y = 0; y < 48; y++) {
            for (let x = 0; x < width; x++) {
                const p = (y * width + x) * 3;
                for (let c = 0; c < 3; c++) {
                    batch[((i * 3 + c) * 48 + y) * maxW + x] = (data[p + c] / 255 - 0.5) / 0.5;
                }
            }
        }
    }
    const { ort, rec, charset } = runtime;
    const tensor = new ort.Tensor('float32', batch, [n, 3, 48, maxW]);
    const out = await rec.run({ [rec.inputNames[0]]: tensor });
    const pred = out[rec.outputNames[0]];
    const dims = pred.dims;
    const logits = pred.data;
    const linesOut = [];
    if (dims[0] === n) {
        const T = dims[1], C = dims[2];
        for (let i = 0; i < n; i++) linesOut.push(ctcDecode(logits.subarray(i * T * C, (i + 1) * T * C), T, C, charset));
    } else if (dims.length === 3 && dims[1] === n) {
        const T = dims[0], C = dims[2];
        for (let i = 0; i < n; i++) {
            const slice = new Float32Array(T * C);
            for (let t = 0; t < T; t++) slice.set(logits.subarray((t * n + i) * C, (t * n + i + 1) * C), t * C);
            linesOut.push(ctcDecode(slice, T, C, charset));
        }
    } else {
        linesOut.push(ctcDecode(logits, dims[dims.length - 2], dims[dims.length - 1], charset));
    }
    return linesOut;
}

export async function recognizeCorner(image, game) {
    const layout = layoutFor(game);
    if (!layout || !layout.ocr) return { text: '', number: '', conf: 0, ms: 0, nDet: 0, skipped: true };
    await loadOcr();
    if (!cv) throw new Error('OpenCV is not ready (setCv before recognizeCorner)');
    const t0 = performance.now();
    const w = image.width, h = image.height;
    const bgr = toBGR(image);
    const prep = detectLines(bgr, w, h);
    let crops = [];
    let nDet = 0;
    try {
        const { ort, det } = runtime;
        const tensor = new ort.Tensor('float32', prep.input, [1, 3, prep.rh, prep.rw]);
        const out = await det.run({ [det.inputNames[0]]: tensor });
        const pred = out[det.outputNames[0]];
        const mh = pred.dims[pred.dims.length - 2];
        const mw = pred.dims[pred.dims.length - 1];
        const boxes = await boxesFromMap(pred.data, mw, mh, w, h);
        nDet = boxes.length;
        for (const b of boxes) {
            const crop = warpBox(prep.src, b.box);
            if (crop && crop.width >= 2 && crop.height >= 2) crops.push(crop);
        }
    } finally {
        drop(prep.owned);
    }
    if (!crops.length) crops = [{ data: bgr, width: w, height: h }];
    const recs = await recognizeLines(crops);
    const text = recs.map((r) => r.text).filter((t) => t && t.trim()).join('\n');
    const number = parseNumber(text, layout);
    let conf = 0;
    if (number) {
        const hit = recs.filter((r) => numberExact(r.text, number));
        const used = hit.length ? hit : recs;
        conf = used.reduce((s, r) => s + r.conf, 0) / used.length;
    }
    return { text, number, conf, ms: performance.now() - t0, nDet, skipped: false };
}

export async function recognizeCard(card, game) {
    const layout = layoutFor(game);
    if (!layout || !layout.ocr) return recognizeCorner(card, game);
    return recognizeCorner(cropPixels(card, layout.region), game);
}
