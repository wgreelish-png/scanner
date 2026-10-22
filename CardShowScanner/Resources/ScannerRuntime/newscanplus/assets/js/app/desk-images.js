/**
 * desk-images.js - desktop upload intake: which files we can read, decode to an oriented bitmap, thumbnails.
 *
 * fileVerdict(file) -> {ok: true} | {ok: false, reason}   by MIME type, falling back to the extension
 *   HEIC/HEIF and TIFF are refused with a hint (Chrome/Edge/Firefox cannot decode them); non-images are refused.
 * isImageName(name) -> boolean    names the watch folder should look at (includes HEIC/TIFF so they get a message)
 * decodeUpload(file, {maxLong=2048}) -> Promise<ImageBitmap>
 *   EXIF orientation applied (imageOrientation 'from-image'); larger images are scaled down to maxLong.
 * thumbUrl({data, width, height}, quality=0.85) -> string   JPEG data URL of an RGBA buffer ('' without canvas)
 * cropPhotos(bitmap, scan, {long=640, maxBytes=90000}) -> string[]
 *   One JPEG data URL per scan card: the card's bounding box (whole image when card.full) cut from the decoded
 *   upload (scan.w/h may be a smaller copy of it), long edge <= `long`. '' when the browser cannot paint a canvas.
 * quadPoint(quad, u, v) -> [x, y] | null
 *   Perspective map of the unit square onto a card-order quad (TL, TR, BR, BL). (0,0) is the matched top-left.
 * quadJpeg(video, quad, frameW, frameH, maxBytes=90000) -> string
 *   JPEG of the card straightened to the orientation that matched: the quad (scan-frame pixels, card order)
 *   is perspective-warped onto a portrait card, same long edge and byte budget as a desktop upload crop.
 *   '' without videoWidth/videoHeight, a frame size, a quad, or document. maxBytes <= 20480 uses a short ladder.
 * shrinkBitmap(bitmap, maxLong) -> Promise<ImageBitmap>   resized (or copied) bitmap; the source stays open
 */
const OK_TYPES = /^image\/(jpeg|png|webp|gif|bmp|avif)$/;
const OK_EXT = /\.(jpe?g|jfif|png|webp|gif|bmp|avif)$/i;
const HEIC = /\.(heic|heif)$/i;
const TIFF = /\.tiff?$/i;

export function isImageName(name) {
    return OK_EXT.test(name) || HEIC.test(name) || TIFF.test(name);
}

export function fileVerdict(file) {
    const type = (file.type || '').toLowerCase();
    const name = file.name || '';
    if (type === 'image/heic' || type === 'image/heif' || HEIC.test(name)) return { ok: false, reason: 'HEIC not supported' };
    if (type === 'image/tiff' || TIFF.test(name)) return { ok: false, reason: 'TIFF not supported' };
    if (OK_TYPES.test(type) || OK_EXT.test(name)) return { ok: true };
    return { ok: false, reason: 'Not an image file' };
}

export async function decodeUpload(file, { maxLong = 2048 } = {}) {
    let bitmap;
    try {
        bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
    } catch {
        throw new Error('could not decode this image');
    }
    const long = Math.max(bitmap.width, bitmap.height);
    if (long <= maxLong) return bitmap;
    const s = maxLong / long;
    try {
        return await createImageBitmap(bitmap, {
            resizeWidth: Math.round(bitmap.width * s),
            resizeHeight: Math.round(bitmap.height * s),
            resizeQuality: 'high',
        });
    } finally {
        bitmap.close();
    }
}

export function cropPhotos(bitmap, scan, { long = 640, maxBytes = 90000 } = {}) {
    const cards = scan?.cards || [];
    if (!bitmap || bitmap.closed || !cards.length || typeof document === 'undefined') return cards.map(() => '');
    const fx = scan.w ? bitmap.width / scan.w : 1;
    const fy = scan.h ? bitmap.height / scan.h : 1;
    return cards.map((card) => {
        let x0 = 0, y0 = 0, x1 = bitmap.width, y1 = bitmap.height;
        if (!card.full && card.quad?.length) {
            const xs = card.quad.map((p) => p[0] * fx), ys = card.quad.map((p) => p[1] * fy);
            x0 = Math.max(0, Math.floor(Math.min(...xs)));
            y0 = Math.max(0, Math.floor(Math.min(...ys)));
            x1 = Math.min(bitmap.width, Math.ceil(Math.max(...xs)));
            y1 = Math.min(bitmap.height, Math.ceil(Math.max(...ys)));
        }
        return cropJpeg(bitmap, x0, y0, x1 - x0, y1 - y0, long, maxBytes);
    });
}

/** New bitmap with the long side <= maxLong (a plain copy when already small enough). The source stays open. */
export function shrinkBitmap(bitmap, maxLong) {
    const long = Math.max(bitmap.width, bitmap.height);
    if (long <= maxLong) return createImageBitmap(bitmap);
    const s = maxLong / long;
    return createImageBitmap(bitmap, {
        resizeWidth: Math.round(bitmap.width * s),
        resizeHeight: Math.round(bitmap.height * s),
        resizeQuality: 'high',
    });
}

/** Phone inbox thumbs must stay under NSP_DESK_THUMB_MAX. Desktop uploads pass a larger maxBytes. */
const PHONE_THUMB_MAX = 20480;
/** Preview aspect matches core/warp.js (200x280). Long edge matches a desktop upload crop. */
const PREVIEW_LONG = 640;
const PREVIEW_W = Math.round(PREVIEW_LONG * 200 / 280);
const WARP_GRID = 8;

// Unit square (0,0)=TL (1,0)=TR (1,1)=BR (0,1)=BL onto a card-order quad. Null when the quad is degenerate.
function unitHomography(quad) {
    const [x0, y0] = quad[0], [x1, y1] = quad[1], [x2, y2] = quad[2], [x3, y3] = quad[3];
    const dx1 = x1 - x2, dy1 = y1 - y2, dx2 = x3 - x2, dy2 = y3 - y2;
    const dx3 = x0 - x1 + x2 - x3, dy3 = y0 - y1 + y2 - y3;
    const den = dx1 * dy2 - dx2 * dy1;
    if (!den) return null;
    const g = (dx3 * dy2 - dx2 * dy3) / den;
    const h = (dx1 * dy3 - dx3 * dy1) / den;
    return {
        a: x1 - x0 + g * x1, c: x3 - x0 + h * x3, e: x0,
        b: y1 - y0 + g * y1, d: y3 - y0 + h * y3, f: y0,
        g, h,
    };
}

function applyH(H, u, v) {
    const w = H.g * u + H.h * v + 1;
    if (!w) return null;
    return [(H.a * u + H.c * v + H.e) / w, (H.b * u + H.d * v + H.f) / w];
}

/** Where unit-square (u, v) lands on the quad. Null when the quad cannot be a perspective. */
export function quadPoint(quad, u, v) {
    if (!quad || quad.length < 4) return null;
    const H = unitHomography(quad);
    return H ? applyH(H, u, v) : null;
}

// Affine that maps the three source points onto the three destination points. ctx.transform(a, b, c, d, e, f).
function affineOf(s0, s1, s2, d0, d1, d2) {
    const den = s0[0] * (s1[1] - s2[1]) + s1[0] * (s2[1] - s0[1]) + s2[0] * (s0[1] - s1[1]);
    if (!den) return null;
    const coeff = (p0, p1, p2) => [
        (p0 * (s1[1] - s2[1]) + p1 * (s2[1] - s0[1]) + p2 * (s0[1] - s1[1])) / den,
        (p0 * (s2[0] - s1[0]) + p1 * (s0[0] - s2[0]) + p2 * (s1[0] - s0[0])) / den,
        (p0 * (s1[0] * s2[1] - s2[0] * s1[1]) + p1 * (s2[0] * s0[1] - s0[0] * s2[1]) + p2 * (s0[0] * s1[1] - s1[0] * s0[1])) / den,
    ];
    const x = coeff(d0[0], d1[0], d2[0]);
    const y = coeff(d0[1], d1[1], d2[1]);
    return [x[0], y[0], x[1], y[1], x[2], y[2]];
}

function growTri(tri, px) {
    const c = [(tri[0][0] + tri[1][0] + tri[2][0]) / 3, (tri[0][1] + tri[1][1] + tri[2][1]) / 3];
    return tri.map(([x, y]) => {
        const dx = x - c[0], dy = y - c[1], len = Math.hypot(dx, dy) || 1;
        return [x + (dx / len) * px, y + (dy / len) * px];
    });
}

function paintTri(ctx, image, src, dst) {
    const m = affineOf(src[0], src[1], src[2], dst[0], dst[1], dst[2]);
    if (!m) return;
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(dst[0][0], dst[0][1]);
    ctx.lineTo(dst[1][0], dst[1][1]);
    ctx.lineTo(dst[2][0], dst[2][1]);
    ctx.closePath();
    ctx.clip();
    ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]);
    ctx.drawImage(image, 0, 0);
    ctx.restore();
}

// Perspective-warp image so quad (card order, image pixels) fills a dw×dh portrait. False when it cannot.
function paintWarp(ctx, image, quad, dw, dh) {
    const H = unitHomography(quad);
    if (!H) return false;
    const n = WARP_GRID;
    for (let j = 0; j < n; j++) {
        for (let i = 0; i < n; i++) {
            const u0 = i / n, u1 = (i + 1) / n, v0 = j / n, v1 = (j + 1) / n;
            const s00 = applyH(H, u0, v0), s10 = applyH(H, u1, v0), s11 = applyH(H, u1, v1), s01 = applyH(H, u0, v1);
            if (!s00 || !s10 || !s11 || !s01) return false;
            const d00 = [u0 * dw, v0 * dh], d10 = [u1 * dw, v0 * dh], d11 = [u1 * dw, v1 * dh], d01 = [u0 * dw, v1 * dh];
            paintTri(ctx, image, [s00, s10, s11], growTri([d00, d10, d11], 0.6));
            paintTri(ctx, image, [s00, s11, s01], growTri([d00, d11, d01], 0.6));
        }
    }
    return true;
}

export function quadJpeg(video, quad, frameW, frameH, maxBytes = 90000) {
    const vw = video?.videoWidth | 0;
    const vh = video?.videoHeight | 0;
    if (!vw || !vh || !(frameW > 0) || !(frameH > 0) || quad?.length !== 4 || typeof document === 'undefined') return '';
    const fx = vw / frameW;
    const fy = vh / frameH;
    const src = quad.map(([x, y]) => [x * fx, y * fy]);
    const warped = warpJpeg(video, src, PREVIEW_W, PREVIEW_LONG, maxBytes);
    if (warped) return warped;
    const xs = src.map((p) => p[0]), ys = src.map((p) => p[1]);
    const x0 = Math.max(0, Math.floor(Math.min(...xs)));
    const y0 = Math.max(0, Math.floor(Math.min(...ys)));
    const x1 = Math.min(vw, Math.ceil(Math.max(...xs)));
    const y1 = Math.min(vh, Math.ceil(Math.max(...ys)));
    return cropJpeg(video, x0, y0, x1 - x0, y1 - y0, PREVIEW_LONG, maxBytes);
}

// One draw of the camera frame, then a mesh warp of that still. The live video is not sampled per triangle.
function warpJpeg(video, srcQuad, dw, dh, maxBytes) {
    const xs = srcQuad.map((p) => p[0]), ys = srcQuad.map((p) => p[1]);
    let x0 = Math.max(0, Math.floor(Math.min(...xs)));
    let y0 = Math.max(0, Math.floor(Math.min(...ys)));
    let x1 = Math.min(video.videoWidth, Math.ceil(Math.max(...xs)));
    let y1 = Math.min(video.videoHeight, Math.ceil(Math.max(...ys)));
    let sw = x1 - x0, sh = y1 - y0;
    if (sw < 8 || sh < 8) return '';
    const cap = 1280 / Math.max(sw, sh);
    const bw = Math.max(1, Math.round(sw * Math.min(1, cap)));
    const bh = Math.max(1, Math.round(sh * Math.min(1, cap)));
    let still;
    try {
        still = document.createElement('canvas');
        still.width = bw;
        still.height = bh;
        const sctx = still.getContext('2d');
        if (!sctx || typeof sctx.drawImage !== 'function') return '';
        sctx.drawImage(video, x0, y0, sw, sh, 0, 0, bw, bh);
    } catch {
        return '';
    }
    const local = srcQuad.map(([x, y]) => [(x - x0) * (bw / sw), (y - y0) * (bh / sh)]);
    const ladder = maxBytes <= PHONE_THUMB_MAX
        ? [[220, 0.72], [220, 0.55], [160, 0.5], [120, 0.45], [96, 0.4]]
        : [[PREVIEW_LONG, 0.82], [PREVIEW_LONG, 0.7], [Math.round(PREVIEW_LONG * 0.75), 0.7]];
    try {
        for (const [edge, q] of ladder) {
            const s = Math.min(1, edge / Math.max(dw, dh));
            const canvas = document.createElement('canvas');
            canvas.width = Math.max(1, Math.round(dw * s));
            canvas.height = Math.max(1, Math.round(dh * s));
            const ctx = canvas.getContext('2d');
            if (!ctx || typeof ctx.drawImage !== 'function') return '';
            ctx.imageSmoothingEnabled = true;
            if ('imageSmoothingQuality' in ctx) ctx.imageSmoothingQuality = 'high';
            if (!paintWarp(ctx, still, local, canvas.width, canvas.height)) return '';
            const url = canvas.toDataURL('image/jpeg', q);
            if (!url?.startsWith('data:image/jpeg')) return '';
            if ((url.length - 23) * 0.75 <= maxBytes) return url;
        }
    } catch {
        /* no canvas */
    }
    return '';
}

function cropJpeg(bitmap, sx, sy, sw, sh, long, maxBytes) {
    if (sw < 8 || sh < 8) return '';
    const ladder = maxBytes <= PHONE_THUMB_MAX
        ? [[220, 0.72], [220, 0.55], [160, 0.5], [120, 0.45], [96, 0.4]]
        : [[long, 0.82], [long, 0.7], [Math.round(long * 0.75), 0.7]];
    try {
        for (const [edge, q] of ladder) {
            const s = Math.min(1, edge / Math.max(sw, sh));
            const canvas = document.createElement('canvas');
            canvas.width = Math.max(1, Math.round(sw * s));
            canvas.height = Math.max(1, Math.round(sh * s));
            const ctx = canvas.getContext('2d');
            if (!ctx || typeof ctx.drawImage !== 'function') return '';
            ctx.drawImage(bitmap, sx, sy, sw, sh, 0, 0, canvas.width, canvas.height);
            const url = canvas.toDataURL('image/jpeg', q);
            if (!url?.startsWith('data:image/jpeg')) return '';
            if ((url.length - 23) * 0.75 <= maxBytes) return url;
        }
    } catch {
        /* no canvas */
    }
    return '';
}

function toU8(src, n) {
    const u8 = (src instanceof Uint8ClampedArray || src instanceof Uint8Array) ? src : new Uint8ClampedArray(src);
    if (u8.length < n) return null;
    return new Uint8ClampedArray(u8.subarray(0, n));
}

/** True when the canvas shows the source pixels. A stub context without getImageData is trusted. */
function canvasHolds(ctx, data, w, h) {
    if (typeof ctx.getImageData !== 'function') return true;
    const img = ctx.getImageData(0, 0, w, h).data;
    const pts = [0, ((h >> 1) * w + (w >> 1)) * 4, (h * w - 1) * 4];
    return pts.every((i) => img[i] === data[i] && img[i + 1] === data[i + 1] && img[i + 2] === data[i + 2]);
}

/**
 * JPEG data URL of an RGBA thumb. Copies the buffer first (a worker-cloned view can paint as an empty
 * canvas, which is the blank grey box). Falls back to a PNG when the canvas does not hold the pixels,
 * and to img.url when the raw buffer did not survive the worker.
 */
export function thumbUrl(img, quality = 0.85) {
    const w = img?.width | 0, h = img?.height | 0, n = w * h * 4;
    if (!img?.data || n < 4) return img?.url || '';
    const data = toU8(img.data, n);
    if (!data) return img.url || '';
    try {
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d');
        if (ctx && typeof ImageData === 'function') {
            ctx.putImageData(new ImageData(new Uint8ClampedArray(data), w, h), 0, 0);
            const url = canvas.toDataURL('image/jpeg', quality);
            if (url && url.startsWith('data:image/') && url.length > 32 && canvasHolds(ctx, data, w, h)) return url;
        }
    } catch {
        /* png below */
    }
    return img.url || pngDataUrl(data, w, h);
}

function crc32(bytes) {
    let c = ~0;
    for (let i = 0; i < bytes.length; i++) {
        c ^= bytes[i];
        for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c >>> 0;
}

function adler32(bytes) {
    let a = 1, b = 0;
    for (let i = 0; i < bytes.length; i++) {
        a = (a + bytes[i]) % 65521;
        b = (b + a) % 65521;
    }
    return ((b << 16) | a) >>> 0;
}

function pngChunk(type, data) {
    const out = new Uint8Array(12 + data.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, data.length);
    out.set(type, 4);
    out.set(data, 8);
    view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
}

/** Uncompressed RGBA PNG data URL. Used when canvas cannot paint the warp. */
export function pngDataUrl(rgba, w, h) {
    const n = w * h * 4;
    const src = (rgba instanceof Uint8Array) ? rgba : new Uint8Array(rgba.buffer || rgba);
    if (src.length < n || w < 1 || h < 1) return '';
    const raw = new Uint8Array(h * (1 + w * 4));
    for (let y = 0, o = 0, i = 0; y < h; y++) {
        raw[o++] = 0;
        raw.set(src.subarray(i, i + w * 4), o);
        o += w * 4;
        i += w * 4;
    }
    const zblocks = [new Uint8Array([0x78, 0x01])];
    for (let off = 0; off < raw.length; off += 65535) {
        const len = Math.min(65535, raw.length - off);
        const last = off + len >= raw.length;
        const block = new Uint8Array(5 + len);
        const nlen = (~len) & 0xffff;
        block[0] = last ? 1 : 0;
        block[1] = len & 255;
        block[2] = (len >> 8) & 255;
        block[3] = nlen & 255;
        block[4] = (nlen >> 8) & 255;
        block.set(raw.subarray(off, off + len), 5);
        zblocks.push(block);
    }
    const sum = adler32(raw);
    const tail = new Uint8Array(4);
    new DataView(tail.buffer).setUint32(0, sum);
    zblocks.push(tail);
    let zlen = 0;
    for (const b of zblocks) zlen += b.length;
    const z = new Uint8Array(zlen);
    let zoff = 0;
    for (const b of zblocks) { z.set(b, zoff); zoff += b.length; }
    const ihdr = new Uint8Array(13);
    const iv = new DataView(ihdr.buffer);
    iv.setUint32(0, w);
    iv.setUint32(4, h);
    ihdr[8] = 8;
    ihdr[9] = 6;
    const sig = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    const parts = [sig, pngChunk(new Uint8Array([73, 72, 68, 82]), ihdr), pngChunk(new Uint8Array([73, 68, 65, 84]), z), pngChunk(new Uint8Array([73, 69, 78, 68]), new Uint8Array())];
    let total = 0;
    for (const p of parts) total += p.length;
    const png = new Uint8Array(total);
    let po = 0;
    for (const p of parts) { png.set(p, po); po += p.length; }
    let bin = '';
    for (let i = 0; i < png.length; i += 0x8000) bin += String.fromCharCode(...png.subarray(i, i + 0x8000));
    return `data:image/png;base64,${btoa(bin)}`;
}
