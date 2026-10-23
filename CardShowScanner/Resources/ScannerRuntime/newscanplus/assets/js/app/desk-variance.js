/**
 * desk-variance.js - boxes where two printings of the same card differ.
 *
 * Candidate 0 is the reference. Both stock images are drawn to one canvas size
 * (the smaller natural width, 200..400), turned to contrast-normalized gray, and
 * the selected image is laid over the reference by a small scale + shift. The
 * diff forgives a 1px wobble, so only real changes survive.
 *
 * Printings of the same art differ in a few known ways, so only those are boxed:
 *  - stamps anywhere (promo-pack planeswalker in the art, The List mark): solid,
 *    compact blobs of strong change, measured in brightness and colour so a white
 *    stamp on pale sky still counts;
 *  - the set symbol at the right end of the type line (the symbol-sized window
 *    there with the strongest change, when it clears SYMBOL_SCORE);
 *  - the foot: collector number and set code (connected changed cells).
 *
 * Close match only: when more than GATE_SHARE of the card changed it is a
 * different card or art, and nothing is returned.
 *
 * Catalog JPEGs on cdn.tcgtracking.com send no Access-Control-Allow-Origin, so
 * readableImageUrl points those at the same-origin card-image proxy.
 */
export const GATE_SHARE = 0.06;
const GATE_Z = 1.0;
/** Plain-diff share under which two images are cut from one scan (0.03-0.3%); rescans run 4-5%. */
const EXACT_SHARE = 0.01;
const FOOT_Z = 0.8;
const CELL = 4;
const CELL_HITS = 3;
/** Foot blobs weaker than this share of the strongest one are dropped. */
const KEEP = 0.3;
/** Foot blob mass floor at 400×560; scaled by area for smaller canvases. */
const MIN_MASS = 25;
/** Mean squared change a symbol window needs; identical symbols score ≤0.02, M10 vs M12 0.05-0.16, C20 vs DMC ~0.18. */
const SYMBOL_SCORE = 0.035;
/** Boxes closer than this (card fraction) become one box. */
const JOIN_GAP = 0.03;
/** Room for four changed corners. */
const MAX_RECTS = 4;
/** Symbol score needed when a stamp already explains the variance (Zenos prerelease foil noise ~0.06). */
const SYMBOL_WITH_STAMP = 0.1;
const CORNER_SIDE = 0.06;
/** Corner mass at 400×560: Alpha vs Beta ~580 per corner, other pairs ≤135. */
const CORNER_MASS = 300;
const STAMP_Z = 1.2;
const STAMP_HITS = 5;
/** Stamp mass floor at 400×560: promo stamps score 600-1900, rewrapped rules-text words ≤250. */
const STAMP_MASS = 400;
/** Same for same-scan pairs at their own cutoff: Loyal Tutor's stamp on rubble scores ~440, noise ≤165. */
const EXACT_STAMP_MASS = 300;
/** Same-scan pairs this quiet (Deceit 0.04, Lyra 0.04, Cloud ~0) can show faint stamps: Deceit's grey-on-water stamp scores ~235 at 0.25. */
const CLEAN_NOISE = 0.1;
const CLEAN_STAMP_Z = 0.25;
const CLEAN_STAMP_MASS = 150;
const STAMP_AREA = 0.03;
/** A stamp's longer side, as a share of that card side; promo stamps are ~0.08, specks smaller. */
const STAMP_MIN_SIDE = 0.07;
const STAMP_FILL = 0.35;
/** The type line only: above it the art edge, below it rules text that rewraps between printings. */
export const SYMBOL_ZONE = { x0: 0.8, y0: 0.54, x1: 0.97, y1: 0.635 };
export const FOOT_ZONE = { x0: 0.02, y0: 0.915, x1: 0.98, y1: 0.985 };

/** Matches scoring further than this below match 1 are not near printings, so they are not compared. */
export const NEAR_POINTS = 10;

export function matchPct(cand) {
    const n = Number(cand?.confidence ?? cand?.match_pct);
    return Number.isFinite(n) ? Math.round(n) : null;
}

/** True when match `pick` is worth outlining against match 1: not match 1, and within NEAR_POINTS of it (97 vs 95, not 96 vs 3). */
export function nearMatch(cands, pick) {
    if (!(pick > 0) || !cands?.[pick]) return false;
    const top = matchPct(cands[0]);
    const mine = matchPct(cands[pick]);
    return top !== null && mine !== null && top - mine <= NEAR_POINTS;
}

/** Same-origin URL the canvas is allowed to read, or '' when this src cannot be sampled. */
export function readableImageUrl(src) {
    const text = String(src || '');
    if (text.startsWith('data:') || text.startsWith('blob:') || text.startsWith('/')) return text;
    const m = /^https:\/\/cdn\.tcgtracking\.com\/product\/(\d+)(?:_(\d+))?_(200|400)w\.jpg(?:\?.*)?$/.exec(text);
    if (!m || (m[2] && m[2] !== '1')) return '';
    const face = m[2] === '1' ? '1' : '0';
    return `/newscanplus/api/card-image.php?id=${m[1]}&face=${face}&w=${m[3]}`;
}

/** The 400w file for a catalog CDN image; anything else unchanged. */
export function largeImage(src) {
    const text = String(src || '');
    return /^https:\/\/cdn\.tcgtracking\.com\/product\//.test(text) ? text.replace(/_200w\.jpg/, '_400w.jpg') : text;
}

function gray(rgba, w, h) {
    const n = w * h;
    const g = new Float32Array(n);
    let sum = 0;
    for (let i = 0; i < n; i++) {
        g[i] = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
        sum += g[i];
    }
    const mean = sum / n;
    let sq = 0;
    for (let i = 0; i < n; i++) sq += (g[i] - mean) ** 2;
    const std = Math.sqrt(sq / n) || 1;
    for (let i = 0; i < n; i++) g[i] = (g[i] - mean) / std;
    return g;
}

/** Blue-yellow and red-green opponent planes in luma-std units, so a white stamp on pale sky still shows. */
function chroma(rgba, w, h) {
    const n = w * h;
    const by = new Float32Array(n);
    const rg = new Float32Array(n);
    let sl = 0;
    let sb = 0;
    let sr = 0;
    for (let i = 0; i < n; i++) {
        const r = rgba[i * 4];
        const g = rgba[i * 4 + 1];
        const b = rgba[i * 4 + 2];
        sl += 0.299 * r + 0.587 * g + 0.114 * b;
        by[i] = b - (r + g) / 2;
        rg[i] = r - g;
        sb += by[i];
        sr += rg[i];
    }
    const mean = sl / n;
    let sq = 0;
    for (let i = 0; i < n; i++) sq += (0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2] - mean) ** 2;
    const std = Math.sqrt(sq / n) || 1;
    for (let i = 0; i < n; i++) {
        by[i] = (by[i] - sb / n) / std;
        rg[i] = (rg[i] - sr / n) / std;
    }
    return [by, rg];
}

function sample(g, w, h, x, y) {
    if (x < 0) x = 0;
    else if (x > w - 1) x = w - 1;
    if (y < 0) y = 0;
    else if (y > h - 1) y = h - 1;
    const x0 = x | 0;
    const y0 = y | 0;
    const x1 = x0 < w - 1 ? x0 + 1 : x0;
    const y1 = y0 < h - 1 ? y0 + 1 : y0;
    const fx = x - x0;
    const fy = y - y0;
    return (g[y0 * w + x0] * (1 - fx) + g[y0 * w + x1] * fx) * (1 - fy) + (g[y1 * w + x0] * (1 - fx) + g[y1 * w + x1] * fx) * fy;
}

/** g resampled by scale (sx, sy) about the centre plus shift (dx, dy). */
function warp(g, w, h, t) {
    const out = new Float32Array(w * h);
    const cx = (w - 1) / 2;
    const cy = (h - 1) / 2;
    for (let y = 0; y < h; y++) {
        const by = cy + (y - cy) * t.sy + t.dy;
        for (let x = 0; x < w; x++) out[y * w + x] = sample(g, w, h, cx + (x - cx) * t.sx + t.dx, by);
    }
    return out;
}

function fitCost(a, b, w, h, t, step) {
    const cx = (w - 1) / 2;
    const cy = (h - 1) / 2;
    const m = Math.round(w * 0.06);
    let c = 0;
    for (let y = m; y < h - m; y += step) {
        const by = cy + (y - cy) * t.sy + t.dy;
        for (let x = m; x < w - m; x += step) c += Math.abs(a[y * w + x] - sample(b, w, h, cx + (x - cx) * t.sx + t.dx, by));
    }
    return c;
}

/** Scale + shift that lays b over a: a coarse grid, then two finer passes. Scans of reprints differ by ~1% in crop. */
function align(a, b, w, h) {
    let best = { sx: 1, sy: 1, dx: 0, dy: 0 };
    let bestCost = Infinity;
    const span = Math.max(2, Math.round(w * 0.01));
    const step = Math.max(4, Math.round(w / 50));
    for (let s = -2; s <= 2; s++) {
        for (let r = -2; r <= 2; r++) {
            for (let dy = -span; dy <= span; dy++) {
                for (let dx = -span; dx <= span; dx++) {
                    const t = { sx: 1 + s * 0.01, sy: 1 + r * 0.01, dx, dy };
                    const c = fitCost(a, b, w, h, t, step);
                    if (c < bestCost) {
                        bestCost = c;
                        best = t;
                    }
                }
            }
        }
    }
    for (const fine of [0.5, 0.25]) {
        const base = best;
        bestCost = Infinity;
        for (let s = -1; s <= 1; s++) {
            for (let r = -1; r <= 1; r++) {
                for (let dy = -1; dy <= 1; dy++) {
                    for (let dx = -1; dx <= 1; dx++) {
                        const t = { sx: base.sx + s * 0.01 * fine, sy: base.sy + r * 0.01 * fine, dx: base.dx + dx * fine, dy: base.dy + dy * fine };
                        const c = fitCost(a, b, w, h, t, 2);
                        if (c < bestCost) {
                            bestCost = c;
                            best = t;
                        }
                    }
                }
            }
        }
    }
    return best;
}

/** Change map inside zone z after re-seating b over a by a local sub-pixel shift; the global fit drifts near the card edges. */
function zoneDiff(a, b, w, h, z, exact = false) {
    const r = zonePx(z, w, h);
    let best = { dx: 0, dy: 0 };
    let bestCost = Infinity;
    for (let dy = -3; dy <= 3; dy += 0.5) {
        for (let dx = -3; dx <= 3; dx += 0.5) {
            let c = 0;
            for (let y = r.y0; y < r.y1; y += 2) for (let x = r.x0; x < r.x1; x += 2) c += Math.abs(a[y * w + x] - sample(b, w, h, x + dx, y + dy));
            if (c < bestCost) {
                bestCost = c;
                best = { dx, dy };
            }
        }
    }
    const moved = new Float32Array(w * h);
    for (let y = Math.max(0, r.y0 - 1); y < Math.min(h, r.y1 + 1); y++) {
        for (let x = Math.max(0, r.x0 - 1); x < Math.min(w, r.x1 + 1); x++) moved[y * w + x] = sample(b, w, h, x + best.dx, y + best.dy);
    }
    return exact ? plainDiff(a, moved, w, h, z) : looseDiff(a, moved, w, h, z);
}

/** |a - b| per pixel inside zone z, for pairs cut from one scan where 1px strokes must count. */
function plainDiff(a, b, w, h, z) {
    const d = new Float32Array(w * h);
    const r = zonePx(z, w, h);
    for (let y = r.y0; y < r.y1; y++) {
        for (let x = r.x0; x < r.x1; x++) d[y * w + x] = Math.abs(a[y * w + x] - b[y * w + x]);
    }
    return d;
}

/** Share of the card that changed with no wobble forgiveness; same-scan reprints stay under EXACT_SHARE, rescans do not. */
function plainShare(a, b) {
    let n = 0;
    for (let i = 0; i < a.length; i++) if (Math.abs(a[i] - b[i]) > GATE_Z) n++;
    return n / a.length;
}

/** Per-pixel change that forgives a 1px wobble: a pixel counts only if it misses the whole 3×3 on the other side, both ways. */
function looseDiff(a, b, w, h, z = { x0: 0, y0: 0, x1: 1, y1: 1 }) {
    const d = new Float32Array(w * h);
    const r = zonePx(z, w, h);
    for (let y = Math.max(1, r.y0); y < Math.min(h - 1, r.y1); y++) {
        for (let x = Math.max(1, r.x0); x < Math.min(w - 1, r.x1); x++) {
            const i = y * w + x;
            let ab = Infinity;
            let ba = Infinity;
            for (let oy = -w; oy <= w; oy += w) {
                for (let ox = -1; ox <= 1; ox++) {
                    const j = i + oy + ox;
                    const p = Math.abs(a[i] - b[j]);
                    if (p < ab) ab = p;
                    const q = Math.abs(b[i] - a[j]);
                    if (q < ba) ba = q;
                }
            }
            d[i] = ab > ba ? ab : ba;
        }
    }
    return d;
}

function zonePx(z, w, h) {
    return { x0: Math.round(z.x0 * w), y0: Math.round(z.y0 * h), x1: Math.round(z.x1 * w), y1: Math.round(z.y1 * h) };
}

/** The symbol-sized window in the type-line zone with the strongest change, or null when it is no stronger than scan noise. */
function symbolBox(d, w, h) {
    const z = zonePx(SYMBOL_ZONE, w, h);
    const s = Math.max(6, Math.round(w * 0.05));
    let best = null;
    for (let y = z.y0; y + s <= z.y1; y += 2) {
        for (let x = z.x0; x + s <= z.x1; x += 2) {
            let sum = 0;
            for (let yy = y; yy < y + s; yy++) {
                for (let xx = x; xx < x + s; xx++) {
                    const v = d[yy * w + xx];
                    sum += v * v;
                }
            }
            const score = sum / (s * s);
            if (!best || score > best.score) best = { x: x + s / 2, y: y + s / 2, score };
        }
    }
    if (!best || best.score < SYMBOL_SCORE) return null;
    let mx = 0;
    let my = 0;
    let m = 0;
    for (let y = Math.max(z.y0, Math.round(best.y - s)); y < Math.min(z.y1, Math.round(best.y + s)); y++) {
        for (let x = Math.max(z.x0, Math.round(best.x - s)); x < Math.min(z.x1, Math.round(best.x + s)); x++) {
            const v = d[y * w + x] ** 2;
            mx += x * v;
            my += y * v;
            m += v;
        }
    }
    const cx = m ? mx / m : best.x;
    const cy = m ? my / m : best.y;
    // Wide enough for the widest symbols (M10-era "M10" badges are ~0.09 of the card).
    const halfW = s * 0.9;
    const halfH = s * 0.65;
    return { x0: cx - halfW, y0: cy - halfH, x1: cx + halfW, y1: cy + halfH, score: best.score };
}

/** Connected changed cells along the foot, strongest first, weak ones dropped. */
function footBoxes(d, w, h, cut = FOOT_Z) {
    const z = zonePx(FOOT_ZONE, w, h);
    const cw = Math.ceil((z.x1 - z.x0) / CELL);
    const ch = Math.ceil((z.y1 - z.y0) / CELL);
    const hits = new Uint16Array(cw * ch);
    const mass = new Float32Array(cw * ch);
    for (let y = z.y0; y < z.y1; y++) {
        for (let x = z.x0; x < z.x1; x++) {
            const v = d[y * w + x];
            if (v <= cut) continue;
            const c = (((y - z.y0) / CELL) | 0) * cw + (((x - z.x0) / CELL) | 0);
            hits[c]++;
            mass[c] += v;
        }
    }
    const seen = new Uint8Array(cw * ch);
    const blobs = [];
    for (let start = 0; start < hits.length; start++) {
        if (hits[start] < CELL_HITS || seen[start]) continue;
        let x0 = cw;
        let y0 = ch;
        let x1 = -1;
        let y1 = -1;
        let m = 0;
        const stack = [start];
        seen[start] = 1;
        while (stack.length) {
            const i = stack.pop();
            const cx = i % cw;
            const cy = (i - cx) / cw;
            x0 = Math.min(x0, cx);
            y0 = Math.min(y0, cy);
            x1 = Math.max(x1, cx);
            y1 = Math.max(y1, cy);
            m += mass[i];
            // Wide reach so one line of small type (number, set code) joins into a single box.
            for (let oy = -3; oy <= 3; oy++) {
                for (let ox = -6; ox <= 6; ox++) {
                    const nx = cx + ox;
                    const ny = cy + oy;
                    if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
                    const j = ny * cw + nx;
                    if (hits[j] >= CELL_HITS && !seen[j]) {
                        seen[j] = 1;
                        stack.push(j);
                    }
                }
            }
        }
        blobs.push({
            x0: z.x0 + x0 * CELL,
            y0: z.y0 + y0 * CELL,
            x1: Math.min(z.x1, z.x0 + (x1 + 1) * CELL),
            y1: Math.min(z.y1, z.y0 + (y1 + 1) * CELL),
            m,
        });
    }
    const floor = MIN_MASS * ((w * h) / (400 * 560));
    const kept = blobs.filter((b) => b.m >= floor);
    const top = Math.max(0, ...kept.map((b) => b.m));
    return kept.filter((b) => b.m >= top * KEEP).sort((p, q) => q.m - p.m);
}

/** 99th-percentile change of a same-scan pair: ~0 for clean pairs, ~0.3 Loyal Tutor, ~0.65 JPEG-noisier foils and M10 vs M12. */
function noiseFloor(d) {
    const s = Float32Array.from(d).sort();
    return s[Math.floor(s.length * 0.99)];
}

/** Changed corner squares when at least two corners changed: Alpha's rounder corners vs Beta. */
function cornerBoxes(d, w, h) {
    const c = Math.round(w * CORNER_SIDE);
    const scale = (w * h) / (400 * 560);
    const hit = [[0, 0], [w - c, 0], [0, h - c], [w - c, h - c]]
        .map(([x0, y0]) => {
            let m = 0;
            for (let y = y0; y < y0 + c; y++) for (let x = x0; x < x0 + c; x++) m += d[y * w + x];
            return { x0, y0, x1: x0 + c, y1: y0 + c, m: m / scale, kind: 'corner' };
        })
        .filter((b) => b.m >= CORNER_MASS);
    return hit.length >= 2 ? hit : [];
}

/** Strong, compact changes anywhere on the card (promo and prerelease stamps in the art). */
function stampBoxes(d, w, h, zCut, minMass) {
    const cw = Math.ceil(w / CELL);
    const ch = Math.ceil(h / CELL);
    const hits = new Uint16Array(cw * ch);
    const mass = new Float32Array(cw * ch);
    for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
            const v = d[y * w + x];
            if (v <= zCut) continue;
            const c = ((y / CELL) | 0) * cw + ((x / CELL) | 0);
            hits[c]++;
            mass[c] += v;
        }
    }
    const need = STAMP_HITS;
    const seen = new Uint8Array(cw * ch);
    const out = [];
    for (let start = 0; start < hits.length; start++) {
        if (hits[start] < need || seen[start]) continue;
        let x0 = cw;
        let y0 = ch;
        let x1 = -1;
        let y1 = -1;
        let m = 0;
        let n = 0;
        const stack = [start];
        seen[start] = 1;
        while (stack.length) {
            const i = stack.pop();
            const cx = i % cw;
            const cy = (i - cx) / cw;
            x0 = Math.min(x0, cx);
            y0 = Math.min(y0, cy);
            x1 = Math.max(x1, cx);
            y1 = Math.max(y1, cy);
            m += mass[i];
            n++;
            for (let oy = -1; oy <= 1; oy++) {
                for (let ox = -1; ox <= 1; ox++) {
                    const nx = cx + ox;
                    const ny = cy + oy;
                    if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
                    const j = ny * cw + nx;
                    if (hits[j] >= need && !seen[j]) {
                        seen[j] = 1;
                        stack.push(j);
                    }
                }
            }
        }
        out.push({ x0: x0 * CELL, y0: y0 * CELL, x1: Math.min(w, (x1 + 1) * CELL), y1: Math.min(h, (y1 + 1) * CELL), m, n });
    }
    const scale = (w * h) / (400 * 560);
    return out
        .filter((b) => {
            const px = (b.x1 - b.x0) * (b.y1 - b.y0);
            // Solid: a stamp fills its box; scattered rewrap or ghosting does not.
            const side = Math.max((b.x1 - b.x0) / w, (b.y1 - b.y0) / h);
            return b.m >= minMass * scale && side >= STAMP_MIN_SIDE && px / (w * h) <= STAMP_AREA && (b.n * CELL * CELL) / px >= STAMP_FILL;
        })
        .sort((p, q) => q.m - p.m);
}

/**
 * Pure diff of two same-size RGBA buffers (a is the reference).
 * @returns {{x:number,y:number,w:number,h:number}[]} rects in 0..1 card coordinates
 */
export function diffRects(rgbaA, rgbaB, w, h) {
    if (!rgbaA || !rgbaB || rgbaA.length < w * h * 4 || rgbaB.length < w * h * 4) return [];
    const a = gray(rgbaA, w, h);
    const b0 = gray(rgbaB, w, h);
    const t = align(a, b0, w, h);
    const b = warp(b0, w, h, t);
    const whole = looseDiff(a, b, w, h);
    let changed = 0;
    for (let i = 0; i < whole.length; i++) if (whole[i] > GATE_Z) changed++;
    // No luma change can still hide a faint grey stamp on dark water (Deceit promo), so zero is not a reason to stop.
    if (changed / (w * h) > GATE_SHARE) return [];
    const exact = plainShare(a, b) < EXACT_SHARE;
    const ca = chroma(rgbaA, w, h);
    const cb = chroma(rgbaB, w, h).map((p) => warp(p, w, h, t));
    const card = { x0: 0, y0: 0, x1: 1, y1: 1 };
    const diff = exact ? plainDiff : looseDiff;
    const lum = exact ? plainDiff(a, b, w, h, card) : whole;
    const dBy = diff(ca[0], cb[0], w, h, card);
    const dRg = diff(ca[1], cb[1], w, h, card);
    const color = new Float32Array(w * h);
    for (let i = 0; i < color.length; i++) color[i] = Math.hypot(lum[i], dBy[i], dRg[i]);
    // Same-scan pairs: cutoffs follow the pair's own noise, so a stamp on grey rubble counts and foil JPEG noise does not.
    const noise = exact ? noiseFloor(color) : 0;
    const clean = exact && noise < CLEAN_NOISE;
    const stamps = !exact
        ? stampBoxes(color, w, h, STAMP_Z, STAMP_MASS)
        : clean
          ? stampBoxes(color, w, h, CLEAN_STAMP_Z, CLEAN_STAMP_MASS)
          : stampBoxes(color, w, h, Math.max(0.6, 1.5 * noise), EXACT_STAMP_MASS);
    const corners = cornerBoxes(color, w, h);
    const sym = symbolBox(zoneDiff(a, b, w, h, SYMBOL_ZONE), w, h);
    const foot = footBoxes(zoneDiff(a, b, w, h, FOOT_ZONE, exact), w, h, Math.max(FOOT_Z, 1.5 * noise));
    const pad = Math.max(2, Math.round(w * 0.008));
    const clear = (r) => !stamps.some((s) => r.x0 < s.x1 && s.x0 < r.x1 && r.y0 < s.y1 && s.y0 < r.y1);
    // A symbol window touching a stamp is the stamp's edge; with a stamp elsewhere, promo printings keep the set symbol.
    const keepSym = sym && clear(sym) && (!stamps.length || sym.score >= SYMBOL_WITH_STAMP);
    const rects = [...stamps, ...corners, ...(keepSym ? [sym] : []), ...foot].map((r) => {
        const x0 = Math.max(0, r.x0 - pad);
        const y0 = Math.max(0, r.y0 - pad);
        const x1 = Math.min(w, r.x1 + pad);
        const y1 = Math.min(h, r.y1 + pad);
        const box = { x: x0 / w, y: y0 / h, w: (x1 - x0) / w, h: (y1 - y0) / h };
        return r.kind ? { ...box, kind: r.kind } : box;
    });
    const joined = [...joinClose(rects.filter((r) => !r.kind)), ...rects.filter((r) => r.kind)];
    const order = (r) => (r.kind ? 1 : 0);
    return joined.sort((p, q) => order(p) - order(q)).slice(0, MAX_RECTS);
}

/** Merges rects that overlap or sit within JOIN_GAP of each other, keeping the first one's place in the order. */
export function joinClose(rects) {
    const list = rects.map((r) => ({ ...r }));
    for (let merged = true; merged; ) {
        merged = false;
        for (let i = 0; i < list.length && !merged; i++) {
            for (let j = i + 1; j < list.length; j++) {
                const p = list[i];
                const q = list[j];
                const apartX = Math.max(p.x, q.x) - Math.min(p.x + p.w, q.x + q.w);
                const apartY = Math.max(p.y, q.y) - Math.min(p.y + p.h, q.y + q.h);
                if (apartX > JOIN_GAP || apartY > JOIN_GAP) continue;
                const x = Math.min(p.x, q.x);
                const y = Math.min(p.y, q.y);
                list[i] = { x, y, w: Math.max(p.x + p.w, q.x + q.w) - x, h: Math.max(p.y + p.h, q.y + q.h) - y };
                list.splice(j, 1);
                merged = true;
                break;
            }
        }
    }
    return list;
}

/** Rects bigger than this share of the card get an outline but no zoom. */
const ZOOM_AREA = 0.02;
const ZOOM_MAX_W = 0.46;
const ZOOM_MAX_H = 0.3;
const ZOOM_GAP = 0.05;

function overlaps(p, q) {
    return p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h;
}

/**
 * Where to show a 2-3x zoom of rect r (card fractions), beside it toward the card centre and clear of `avoid`.
 * @returns {{x:number,y:number,w:number,h:number,zoom:number}|null} null when r is too big or no clear spot exists
 */
export function zoomBox(r, avoid = []) {
    if (!r || r.w * r.h > ZOOM_AREA) return null;
    const zoom = Math.min(3, ZOOM_MAX_W / r.w, ZOOM_MAX_H / r.h);
    if (zoom < 2) return null;
    const w = r.w * zoom;
    const h = r.h * zoom;
    const clamp = (v, size) => Math.min(0.98 - size, Math.max(0.02, v));
    const x = clamp(r.x + r.w / 2 > 0.5 ? r.x - ZOOM_GAP - w : r.x + r.w + ZOOM_GAP, w);
    const y = clamp(r.y + r.h / 2 > 0.4 ? r.y - ZOOM_GAP - h : r.y + r.h + ZOOM_GAP, h);
    const box = { x, y, w, h, zoom };
    return overlaps(box, r) || avoid.some((o) => overlaps(box, o)) ? null : box;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
/** Arrow space matches the card's 5:7 shape so arrowheads are not squashed. */
const ART_W = 500;
const ART_H = 700;

function placed(tag, cls, r) {
    const node = document.createElement(tag);
    node.className = cls;
    node.style.left = `${r.x * 100}%`;
    node.style.top = `${r.y * 100}%`;
    node.style.width = `${r.w * 100}%`;
    node.style.height = `${r.h * 100}%`;
    return node;
}

/** Point where the ray from box b's centre toward (tx, ty) leaves b, in arrow space. */
function edgePoint(b, tx, ty) {
    const cx = (b.x + b.w / 2) * ART_W;
    const cy = (b.y + b.h / 2) * ART_H;
    const dx = tx - cx;
    const dy = ty - cy;
    const t = Math.min(dx ? (b.w * ART_W) / 2 / Math.abs(dx) : Infinity, dy ? (b.h * ART_H) / 2 / Math.abs(dy) : Infinity, 1);
    return [cx + dx * t, cy + dy * t];
}

/** Arrow from the zoom box edge to the outlined rect edge, head at the rect. */
function arrowBetween(from, to) {
    const [x1, y1] = edgePoint(from, (to.x + to.w / 2) * ART_W, (to.y + to.h / 2) * ART_H);
    const [x2, y2] = edgePoint(to, (from.x + from.w / 2) * ART_W, (from.y + from.h / 2) * ART_H);
    const len = Math.hypot(x2 - x1, y2 - y1) || 1;
    const ux = (x2 - x1) / len;
    const uy = (y2 - y1) / len;
    const head = 14;
    const bx = x2 - ux * head;
    const by = y2 - uy * head;
    const g = document.createElementNS(SVG_NS, 'g');
    const line = document.createElementNS(SVG_NS, 'line');
    line.setAttribute('x1', x1.toFixed(1));
    line.setAttribute('y1', y1.toFixed(1));
    line.setAttribute('x2', bx.toFixed(1));
    line.setAttribute('y2', by.toFixed(1));
    const tip = document.createElementNS(SVG_NS, 'polygon');
    tip.setAttribute('points', [
        [x2, y2],
        [bx - uy * head * 0.55, by + ux * head * 0.55],
        [bx + uy * head * 0.55, by - ux * head * 0.55],
    ].map((p) => p.map((v) => v.toFixed(1)).join(',')).join(' '));
    g.append(line, tip);
    return g;
}

/** Glowing outlines on `art` (the box the card image fills), plus a zoom and arrow for each small rect. */
export function drawVariance(art, rects, src) {
    const veil = document.createElement('span');
    veil.className = 'nsp-walk-var';
    veil.setAttribute('aria-hidden', 'true');
    const arrows = document.createElementNS(SVG_NS, 'svg');
    arrows.setAttribute('class', 'nsp-walk-var-arrows');
    arrows.setAttribute('viewBox', `0 0 ${ART_W} ${ART_H}`);
    arrows.setAttribute('preserveAspectRatio', 'none');
    const taken = [...rects];
    let cornerZoomed = false;
    for (const r of rects) {
        veil.append(placed('span', 'nsp-walk-var-box', r));
        // Four matching corners need one zoom, not four.
        const z = src && !(r.kind === 'corner' && cornerZoomed) ? zoomBox(r, taken) : null;
        if (z && r.kind === 'corner') cornerZoomed = true;
        if (!z) continue;
        taken.push(z);
        const lens = placed('span', 'nsp-walk-var-zoom', z);
        lens.style.backgroundImage = `url("${String(src).replace(/"/g, '%22')}")`;
        lens.style.backgroundSize = `${100 / r.w}% ${100 / r.h}%`;
        lens.style.backgroundPosition = `${(r.x / (1 - r.w)) * 100}% ${(r.y / (1 - r.h)) * 100}%`;
        veil.append(lens);
        arrows.append(arrowBetween(z, r));
    }
    if (arrows.childNodes.length) veil.prepend(arrows);
    art.append(veil);
    return veil;
}

function canSample() {
    return typeof document !== 'undefined' && typeof Image === 'function';
}

function loadImage(src) {
    return new Promise((resolve) => {
        const url = readableImageUrl(src);
        if (!url || !canSample()) {
            resolve(null);
            return;
        }
        try {
            const img = new Image();
            img.onload = () => resolve(img.naturalWidth && img.naturalHeight ? img : null);
            img.onerror = () => resolve(null);
            img.src = url;
        } catch {
            resolve(null);
        }
    });
}

function pixels(img, w, h) {
    try {
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d', { willReadFrequently: true });
        if (!ctx) return null;
        ctx.drawImage(img, 0, 0, w, h);
        return ctx.getImageData(0, 0, w, h).data;
    } catch {
        return null;
    }
}

const memo = new Map();

async function measure(refSrc, otherSrc) {
    const [ref, other] = await Promise.all([loadImage(refSrc), loadImage(otherSrc)]);
    if (!ref || !other) return [];
    // Some "400w" files are smaller (265w); upscaling one side adds no detail.
    const w = Math.max(200, Math.min(400, ref.naturalWidth, other.naturalWidth)) & ~1;
    const h = Math.round(w * 1.4);
    const a = pixels(ref, w, h);
    const b = pixels(other, w, h);
    if (!a || !b) return [];
    return diffRects(a, b, w, h);
}

/** Rects where `otherSrc` differs from `refSrc`, or [] on any failure. Cached per pair. */
export async function varianceRects(refSrc, otherSrc) {
    try {
        const ref = largeImage(refSrc);
        const other = largeImage(otherSrc);
        if (!ref || !other || ref === other || !canSample()) return [];
        const key = `${ref}|${other}`;
        if (!memo.has(key)) {
            if (memo.size > 64) memo.delete(memo.keys().next().value);
            memo.set(key, measure(ref, other).catch(() => []));
        }
        return await memo.get(key);
    } catch {
        return [];
    }
}
