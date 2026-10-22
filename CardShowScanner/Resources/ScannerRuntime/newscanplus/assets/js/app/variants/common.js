/**
 * variants/common.js — Shared 200x280 RGBA image analysis primitives for per-game
 * single-image variant & sibling detection (used when scanning on 'Any' printing preference).
 *
 * Standalone module for testing and accuracy verification; not wired into live scanner yet.
 */

export const WORK_W = 200;
export const WORK_H = 280;

/**
 * Resample an arbitrary RGBA buffer (srcW x srcH) to a 200x280 work surface with:
 *  - L: BT.601 luma (0..255)
 *  - A: red-green opponent chroma (R - G)
 *  - B: yellow-blue opponent chroma ((R + G)/2 - B)
 *  - lap: 4-neighbor Laplacian magnitude on interior (198x278)
 *  - floor: median Laplacian floor (camera sharpness baseline)
 */
export function toWorkSurface(rgba, srcW = WORK_W, srcH = WORK_H) {
    if (!rgba || rgba.length < srcW * srcH * 4) return null;
    const W = WORK_W;
    const H = WORK_H;
    const n = W * H;
    const L = new Float32Array(n);
    const A = new Float32Array(n);
    const B = new Float32Array(n);
    const R = new Float32Array(n);
    const G = new Float32Array(n);
    const Bl = new Float32Array(n);

    for (let y = 0; y < H; y++) {
        const sy = srcH === H ? y : Math.min(srcH - 1, Math.floor(((y + 0.5) * srcH) / H));
        for (let x = 0; x < W; x++) {
            const sx = srcW === W ? x : Math.min(srcW - 1, Math.floor(((x + 0.5) * srcW) / W));
            const si = (sy * srcW + sx) * 4;
            const r = rgba[si];
            const g = rgba[si + 1];
            const b = rgba[si + 2];
            const di = y * W + x;
            R[di] = r;
            G[di] = g;
            Bl[di] = b;
            L[di] = 0.299 * r + 0.587 * g + 0.114 * b;
            A[di] = r - g;
            B[di] = 0.5 * (r + g) - b;
        }
    }

    const lw = W - 2;
    const lh = H - 2;
    const lap = new Float32Array(lw * lh);
    const sample = [];
    for (let y = 1; y < H - 1; y++) {
        const row = y * W;
        const lrow = (y - 1) * lw;
        for (let x = 1; x < W - 1; x++) {
            const i = row + x;
            const v = Math.abs(4 * L[i] - L[i - 1] - L[i + 1] - L[i - W] - L[i + W]);
            lap[lrow + (x - 1)] = v;
            if ((y & 1) === 0 && (x & 1) === 0) sample.push(v);
        }
    }
    sample.sort((p, q) => p - q);
    const floor = sample.length ? sample[sample.length >> 1] : 0;

    return { W, H, R, G, Bl, L, A, B, lap, lw, lh, floor };
}

/**
 * 3x3 box blur of a work surface (approximates Gaussian(3x3) for reference alignment).
 */
export function blurSurface(surf) {
    if (!surf) return null;
    const { W, H } = surf;
    const blurPlane = (src) => {
        const dst = new Float32Array(W * H);
        for (let y = 0; y < H; y++) {
            const y0 = Math.max(0, y - 1);
            const y1 = Math.min(H - 1, y + 1);
            for (let x = 0; x < W; x++) {
                const x0 = Math.max(0, x - 1);
                const x1 = Math.min(W - 1, x + 1);
                let sum = 0;
                let cnt = 0;
                for (let yy = y0; yy <= y1; yy++) {
                    const r = yy * W;
                    for (let xx = x0; xx <= x1; xx++) {
                        sum += src[r + xx];
                        cnt++;
                    }
                }
                dst[y * W + x] = sum / cnt;
            }
        }
        return dst;
    };
    const R = blurPlane(surf.R);
    const G = blurPlane(surf.G);
    const Bl = blurPlane(surf.Bl);
    const L = blurPlane(surf.L);
    const A = blurPlane(surf.A);
    const B = blurPlane(surf.B);
    const lw = W - 2;
    const lh = H - 2;
    const lap = new Float32Array(lw * lh);
    for (let y = 1; y < H - 1; y++) {
        const row = y * W;
        const lrow = (y - 1) * lw;
        for (let x = 1; x < W - 1; x++) {
            const i = row + x;
            lap[lrow + (x - 1)] = Math.abs(4 * L[i] - L[i - 1] - L[i + 1] - L[i - W] - L[i + W]);
        }
    }
    return { W, H, R, G, Bl, L, A, B, lap, lw, lh, floor: surf.floor };
}

/**
 * Align reference surface `ref` to scan surface `scan` by searching integer shifts
 * dx, dy in [-4..4] on the card interior and applying a 3x3 smoothing blur.
 */
export function alignReference(scan, ref) {
    if (!scan || !ref) return null;
    const { W, H } = scan;
    let sSum = 0;
    let sCnt = 0;
    for (let y = 24; y < 256; y += 4) {
        for (let x = 20; x < 180; x += 4) {
            sSum += scan.L[y * W + x];
            sCnt++;
        }
    }
    const sMean = sSum / (sCnt || 1);

    let bestErr = Infinity;
    let bestDx = 0;
    let bestDy = 0;
    for (let dy = -4; dy <= 4; dy += 2) {
        for (let dx = -4; dx <= 4; dx += 2) {
            let rSum = 0;
            for (let y = 24; y < 256; y += 4) {
                const ry = (y + dy) * W;
                for (let x = 20; x < 180; x += 4) rSum += ref.L[ry + x + dx];
            }
            const rMean = rSum / (sCnt || 1);
            let err = 0;
            for (let y = 24; y < 256; y += 4) {
                const sy = y * W;
                const ry = (y + dy) * W;
                for (let x = 20; x < 180; x += 4) {
                    err += Math.abs((scan.L[sy + x] - sMean) - (ref.L[ry + x + dx] - rMean));
                }
            }
            if (err < bestErr) {
                bestErr = err;
                bestDx = dx;
                bestDy = dy;
            }
        }
    }

    const shiftPlane = (src) => {
        const dst = new Float32Array(W * H);
        for (let y = 0; y < H; y++) {
            const sy = Math.max(0, Math.min(H - 1, y + bestDy));
            for (let x = 0; x < W; x++) {
                const sx = Math.max(0, Math.min(W - 1, x + bestDx));
                dst[y * W + x] = src[sy * W + sx];
            }
        }
        return dst;
    };

    const shifted = {
        W,
        H,
        R: shiftPlane(ref.R),
        G: shiftPlane(ref.G),
        Bl: shiftPlane(ref.Bl),
        L: shiftPlane(ref.L),
        A: shiftPlane(ref.A),
        B: shiftPlane(ref.B),
        floor: ref.floor,
    };
    return blurSurface(shifted);
}

/**
 * Percentile helper on a numeric array or Float32Array (0 <= p <= 100).
 */
export function percentile(arr, p) {
    if (!arr || !arr.length) return 0;
    const sorted = Float32Array.from(arr).sort();
    const idx = Math.min(sorted.length - 1, Math.max(0, Math.floor((p / 100) * sorted.length)));
    return sorted[idx];
}

/**
 * Compute reference-subtracted flat-region foil metrics inside `zone = [rx0, ry0, rx1, ry1]`.
 * Isolates pixels where the aligned reference has low gradient (`grad < 8`), so text and border
 * alignment edges cannot masquerade as foil signal.
 */
export function zoneFlatFoilMetrics(scan, alignedRef, zone) {
    if (!scan || !alignedRef) return null;
    const { W, H } = scan;
    const x0 = Math.max(1, Math.round(zone[0] * W));
    const y0 = Math.max(1, Math.round(zone[1] * H));
    const x1 = Math.min(W - 1, Math.round(zone[2] * W));
    const y1 = Math.min(H - 1, Math.round(zone[3] * H));

    const rL = alignedRef.L;
    const grads = [];
    for (let y = y0; y < y1; y++) {
        const row = y * W;
        for (let x = x0; x < x1; x++) {
            const i = row + x;
            const gx = Math.abs(rL[i + 1] - rL[i - 1]) * 0.5;
            const gy = Math.abs(rL[i + W] - rL[i - W]) * 0.5;
            grads.push(gx + gy);
        }
    }
    let gradCut = 8.0;
    let flatCnt = 0;
    for (let i = 0; i < grads.length; i++) if (grads[i] < gradCut) flatCnt++;
    if (flatCnt < 30) gradCut = percentile(grads, 50) + 0.01;

    let sumDL = 0;
    let sumDA = 0;
    let sumDB = 0;
    let sumSL = 0;
    let sumRL = 0;
    let nFlat = 0;
    for (let y = y0, gi = 0; y < y1; y++) {
        const row = y * W;
        for (let x = x0; x < x1; x++, gi++) {
            if (grads[gi] >= gradCut) continue;
            const i = row + x;
            sumDL += scan.L[i] - alignedRef.L[i];
            sumDA += scan.A[i] - alignedRef.A[i];
            sumDB += scan.B[i] - alignedRef.B[i];
            sumSL += scan.L[i];
            sumRL += alignedRef.L[i];
            nFlat++;
        }
    }
    if (!nFlat) return { lumaStd: 0, chromaMean: 0, chromaP90: 0, waveAB: 0, waveL: 0, texExcess: 0, diagExcess: 0, contrastRatio: 1 };

    const meanDL = sumDL / nFlat;
    const meanDA = sumDA / nFlat;
    const meanDB = sumDB / nFlat;
    const meanSL = sumSL / nFlat;
    const meanRL = sumRL / nFlat;

    const chromas = new Float32Array(nFlat);
    let sqDL = 0;
    let sqSL = 0;
    let sqRL = 0;
    let sumChr = 0;
    let sumTexEx = 0;
    let sumDiagEx = 0;
    const lw = scan.lw;

    const bandCnt = [0, 0, 0, 0];
    const bandA = [0, 0, 0, 0];
    const bandB = [0, 0, 0, 0];
    const bandL = [0, 0, 0, 0];
    const hZone = Math.max(1, y1 - y0);

    let fi = 0;
    for (let y = y0, gi = 0; y < y1; y++) {
        const row = y * W;
        const lrow = (y - 1) * lw;
        const bIdx = Math.min(3, Math.floor(((y - y0) * 4) / hZone));
        for (let x = x0; x < x1; x++, gi++) {
            if (grads[gi] >= gradCut) continue;
            const i = row + x;
            const dl = (scan.L[i] - alignedRef.L[i]) - meanDL;
            const da = (scan.A[i] - alignedRef.A[i]) - meanDA;
            const db = (scan.B[i] - alignedRef.B[i]) - meanDB;
            const chr = Math.hypot(da, db);
            chromas[fi++] = chr;
            sumChr += chr;
            sqDL += dl * dl;
            sqSL += (scan.L[i] - meanSL) ** 2;
            sqRL += (alignedRef.L[i] - meanRL) ** 2;
            const li = lrow + (x - 1);
            const texDiff = scan.lap[li] - alignedRef.lap[li];
            if (texDiff > 0) sumTexEx += texDiff;
            const sd =
                Math.abs(scan.L[i + W + 1] - scan.L[i - W - 1]) +
                Math.abs(scan.L[i + W - 1] - scan.L[i - W + 1]);
            const rd =
                Math.abs(alignedRef.L[i + W + 1] - alignedRef.L[i - W - 1]) +
                Math.abs(alignedRef.L[i + W - 1] - alignedRef.L[i - W + 1]);
            if (sd > rd) sumDiagEx += sd - rd;
            bandCnt[bIdx]++;
            bandA[bIdx] += da;
            bandB[bIdx] += db;
            bandL[bIdx] += dl;
        }
    }

    const validA = [];
    const validB = [];
    const validL = [];
    for (let b = 0; b < 4; b++) {
        if (bandCnt[b] >= 8) {
            validA.push(bandA[b] / bandCnt[b]);
            validB.push(bandB[b] / bandCnt[b]);
            validL.push(bandL[b] / bandCnt[b]);
        }
    }
    const waveAB =
        validA.length >= 2
            ? Math.max(...validA) - Math.min(...validA) + (Math.max(...validB) - Math.min(...validB))
            : 0;
    const waveL = validL.length >= 2 ? Math.max(...validL) - Math.min(...validL) : 0;

    return {
        lumaStd: Math.sqrt(sqDL / nFlat),
        chromaMean: sumChr / nFlat,
        chromaP90: percentile(chromas, 90),
        waveAB,
        waveL,
        texExcess: sumTexEx / nFlat,
        diagExcess: sumDiagEx / nFlat,
        contrastRatio: Math.sqrt(sqSL / nFlat) / (Math.sqrt(sqRL / nFlat) + 1.0),
    };
}

/**
 * Mean Laplacian texture above the card's noise floor inside `rect = [rx0, ry0, rx1, ry1]`.
 */
export function patchTexture(surf, rect) {
    if (!surf) return 0;
    const x0 = Math.max(1, Math.round(rect[0] * surf.W)) - 1;
    const y0 = Math.max(1, Math.round(rect[1] * surf.H)) - 1;
    const x1 = Math.min(surf.W - 1, Math.round(rect[2] * surf.W)) - 1;
    const y1 = Math.min(surf.H - 1, Math.round(rect[3] * surf.H)) - 1;
    let sum = 0;
    let cnt = 0;
    for (let y = y0; y < y1; y++) {
        const row = y * surf.lw;
        for (let x = x0; x < x1; x++) {
            sum += surf.lap[row + x];
            cnt++;
        }
    }
    if (!cnt) return 0;
    return Math.max(0, sum / cnt - surf.floor);
}

/**
 * Resolve a variant label (or predicate) against a candidate's `variants` array.
 */
export function findVariant(variants, matchLabelOrFn) {
    if (!Array.isArray(variants)) return null;
    const fn =
        typeof matchLabelOrFn === 'function'
            ? matchLabelOrFn
            : (v) => String(v?.label || '').toLowerCase() === String(matchLabelOrFn || '').toLowerCase();
    return variants.find(fn) || null;
}

/**
 * Strip parenthetical suffixes from a card name to compare base card names across siblings.
 */
export function baseCardName(name) {
    return String(name || '')
        .replace(/\s*\(\d{3,4}\)/g, '')
        .split(' (')[0]
        .replace(/\s*-\s*\d+\/\d+.*$/, '')
        .trim()
        .toLowerCase();
}

export const CARD_W = 200;
export const CARD_H = 280;
const GW = 50;
const GH = 70;
const GC = 4;

const REG_T = [0.08, 0.58, 0.92, 0.90, 16, 24, 1, 2];
const REG_B = [0.04, 0.88, 0.96, 0.985, 32, 6, 2, 1];
const REG_MTG_SYM = [0.80, 0.54, 0.95, 0.62, 12, 8];
const REG_LIST = [0.015, 0.915, 0.095, 0.985, 10, 10];
const CORNER_PATCHES = [[11, 262, 33, 269], [33, 263, 55, 270], [10, 256, 38, 263], [11, 261, 56, 270]];

export function cardBaseName(name) {
    return String(name || '')
        .replace(/\s+-\s+\d+\/\d+\b/g, '')
        .replace(/\s*\[[^\]]*\]/g, '')
        .replace(/\s*\([^)]*\)/g, '')
        .replace(/\s+-\s+(?:\d+\/\d+|"[^"]*")$/, '')
        .trim()
        .toLowerCase();
}

export function isPlainReprintName(name) {
    const s = String(name || '');
    const rest = s.slice(s.replace(/\s*\([^)]*\).*$/, '').length).trim();
    return rest === '' || /^\(\d+\)$/.test(rest);
}

function luma200(rgba) {
    const g = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) {
        const o = i * 4;
        g[i] = 0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2];
    }
    return g;
}

function morphBox(src, rad, isMax) {
    const tmp = new Float32Array(CARD_W * CARD_H);
    const out = new Float32Array(CARD_W * CARD_H);
    if (rad === 1) {
        for (let y = 0; y < CARD_H; y++) {
            const rOff = y * CARD_W;
            for (let x = 0; x < CARD_W; x++) {
                const a = src[rOff + (x > 0 ? x - 1 : 0)];
                const b = src[rOff + x];
                const c = src[rOff + (x < CARD_W - 1 ? x + 1 : CARD_W - 1)];
                tmp[rOff + x] = isMax ? (a > b ? (a > c ? a : c) : (b > c ? b : c)) : (a < b ? (a < c ? a : c) : (b < c ? b : c));
            }
        }
        for (let y = 0; y < CARD_H; y++) {
            const r0 = (y > 0 ? y - 1 : 0) * CARD_W;
            const r1 = y * CARD_W;
            const r2 = (y < CARD_H - 1 ? y + 1 : CARD_H - 1) * CARD_W;
            for (let x = 0; x < CARD_W; x++) {
                const a = tmp[r0 + x], b = tmp[r1 + x], c = tmp[r2 + x];
                out[r1 + x] = isMax ? (a > b ? (a > c ? a : c) : (b > c ? b : c)) : (a < b ? (a < c ? a : c) : (b < c ? b : c));
            }
        }
        return out;
    }
    for (let y = 0; y < CARD_H; y++) {
        const rOff = y * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            const x0 = x > 1 ? x - 2 : 0;
            const x1 = x > 0 ? x - 1 : 0;
            const x3 = x < CARD_W - 1 ? x + 1 : CARD_W - 1;
            const x4 = x < CARD_W - 2 ? x + 2 : CARD_W - 1;
            let v = src[rOff + x];
            const a = src[rOff + x0], b = src[rOff + x1], c = src[rOff + x3], d = src[rOff + x4];
            if (isMax) { if (a > v) v = a; if (b > v) v = b; if (c > v) v = c; if (d > v) v = d; }
            else { if (a < v) v = a; if (b < v) v = b; if (c < v) v = c; if (d < v) v = d; }
            tmp[rOff + x] = v;
        }
    }
    for (let y = 0; y < CARD_H; y++) {
        const r0 = (y > 1 ? y - 2 : 0) * CARD_W;
        const r1 = (y > 0 ? y - 1 : 0) * CARD_W;
        const r2 = y * CARD_W;
        const r3 = (y < CARD_H - 1 ? y + 1 : CARD_H - 1) * CARD_W;
        const r4 = (y < CARD_H - 2 ? y + 2 : CARD_H - 1) * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            let v = tmp[r2 + x];
            const a = tmp[r0 + x], b = tmp[r1 + x], c = tmp[r3 + x], d = tmp[r4 + x];
            if (isMax) { if (a > v) v = a; if (b > v) v = b; if (c > v) v = c; if (d > v) v = d; }
            else { if (a < v) v = a; if (b < v) v = b; if (c < v) v = c; if (d < v) v = d; }
            out[r2 + x] = v;
        }
    }
    return out;
}

function blackhat(g, rad) {
    const closed = morphBox(morphBox(g, rad, true), rad, false);
    const out = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) out[i] = closed[i] - g[i];
    return out;
}

function tophat(g, rad) {
    const opened = morphBox(morphBox(g, rad, false), rad, true);
    const out = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) out[i] = g[i] - opened[i];
    return out;
}

function inkMap(g) {
    const tmp = new Float32Array(CARD_W * CARD_H);
    const out = new Float32Array(CARD_W * CARD_H);
    for (let y = 0; y < CARD_H; y++) {
        const rOff = y * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            const x0 = x > 1 ? x - 2 : 0, x1 = x > 0 ? x - 1 : 0, x3 = x < CARD_W - 1 ? x + 1 : CARD_W - 1, x4 = x < CARD_W - 2 ? x + 2 : CARD_W - 1;
            tmp[rOff + x] = 0.2 * (g[rOff + x0] + g[rOff + x1] + g[rOff + x] + g[rOff + x3] + g[rOff + x4]);
        }
    }
    for (let y = 0; y < CARD_H; y++) {
        const r0 = (y > 1 ? y - 2 : 0) * CARD_W, r1 = (y > 0 ? y - 1 : 0) * CARD_W, r2 = y * CARD_W, r3 = (y < CARD_H - 1 ? y + 1 : CARD_H - 1) * CARD_W, r4 = (y < CARD_H - 2 ? y + 2 : CARD_H - 1) * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            const blur = 0.2 * (tmp[r0 + x] + tmp[r1 + x] + tmp[r2 + x] + tmp[r3 + x] + tmp[r4 + x]);
            out[r2 + x] = Math.abs(g[r2 + x] - blur);
        }
    }
    return out;
}

function highPassBox(g, rad) {
    const tmp = new Float32Array(CARD_W * CARD_H);
    const out = new Float32Array(CARD_W * CARD_H);
    const k = 2 * rad + 1;
    for (let y = 0; y < CARD_H; y++) {
        const rOff = y * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            let s = 0;
            for (let d = -rad; d <= rad; d++) s += g[rOff + Math.max(0, Math.min(CARD_W - 1, x + d))];
            tmp[rOff + x] = s / k;
        }
    }
    for (let y = 0; y < CARD_H; y++) {
        const rOff = y * CARD_W;
        for (let x = 0; x < CARD_W; x++) {
            let s = 0;
            for (let d = -rad; d <= rad; d++) s += tmp[Math.max(0, Math.min(CARD_H - 1, y + d)) * CARD_W + x];
            out[rOff + x] = g[rOff + x] - s / k;
        }
    }
    return out;
}

function areaPoolRegion(plane, reg) {
    let [x0, y0, x1, y1, w, h, sx, sy] = reg;
    const cw = (x1 - x0) / w;
    const ch = (y1 - y0) / h;
    x0 -= sx * cw; x1 += sx * cw;
    y0 -= sy * ch; y1 += sy * ch;
    const pw = w + 2 * sx;
    const ph = h + 2 * sy;
    const px0 = Math.max(0, Math.floor(CARD_W * x0));
    const py0 = Math.max(0, Math.floor(CARD_H * y0));
    const px1 = Math.min(CARD_W, Math.floor(CARD_W * x1));
    const py1 = Math.min(CARD_H, Math.floor(CARD_H * y1));
    const sw = Math.max(1, px1 - px0);
    const sh = Math.max(1, py1 - py0);
    const out = new Float32Array(pw * ph);
    for (let r = 0; r < ph; r++) {
        const sy0 = py0 + Math.floor((r * sh) / ph);
        const sy1 = Math.max(sy0 + 1, py0 + Math.floor(((r + 1) * sh) / ph));
        for (let c = 0; c < pw; c++) {
            const sx0 = px0 + Math.floor((c * sw) / pw);
            const sx1 = Math.max(sx0 + 1, px0 + Math.floor(((c + 1) * sw) / pw));
            let sum = 0, cnt = 0;
            for (let yy = sy0; yy < sy1; yy++) {
                const rOff = yy * CARD_W;
                for (let xx = sx0; xx < sx1; xx++) {
                    sum += plane[rOff + xx];
                    cnt++;
                }
            }
            out[r * pw + c] = cnt ? sum / cnt : 0;
        }
    }
    return { data: out, w: pw, h: ph, sx, sy };
}

function zNormWindow(feat, ox, oy, cw, ch) {
    const { data, w } = feat;
    const n = cw * ch;
    const out = new Float32Array(n);
    let sum = 0, k = 0;
    for (let r = 0; r < ch; r++) {
        const rOff = (oy + r) * w + ox;
        for (let c = 0; c < cw; c++) {
            const v = data[rOff + c];
            out[k++] = v;
            sum += v;
        }
    }
    const mean = sum / n;
    let sq = 0;
    for (let i = 0; i < n; i++) {
        out[i] -= mean;
        sq += out[i] * out[i];
    }
    const norm = Math.sqrt(sq) || 1;
    for (let i = 0; i < n; i++) out[i] /= norm;
    return out;
}

export function subhashDist(a, b) {
    const { w, h, sx, sy } = a;
    const cw = w - 2 * sx;
    const ch = h - 2 * sy;
    const core = zNormWindow(b, sx, sy, cw, ch);
    let best = -1;
    for (let dy = 0; dy <= 2 * sy; dy++) {
        for (let dx = 0; dx <= 2 * sx; dx++) {
            const win = zNormWindow(a, dx, dy, cw, ch);
            let dot = 0;
            for (let i = 0; i < core.length; i++) dot += win[i] * core[i];
            if (dot > best) best = dot;
        }
    }
    return 1 - best;
}

function strokeCellMap(g) {
    const bh = blackhat(g, 2);
    const th = tophat(g, 2);
    const n = GW * GH;
    const map = new Float32Array(2 * n);
    for (let ch = 0; ch < 2; ch++) {
        const src = ch === 0 ? bh : th;
        const cells = new Float32Array(n);
        for (let r = 0; r < GH; r++) {
            for (let c = 0; c < GW; c++) {
                let s = 0;
                for (let dy = 0; dy < GC; dy++) {
                    const rOff = (r * GC + dy) * CARD_W + c * GC;
                    for (let dx = 0; dx < GC; dx++) s += src[rOff + dx];
                }
                cells[r * GW + c] = s / (GC * GC);
            }
        }
        const sorted = Float32Array.from(cells).sort();
        const p95 = sorted[Math.floor(n * 0.95)] || 1;
        const base = ch * n;
        for (let i = 0; i < n; i++) map[base + i] = Math.min(1.5, cells[i] / p95);
    }
    return map;
}

export function extractMtgReprintPools(rgba) {
    if (!rgba || rgba.length < CARD_W * CARD_H * 4) return null;
    const g = luma200(rgba);
    function poolReg([x0f, y0f, x1f, y1f, gw, gh]) {
        const x0 = Math.round(x0f * CARD_W), y0 = Math.round(y0f * CARD_H);
        const rw = Math.max(gw, Math.round((x1f - x0f) * CARD_W));
        const rh = Math.max(gh, Math.round((y1f - y0f) * CARD_H));
        const cells = new Float32Array(gw * gh);
        for (let gy = 0; gy < gh; gy++) {
            const py0 = y0 + Math.floor((gy * rh) / gh);
            const py1 = Math.min(CARD_H, Math.max(py0 + 1, y0 + Math.floor(((gy + 1) * rh) / gh)));
            for (let gx = 0; gx < gw; gx++) {
                const px0 = x0 + Math.floor((gx * rw) / gw);
                const px1 = Math.min(CARD_W, Math.max(px0 + 1, x0 + Math.floor(((gx + 1) * rw) / gw)));
                let s = 0, cnt = 0;
                for (let y = py0; y < py1; y++) {
                    for (let x = px0; x < px1; x++) { s += g[y * CARD_W + x]; cnt++; }
                }
                cells[gy * gw + gx] = cnt ? s / cnt : 0;
            }
        }
        let mean = 0;
        for (let i = 0; i < cells.length; i++) mean += cells[i];
        mean /= cells.length;
        let sq = 0;
        for (let i = 0; i < cells.length; i++) { cells[i] -= mean; sq += cells[i] * cells[i]; }
        const nrm = Math.sqrt(sq) || 1;
        for (let i = 0; i < cells.length; i++) cells[i] /= nrm;
        return cells;
    }
    return {
        mtgSym: poolReg(REG_MTG_SYM),
        listIcon: poolReg(REG_LIST),
    };
}

export function extractReprintFeatures(rgba, width = CARD_W, height = CARD_H) {
    if (!rgba || width !== CARD_W || height !== CARD_H) return null;
    const g = luma200(rgba);
    const bh = blackhat(g, 1);
    const ink = inkMap(g);
    const n = GW * GH;
    const ch = new Float32Array(2 * n);
    for (let r = 0; r < GH; r++) {
        for (let c = 0; c < GW; c++) {
            let rSum = 0, gSum = 0, bSum = 0;
            for (let dy = 0; dy < GC; dy++) {
                const rowOff = ((r * GC + dy) * CARD_W + c * GC) * 4;
                for (let dx = 0; dx < GC; dx++) {
                    const p = rowOff + dx * 4;
                    rSum += rgba[p];
                    gSum += rgba[p + 1];
                    bSum += rgba[p + 2];
                }
            }
            const y = Math.max(40, (0.299 * rSum + 0.587 * gSum + 0.114 * bSum) / (GC * GC));
            const idx = r * GW + c;
            ch[idx] = (rSum - gSum) / (GC * GC) / y;
            ch[n + idx] = (rSum - bSum) / (GC * GC) / y;
        }
    }
    const mtgPools = extractMtgReprintPools(rgba);
    return {
        bht: areaPoolRegion(bh, REG_T),
        bhb: areaPoolRegion(bh, REG_B),
        inkt: areaPoolRegion(ink, REG_T),
        inkb: areaPoolRegion(ink, REG_B),
        dg: strokeCellMap(g),
        ch,
        hp1: highPassBox(g, 1),
        hp3: highPassBox(g, 3),
        mtgSym: mtgPools?.mtgSym || null,
        listIcon: mtgPools?.listIcon || null,
        rgba,
    };
}

function shiftDg(map, dy, dx) {
    if (dy === 0 && dx === 0) return map;
    const n = GW * GH;
    const out = new Float32Array(2 * n);
    for (let ch = 0; ch < 2; ch++) {
        const base = ch * n;
        for (let r = 0; r < GH; r++) {
            const rr = (r - dy + GH) % GH;
            for (let c = 0; c < GW; c++) {
                const cc = (c - dx + GW) % GW;
                out[base + r * GW + c] = map[base + rr * GW + cc];
            }
        }
    }
    return out;
}

export function dgVote(qMap, aMap, bMap, k = 30, bands = null) {
    const n = GW * GH;
    const D = new Float32Array(n);
    const keep = new Uint8Array(n);
    if (!bands) {
        for (let r = 2; r < GH - 2; r++) {
            for (let c = 2; c < GW - 2; c++) keep[r * GW + c] = 1;
        }
    } else {
        for (const [y0, y1] of bands) {
            const r0 = Math.floor(GH * y0);
            const r1 = Math.min(GH, Math.ceil(GH * y1));
            for (let r = r0; r < r1; r++) {
                for (let c = 2; c < GW - 2; c++) keep[r * GW + c] = 1;
            }
        }
    }
    for (let i = 0; i < n; i++) {
        if (keep[i]) D[i] = Math.abs(aMap[i] - bMap[i]) + Math.abs(aMap[n + i] - bMap[n + i]);
    }
    const order = Int32Array.from({ length: n }, (_, i) => i).sort((i, j) => D[i] - D[j]);
    const idx = order.subarray(n - k);

    let bestShift = qMap;
    let bestErr = Infinity;
    for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
            const qs = shiftDg(qMap, dy, dx);
            let err = 0;
            for (let i = 0; i < n; i++) {
                if (!bands || keep[i]) {
                    err += Math.abs(qs[i] - 0.5 * (aMap[i] + bMap[i])) + Math.abs(qs[n + i] - 0.5 * (aMap[n + i] + bMap[n + i]));
                }
            }
            if (err < bestErr) {
                bestErr = err;
                bestShift = qs;
            }
        }
    }

    let sa = 0, sb = 0, dab = 0, wins = 0, dSum = 0;
    for (let j = 0; j < k; j++) {
        const i = idx[j];
        const ca = Math.abs(bestShift[i] - aMap[i]) + Math.abs(bestShift[n + i] - aMap[n + i]);
        const cb = Math.abs(bestShift[i] - bMap[i]) + Math.abs(bestShift[n + i] - bMap[n + i]);
        sa += ca;
        sb += cb;
        dab += D[i];
        dSum += D[i];
        if (cb < ca) wins++;
    }
    return {
        v: (sa - sb) / ((bands ? dab : (sa + sb)) + 1e-6),
        v3: (sa - sb) / (dab + 1e-6),
        frac: wins / k,
        d: dSum / k,
    };
}

export function stampVote(qFeat, aFeat, bFeat, k = 12) {
    if (!qFeat?.dg || !qFeat?.ch || !aFeat?.dg || !aFeat?.ch || !bFeat?.dg || !bFeat?.ch) {
        return { v: 0, frac: 0, d: 0 };
    }
    const qDg = qFeat.dg, aDg = aFeat.dg, bDg = bFeat.dg;
    const qCh = qFeat.ch, aCh = aFeat.ch, bCh = bFeat.ch;
    const n = GW * GH;
    const cells = [];
    const r0 = Math.floor(GH * 0.35), r1 = Math.floor(GH * 0.56);
    const c0 = Math.floor(GW * 0.72), c1 = Math.floor(GW * 0.96);
    for (let r = r0; r < r1; r++) {
        for (let c = c0; c < c1; c++) {
            const i = r * GW + c;
            const dDg = Math.abs(aDg[i] - bDg[i]) + Math.abs(aDg[n + i] - bDg[n + i]);
            const dCh = 2.5 * (Math.abs(aCh[i] - bCh[i]) + Math.abs(aCh[n + i] - bCh[n + i]));
            const d = dDg + dCh;
            if (d > 0.4) cells.push({ i, r, c, d });
        }
    }
    cells.sort((x, y) => y.d - x.d);
    const top = cells.slice(0, k);
    if (top.length < 4) return { v: 0, frac: 0, d: 0 };

    let bestShift = [0, 0], bestErr = Infinity;
    for (let dr = -1; dr <= 1; dr++) {
        for (let dc = -1; dc <= 1; dc++) {
            let err = 0;
            for (const cell of top) {
                const qr = Math.max(0, Math.min(GH - 1, cell.r + dr));
                const qc = Math.max(0, Math.min(GW - 1, cell.c + dc));
                const qi = qr * GW + qc;
                err += Math.abs(qDg[qi] - 0.5 * (aDg[cell.i] + bDg[cell.i]))
                    + Math.abs(qDg[n + qi] - 0.5 * (aDg[n + cell.i] + bDg[n + cell.i]))
                    + 2.5 * (Math.abs(qCh[qi] - 0.5 * (aCh[cell.i] + bCh[cell.i]))
                        + Math.abs(qCh[n + qi] - 0.5 * (aCh[n + cell.i] + bCh[n + cell.i])));
            }
            if (err < bestErr) {
                bestErr = err;
                bestShift = [dr, dc];
            }
        }
    }

    let sa = 0, sb = 0, dab = 0, wins = 0;
    const [dr, dc] = bestShift;
    for (const cell of top) {
        const qr = Math.max(0, Math.min(GH - 1, cell.r + dr));
        const qc = Math.max(0, Math.min(GW - 1, cell.c + dc));
        const qi = qr * GW + qc;
        const ca = Math.abs(qDg[qi] - aDg[cell.i]) + Math.abs(qDg[n + qi] - aDg[n + cell.i])
            + 2.5 * (Math.abs(qCh[qi] - aCh[cell.i]) + Math.abs(qCh[n + qi] - aCh[n + cell.i]));
        const cb = Math.abs(qDg[qi] - bDg[cell.i]) + Math.abs(qDg[n + qi] - bDg[n + cell.i])
            + 2.5 * (Math.abs(qCh[qi] - bCh[cell.i]) + Math.abs(qCh[n + qi] - bCh[n + cell.i]));
        sa += ca;
        sb += cb;
        dab += cell.d;
        if (cb < ca) wins++;
    }
    return { v: (sa - sb) / (dab + 1e-6), frac: wins / top.length, d: dab / top.length };
}

export function stampRegionVote(qFeat, aFeat, bFeat, bands, x0Frac = 0.50, x1Frac = 0.92, k = 10) {
    const n = GW * GH;
    const D = new Float32Array(n);
    const c0 = Math.floor(GW * x0Frac), c1 = Math.min(GW, Math.ceil(GW * x1Frac));
    for (const [y0, y1] of bands) {
        const r0 = Math.floor(GH * y0), r1 = Math.min(GH, Math.ceil(GH * y1));
        for (let r = r0; r < r1; r++) {
            for (let c = c0; c < c1; c++) {
                const i = r * GW + c;
                const dDg = Math.abs(aFeat.dg[i] - bFeat.dg[i]) + Math.abs(aFeat.dg[n + i] - bFeat.dg[n + i]);
                const dCh = 1.6 * (Math.abs(aFeat.ch[i] - bFeat.ch[i]) + Math.abs(aFeat.ch[n + i] - bFeat.ch[n + i]));
                D[i] = dDg + dCh;
            }
        }
    }
    const idx = [];
    for (let i = 0; i < n; i++) if (D[i] > 0) idx.push(i);
    idx.sort((x, y) => D[y] - D[x]);
    const top = idx.slice(0, k);
    if (!top.length) return { v: 0, frac: 0, d: 0 };
    let sa = 0, sb = 0, wins = 0, dSum = 0;
    for (const i of top) {
        const qa = Math.abs(qFeat.dg[i] - aFeat.dg[i]) + Math.abs(qFeat.dg[n + i] - aFeat.dg[n + i])
            + 1.6 * (Math.abs(qFeat.ch[i] - aFeat.ch[i]) + Math.abs(qFeat.ch[n + i] - aFeat.ch[n + i]));
        const qb = Math.abs(qFeat.dg[i] - bFeat.dg[i]) + Math.abs(qFeat.dg[n + i] - bFeat.dg[n + i])
            + 1.6 * (Math.abs(qFeat.ch[i] - bFeat.ch[i]) + Math.abs(qFeat.ch[n + i] - bFeat.ch[n + i]));
        sa += qa; sb += qb; dSum += D[i];
        if (qb < qa) wins++;
    }
    return { v: (sa - sb) / (dSum + 1e-6), frac: wins / top.length, d: dSum };
}

function zdotCorner(pA, pB, x0, y0, x1, y1, dy, dx) {
    const n = (x1 - x0) * (y1 - y0);
    let sA = 0, sB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(CARD_H - 1, y + dy)) * CARD_W;
        const ry = y * CARD_W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(CARD_W - 1, x + dx));
            sA += pA[qy + qx];
            sB += pB[ry + x];
        }
    }
    const mA = sA / n, mB = sB / n;
    let dot = 0, nA = 0, nB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(CARD_H - 1, y + dy)) * CARD_W;
        const ry = y * CARD_W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(CARD_W - 1, x + dx));
            const a = pA[qy + qx] - mA;
            const b = pB[ry + x] - mB;
            dot += a * b;
            nA += a * a;
            nB += b * b;
        }
    }
    return dot / (Math.sqrt(nA * nB) + 1e-6);
}

function alignCornerRef(qFeat, rFeat, dyMin = -13, dyMax = 2, dxMin = -3, dxMax = 4) {
    let best = -1e9, bdy = 0, bdx = 0;
    for (let dy = dyMin; dy <= dyMax; dy++) {
        for (let dx = dxMin; dx <= dxMax; dx++) {
            const c = 0.5 * zdotCorner(qFeat.hp1, rFeat.hp1, 10, 256, 62, 270, dy, dx)
                + 0.5 * zdotCorner(qFeat.hp3, rFeat.hp3, 10, 256, 62, 270, dy, dx);
            if (c > best) {
                best = c;
                bdy = dy;
                bdx = dx;
            }
        }
    }
    return { dy: bdy, dx: bdx, corr: best };
}

function normCornerPatch(plane, x0, y0, x1, y1, dy, dx) {
    const w = x1 - x0, h = y1 - y0, n = w * h;
    const out = new Float32Array(n);
    let s = 0, k = 0;
    for (let y = y0; y < y1; y++) {
        const yy = Math.max(0, Math.min(CARD_H - 1, y + dy)) * CARD_W;
        for (let x = x0; x < x1; x++) {
            const xx = Math.max(0, Math.min(CARD_W - 1, x + dx));
            const v = plane[yy + xx];
            out[k++] = v;
            s += v;
        }
    }
    const m = s / n;
    let sq = 0;
    for (let i = 0; i < n; i++) {
        out[i] -= m;
        sq += out[i] * out[i];
    }
    const nr = Math.sqrt(sq / n) || 1;
    for (let i = 0; i < n; i++) out[i] /= nr;
    return out;
}

export function cornerVote(qFeat, aFeat, bFeat) {
    if (!qFeat?.hp1 || !qFeat?.hp3 || !aFeat?.hp1 || !aFeat?.hp3 || !bFeat?.hp1 || !bFeat?.hp3) {
        return { v: 0, frac: 0, fitA: 0, fitB: 0, setD: 0, numD: 0, nB: 0 };
    }
    const avgHp1 = new Float32Array(CARD_W * CARD_H);
    const avgHp3 = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) {
        avgHp1[i] = 0.5 * (aFeat.hp1[i] + bFeat.hp1[i]);
        avgHp3[i] = 0.5 * (aFeat.hp3[i] + bFeat.hp3[i]);
    }
    const al0 = alignCornerRef(qFeat, { hp1: avgHp1, hp3: avgHp3 });
    const alA = alignCornerRef(qFeat, aFeat, al0.dy - 1, al0.dy + 1, al0.dx - 1, al0.dx + 1);
    const alB = alignCornerRef(qFeat, bFeat, al0.dy - 1, al0.dy + 1, al0.dx - 1, al0.dx + 1);

    let sa = 0, sb = 0, dab = 0, wins = 0, tot = 0;
    const fitsA = [], fitsB = [];
    for (const [x0, y0, x1, y1] of CORNER_PATCHES) {
        for (const ch of ['hp1', 'hp3']) {
            const qA = normCornerPatch(qFeat[ch], x0, y0, x1, y1, alA.dy, alA.dx);
            const qB = normCornerPatch(qFeat[ch], x0, y0, x1, y1, alB.dy, alB.dx);
            const A = normCornerPatch(aFeat[ch], x0, y0, x1, y1, 0, 0);
            const B = normCornerPatch(bFeat[ch], x0, y0, x1, y1, 0, 0);
            let dA = 0, dB = 0;
            for (let i = 0; i < A.length; i++) {
                dA += qA[i] * A[i];
                dB += qB[i] * B[i];
            }
            fitsA.push(dA / A.length);
            fitsB.push(dB / B.length);
            const diffs = [];
            for (let i = 0; i < A.length; i++) {
                const d = Math.abs(A[i] - B[i]);
                if (d > 0.35) diffs.push({ i, d });
            }
            diffs.sort((x, y) => y.d - x.d);
            for (const cell of diffs.slice(0, 60)) {
                const ca = Math.abs(qA[cell.i] - A[cell.i]);
                const cb = Math.abs(qB[cell.i] - B[cell.i]);
                sa += ca;
                sb += cb;
                dab += cell.d;
                if (cb < ca) wins++;
                tot++;
            }
        }
    }
    const setA = 0.5 * (fitsA[0] + fitsA[1]), setB = 0.5 * (fitsB[0] + fitsB[1]);
    const numA = 0.5 * (fitsA[2] + fitsA[3]), numB = 0.5 * (fitsB[2] + fitsB[3]);
    const fitA = fitsA.reduce((a, b) => a + b, 0) / fitsA.length;
    const fitB = fitsB.reduce((a, b) => a + b, 0) / fitsB.length;
    return {
        v: (sa - sb) / (dab + 1e-6),
        frac: tot ? wins / tot : 0,
        fitA,
        fitB,
        setD: setB - setA,
        numD: numB - numA,
        nB: numB,
    };
}

export function resizeArea200(src, sw, sh) {
    if (!src || !sw || !sh) return null;
    if (sw === CARD_W && sh === CARD_H) {
        let opaque = true;
        for (let i = 3; i < src.length; i += 4) {
            if (src[i] !== 255) { opaque = false; break; }
        }
        if (opaque) return src instanceof Uint8ClampedArray ? src : new Uint8ClampedArray(src);
    }
    let hasAlpha = false;
    for (let i = 3; i < src.length; i += 4) {
        if (src[i] !== 255) { hasAlpha = true; break; }
    }
    let x0 = 0, y0 = 0, cw = sw, ch = sh;
    if (hasAlpha) {
        let bx0 = sw, by0 = sh, bx1 = -1, by1 = -1;
        for (let y = 0; y < sh; y++) {
            for (let x = 0; x < sw; x++) {
                if (src[(y * sw + x) * 4 + 3] > 16) {
                    if (x < bx0) bx0 = x;
                    if (x > bx1) bx1 = x;
                    if (y < by0) by0 = y;
                    if (y > by1) by1 = y;
                }
            }
        }
        if (bx1 >= 0) { x0 = bx0; y0 = by0; cw = bx1 - bx0 + 1; ch = by1 - by0 + 1; }
    }
    const dst = new Uint8ClampedArray(CARD_W * CARD_H * 4);
    const sx = cw / CARD_W, sy = ch / CARD_H;
    for (let dy = 0; dy < CARD_H; dy++) {
        const fy0 = dy * sy, fy1 = (dy + 1) * sy;
        const iy0 = Math.floor(fy0), iy1 = Math.min(ch, Math.ceil(fy1));
        for (let dx = 0; dx < CARD_W; dx++) {
            const fx0 = dx * sx, fx1 = (dx + 1) * sx;
            const ix0 = Math.floor(fx0), ix1 = Math.min(cw, Math.ceil(fx1));
            let r = 0, g = 0, b = 0, wsum = 0;
            for (let iy = iy0; iy < iy1; iy++) {
                const wy = Math.min(iy + 1, fy1) - Math.max(iy, fy0);
                const rowOff = (y0 + iy) * sw + x0;
                for (let ix = ix0; ix < ix1; ix++) {
                    const wx = Math.min(ix + 1, fx1) - Math.max(ix, fx0);
                    const w = wx * wy;
                    const p = (rowOff + ix) * 4;
                    const a = src[p + 3];
                    if (a === 255) {
                        r += src[p] * w;
                        g += src[p + 1] * w;
                        b += src[p + 2] * w;
                    } else {
                        r += Math.floor((src[p] * a + 255 * (255 - a) + 127) / 255) * w;
                        g += Math.floor((src[p + 1] * a + 255 * (255 - a) + 127) / 255) * w;
                        b += Math.floor((src[p + 2] * a + 255 * (255 - a) + 127) / 255) * w;
                    }
                    wsum += w;
                }
            }
            const di = (dy * CARD_W + dx) * 4;
            dst[di] = Math.round(r / wsum);
            dst[di + 1] = Math.round(g / wsum);
            dst[di + 2] = Math.round(b / wsum);
            dst[di + 3] = 255;
        }
    }
    return dst;
}
