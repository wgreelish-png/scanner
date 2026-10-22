/**
 * pokemon-watermark.js - client-side Pokemon (%Ball%) / (Energy Symbol Pattern) / (Team Rocket)
 * text-box watermark detector (200x280 warp -> 18x20 Median-Box DoG correlation).
 */
import { CARD_W, CARD_H, loadRgba200, cardBaseName } from './reprint-rerank.js';
import { AH_PROTOS } from './pokemon-watermark-protos.js';
import { numbersMatch } from '../core/ocr/layouts.js';

const BOX_X0 = 50;
const BOX_Y0 = 142;
const BOX_W = 100;
const BOX_H = 90;
const GRID_R = 18;
const GRID_C = 20;
const CELL = 5;

const PAT_RE = /\(((?:[A-Za-z]+ )?Ball(?: Pattern)?|Energy Symbol(?: Pattern)?|Team Rocket)\)/i;

export function patternNameOf(name, detail) {
    if (detail?.pattern_name) {
        const pm = PAT_RE.exec(`(${detail.pattern_name})`);
        if (pm) return pm[1].trim();
    }
    const m = PAT_RE.exec(String(name || detail?.name || ''));
    return m ? m[1].trim() : '';
}

function sameLeadCard(lead, cand, details) {
    if (!lead || !cand) return false;
    if (lead.ref === cand.ref) return true;
    const b0 = cardBaseName(lead.tuple?.[1] || details?.[lead.ref]?.name || '');
    const bc = cardBaseName(cand.tuple?.[1] || details?.[cand.ref]?.name || '');
    if (!b0 || !bc) return Boolean(details?.[lead.ref]?.variant_siblings?.includes(cand.ref));
    if (b0 !== bc) return false;
    if (Number.isFinite(lead.d) && Number.isFinite(cand.d) && cand.d - lead.d > 2.5) return false;
    return true;
}

/**
 * Extract 18x20 normalized watermark map (Float32Array of length 360) from a 200x280 RGBA buffer.
 * Uses an O(1)-per-pixel sliding 7x7 histogram median filter (<1.2 ms total) + 3-pass 17x17 box DoG.
 */
export function extractWatermarkFromRgba(rgba, width = CARD_W, height = CARD_H) {
    if (!rgba || width !== CARD_W || height !== CARD_H) return null;
    const gray = new Uint8Array(BOX_W * BOX_H);
    for (let y = 0; y < BOX_H; y++) {
        const srcRow = (BOX_Y0 + y) * CARD_W + BOX_X0;
        const dstRow = y * BOX_W;
        for (let x = 0; x < BOX_W; x++) {
            const i = (srcRow + x) * 4;
            gray[dstRow + x] = Math.min(255, Math.max(0, Math.round(
                0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]
            )));
        }
    }

    // Exact 7x7 median filter via sliding 256-bin histogram with border replicate on 100x90
    const med = new Float32Array(BOX_W * BOX_H);
    const hist = new Uint8Array(256);
    for (let y = 0; y < BOX_H; y++) {
        hist.fill(0);
        const y0 = y > 2 ? y - 3 : 0, y1 = y > 1 ? y - 2 : 0, y2 = y > 0 ? y - 1 : 0, y3 = y;
        const y4 = y < BOX_H - 1 ? y + 1 : BOX_H - 1, y5 = y < BOX_H - 2 ? y + 2 : BOX_H - 1, y6 = y < BOX_H - 3 ? y + 3 : BOX_H - 1;
        const r0 = y0 * BOX_W, r1 = y1 * BOX_W, r2 = y2 * BOX_W, r3 = y3 * BOX_W, r4 = y4 * BOX_W, r5 = y5 * BOX_W, r6 = y6 * BOX_W;
        for (let dx = -3; dx <= 3; dx++) {
            const xx = dx < 0 ? 0 : dx;
            hist[gray[r0 + xx]]++; hist[gray[r1 + xx]]++; hist[gray[r2 + xx]]++; hist[gray[r3 + xx]]++;
            hist[gray[r4 + xx]]++; hist[gray[r5 + xx]]++; hist[gray[r6 + xx]]++;
        }
        for (let x = 0; x < BOX_W; x++) {
            let acc = 0, m = 0;
            while (acc < 25) acc += hist[m++];
            med[r3 + x] = m - 1;
            if (x + 1 < BOX_W) {
                const xl = x - 3 < 0 ? 0 : x - 3;
                const xr = x + 4 >= BOX_W ? BOX_W - 1 : x + 4;
                hist[gray[r0 + xl]]--; hist[gray[r1 + xl]]--; hist[gray[r2 + xl]]--; hist[gray[r3 + xl]]--;
                hist[gray[r4 + xl]]--; hist[gray[r5 + xl]]--; hist[gray[r6 + xl]]--;
                hist[gray[r0 + xr]]++; hist[gray[r1 + xr]]++; hist[gray[r2 + xr]]++; hist[gray[r3 + xr]]++;
                hist[gray[r4 + xr]]++; hist[gray[r5 + xr]]++; hist[gray[r6 + xr]]++;
            }
        }
    }

    // 3-pass separable 17x17 box blur with border replicate
    let bg = new Float32Array(med);
    const tmp = new Float32Array(BOX_W * BOX_H);
    for (let pass = 0; pass < 3; pass++) {
        for (let y = 0; y < BOX_H; y++) {
            const rOff = y * BOX_W;
            for (let x = 0; x < BOX_W; x++) {
                let s = 0;
                for (let dx = -8; dx <= 8; dx++) {
                    const xx = x + dx < 0 ? 0 : (x + dx >= BOX_W ? BOX_W - 1 : x + dx);
                    s += bg[rOff + xx];
                }
                tmp[rOff + x] = s / 17;
            }
        }
        for (let y = 0; y < BOX_H; y++) {
            const rOff = y * BOX_W;
            for (let x = 0; x < BOX_W; x++) {
                let s = 0;
                for (let dy = -8; dy <= 8; dy++) {
                    const yy = y + dy < 0 ? 0 : (y + dy >= BOX_H ? BOX_H - 1 : y + dy);
                    s += tmp[yy * BOX_W + x];
                }
                bg[rOff + x] = s / 17;
            }
        }
    }

    // Downsample 100x90 (med - bg) into 18x20 grid (exact 5x5 cells)
    const raw = new Float32Array(GRID_R * GRID_C);
    for (let gr = 0; gr < GRID_R; gr++) {
        for (let gc = 0; gc < GRID_C; gc++) {
            let sum = 0;
            for (let dy = 0; dy < CELL; dy++) {
                const rOff = (gr * CELL + dy) * BOX_W + gc * CELL;
                for (let dx = 0; dx < CELL; dx++) {
                    const idx = rOff + dx;
                    sum += med[idx] - bg[idx];
                }
            }
            raw[gr * GRID_C + gc] = sum / 25;
        }
    }
    return { raw, norm: normalizeWm(raw) };
}

export function normalizeWm(arr) {
    const n = arr.length;
    let sum = 0;
    for (let i = 0; i < n; i++) sum += arr[i];
    const mean = sum / n;
    let sq = 0;
    for (let i = 0; i < n; i++) sq += (arr[i] - mean) ** 2;
    const std = Math.sqrt(sq / n) || 1;
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = (arr[i] - mean) / std;
    return out;
}

export function subtractPlainWm(wm, plainWm, weight = 0.5) {
    if (!wm || !plainWm) return wm;
    const raw = new Float32Array(wm.length);
    for (let i = 0; i < wm.length; i++) raw[i] = wm[i] - weight * plainWm[i];
    return normalizeWm(raw);
}

/** Max correlation over (-1..1, -1..1) shifts on the 18x20 grid. */
export function corrShift(wq, wr) {
    if (!wq || !wr) return -1;
    let best = -Infinity;
    for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
            let sum = 0;
            for (let r = 0; r < GRID_R; r++) {
                const rr = (r - dy + GRID_R) % GRID_R;
                const rOffQ = rr * GRID_C;
                const rOffR = r * GRID_C;
                for (let c = 0; c < GRID_C; c++) {
                    const cc = (c - dx + GRID_C) % GRID_C;
                    sum += wq[rOffQ + cc] * wr[rOffR + c];
                }
            }
            const corr = sum / (GRID_R * GRID_C);
            if (corr > best) best = corr;
        }
    }
    return best;
}

const refWmCache = new Map();

async function getRefWm(ref, src) {
    if (!ref || !src) return null;
    if (!refWmCache.has(ref)) {
        if (refWmCache.size > 128) refWmCache.delete(refWmCache.keys().next().value);
        refWmCache.set(ref, loadRgba200(src).then((rgba) => (rgba ? extractWatermarkFromRgba(rgba) : null)).catch(() => null));
    }
    return await refWmCache.get(ref);
}

/**
 * Pure Stage 3 watermark decision given extracted query watermark `qWm`, candidate list `cands`,
 * `details`, and `realRefWms` (`Map<ref, {raw, norm}>`).
 */
export function decidePokemonWatermarkFromFeatures(qWm, cands, details, realRefWms) {
    if (!qWm || !Array.isArray(cands) || cands.length < 2 || !details) return null;
    const lead = cands[0];
    const famAnchor = cands.find((c) => sameLeadCard(lead, c, details) && (details[c?.ref]?.variant_siblings?.length || 0) >= 2) || lead;
    const anchorDetail = details[famAnchor?.ref];
    const leadDetail = details[lead?.ref];
    const leadPat = patternNameOf(lead?.tuple?.[1], leadDetail);

    const sibSet = new Set(anchorDetail?.variant_siblings || []);
    if (sibSet.size < 2) return null;

    const famCands = cands.filter((c) => sibSet.has(c?.ref) && sameLeadCard(lead, c, details));
    const patCands = famCands.filter((c) => patternNameOf(c?.tuple?.[1], details[c?.ref]));
    if (!patCands.length) return null;

    // Verify that when >=2 real-image pattern refs exist, they actually have distinct watermarks (std >= 6.0)
    const realPatWms = patCands.map((c) => realRefWms.get(c.ref)?.raw).filter(Boolean);
    let lowPatStd = false;
    if (realPatWms.length >= 2) {
        let maxStd = 0;
        for (let i = 0; i < realPatWms.length; i++) {
            for (let j = i + 1; j < realPatWms.length; j++) {
                const a = realPatWms[i], b = realPatWms[j];
                let mean = 0;
                for (let k = 0; k < a.length; k++) mean += a[k] - b[k];
                mean /= a.length;
                let sq = 0;
                for (let k = 0; k < a.length; k++) sq += (a[k] - b[k] - mean) ** 2;
                const std = Math.sqrt(sq / a.length);
                if (std > maxStd) maxStd = std;
            }
        }
        if (maxStd < 6.0) {
            lowPatStd = true;
            if (!leadPat) return null;
        }
    }

    const plainCand = famCands.find((c) => !patternNameOf(c?.tuple?.[1], details[c?.ref]) && realRefWms.has(c.ref));
    const wp = plainCand ? realRefWms.get(plainCand.ref)?.norm : null;
    const wq = wp ? subtractPlainWm(qWm.norm, wp, 0.5) : qWm.norm;
    const plainScore = wp ? corrShift(qWm.norm, wp) : -1;

    if (lowPatStd) {
        if (leadPat && plainCand && plainScore >= 0.42) {
            const proto = AH_PROTOS[leadPat] || AH_PROTOS['Poke Ball'];
            const protoScore = proto ? corrShift(wq, proto) : -1;
            if (protoScore < 0.22 && (protoScore - plainScore) <= -0.25) {
                return plainCand.ref;
            }
        }
        return null;
    }

    const scores = new Map();
    for (const c of patCands) {
        const d = details[c.ref];
        const pat = patternNameOf(c?.tuple?.[1], d);
        if (Number(d?.image_count) > 0 && realRefWms.has(c.ref)) {
            const wr = realRefWms.get(c.ref).norm;
            scores.set(c.ref, corrShift(wq, wp ? subtractPlainWm(wr, wp, 0.5) : wr));
        } else if (Number(d?.image_count) === 0 && pat) {
            const ctype = d?.card_type || anchorDetail?.card_type || '';
            const protoKey = (pat === 'Energy Symbol Pattern' && ctype && AH_PROTOS[`Energy Symbol Pattern:${ctype}`])
                ? `Energy Symbol Pattern:${ctype}`
                : pat;
            const proto = AH_PROTOS[protoKey] || AH_PROTOS[pat];
            if (proto) scores.set(c.ref, corrShift(wq, proto));
        }
    }

    if (!scores.size) return null;

    const realPats = patCands.filter((c) => Number(details[c.ref]?.image_count) > 0 && scores.has(c.ref));
    let bestReal = realPats[0]?.ref || patCands[0]?.ref;
    for (const c of realPats) {
        if (scores.get(c.ref) > (scores.get(bestReal) ?? -Infinity)) bestReal = c.ref;
    }

    let bestRef = bestReal;
    const bestRealScore = scores.get(bestReal) ?? -Infinity;
    for (const c of patCands) {
        if (Number(details[c.ref]?.image_count) === 0 && scores.has(c.ref)) {
            const sc = scores.get(c.ref);
            if (bestRealScore < 0.45 && sc >= 0.48 && sc > (scores.get(bestRef) ?? -Infinity) + 0.12) {
                bestRef = c.ref;
            }
        }
    }

    const bestPatScore = scores.get(bestRef) ?? -Infinity;
    if (leadPat) {
        // When a pattern card currently leads cands[0], demote to the plain sibling if the card has no watermark
        if (plainCand && plainScore >= 0.45 && (bestPatScore - plainScore) <= -0.20) {
            return plainCand.ref;
        }
        return bestRef;
    }

    // When a plain card leads cands[0], only promote to a pattern sibling when the residual watermark is strong
    const minPat = sibSet.has(lead.ref) ? 0.325 : 0.45;
    const minDiff = sibSet.has(lead.ref) ? -0.15 : 0.05;
    if (bestPatScore >= minPat && (plainScore < 0 || (bestPatScore - plainScore) >= minDiff)) {
        return bestRef;
    }
    return null;
}

/**
 * Resolve which Pokemon (%Ball%) / (Energy Symbol Pattern) / (Team Rocket) sibling matches the scanned card's
 * text-box watermark best. Returns the winning candidate `ref` when a pattern sibling wins, else `null`.
 */
export async function detectPokemonVariantRef(row, thumb = null) {
    const cands = row?.cands;
    const details = row?.details;
    if (!Array.isArray(cands) || cands.length < 2 || !details) return null;
    const lead = cands[0];
    const famAnchor = cands.find((c) => sameLeadCard(lead, c, details) && (details[c?.ref]?.variant_siblings?.length || 0) >= 2) || lead;
    const anchorDetail = details[famAnchor?.ref];

    const sibSet = new Set(anchorDetail?.variant_siblings || []);
    if (sibSet.size < 2) return null;

    const famCands = cands.filter((c) => sibSet.has(c?.ref) && sameLeadCard(lead, c, details));
    const patCands = famCands.filter((c) => patternNameOf(c?.tuple?.[1], details[c?.ref]));
    if (!patCands.length) return null;

    let qRgba = null;
    if (thumb?.data && thumb.width === CARD_W && thumb.height === CARD_H) {
        qRgba = thumb.data;
    } else if (!row.full && (row.photo || row.shot)) {
        qRgba = await loadRgba200(row.photo || row.shot);
    }
    const qWm = qRgba ? extractWatermarkFromRgba(qRgba) : null;
    if (!qWm) return null;

    const realRefWms = new Map();
    await Promise.all(famCands.map(async (c) => {
        const d = details[c.ref];
        if (!d || Number(d.image_count) === 0) return;
        const src = d.image || c.tuple?.[6] || '';
        const wm = await getRefWm(c.ref, src);
        if (wm) realRefWms.set(c.ref, wm);
    }));

    return decidePokemonWatermarkFromFeatures(qWm, cands, details, realRefWms);
}

// ---------------------------------------------------------------- Cosmos Holo sibling step
// Some Cosmos Holo printings share name/number/art with a plain sibling and differ only in the
// foil layer; in catalog renders the dark-rim family (mostly modern MCAP/TTBB/SV promos) also has
// a much darker card border. Yellow-border-era pairs have identical rims and must abstain.
// When the pair's catalog rims genuinely differ, the hash distance already separates them
// (catalog ref-vs-ref bh1 ~7 bits): resolve the pair immediately by candidate `d`, ball-pattern
// siblings excluded. Offline on user-confirmed dark-rim pairs: Cosmos wins by >0.5 in 7/24
// Cosmos misses and in 0/45+ plain controls (closest plain control: -0.3); ties abstain.

export const COSMOS_RE = /\(Cosmos? Holo\)/i;
export const COSMOS_RIM_MIN_DIFF = 40;
export const COSMOS_D_MARGIN = 0.5;

const candName = (c, details) => c?.tuple?.[1] || details?.[c?.ref]?.name || '';
const candNumber = (c, details) => c?.tuple?.[2] || details?.[c?.ref]?.number || '';
const candGroup = (c, details) => c?.tuple?.[4] || details?.[c?.ref]?.group_name || '';

export function cosmosPair(cands, details = {}) {
    if (!Array.isArray(cands)) return null;
    const pairs = [];
    for (const cosmos of cands.filter((c) => COSMOS_RE.test(candName(c, details)) && !/\btrick or trade\b/i.test(candGroup(c, details)))) {
        const base = cardBaseName(candName(cosmos, details));
        if (!base) continue;
        const plains = cands.filter((c) => c !== cosmos
            && !COSMOS_RE.test(candName(c, details))
            && !patternNameOf(candName(c, details), details?.[c?.ref])
            && cardBaseName(candName(c, details)) === base
            && numbersMatch(candNumber(c, details), candNumber(cosmos, details)));
        if (plains.length) pairs.push({ cosmos, plains });
    }
    if (pairs.length !== 1) return null;
    const { cosmos, plains } = pairs[0];
    const plain = plains.find((c) => c === cands[0]) || plains[0];
    return { plain, cosmos, plains };
}

/** Distinct non-pattern printings sharing the pair's base name + collector number. */
export function cosmosFamilySize(pack, pair, details = {}) {
    if (pack?.refs && pair) {
        const base = cardBaseName(candName(pair.cosmos, details));
        const num = candNumber(pair.cosmos, details);
        let n = 0;
        for (const t of pack.refs) {
            if (cardBaseName(t[1] || '') === base && numbersMatch(t[2] || '', num) && !patternNameOf(t[1] || '')) n++;
        }
        return n;
    }
    return null;
}

/** Mean luma of the card rim band (2-4% ring) on a 200x280 RGBA image. */
export function rimMean200(rgba) {
    if (!rgba || rgba.length < CARD_W * CARD_H * 4) return null;
    const inset = 0.02, width = 0.02;
    const x0 = Math.floor(CARD_W * inset), x1 = Math.floor(CARD_W * (inset + width));
    const y0 = Math.floor(CARD_H * inset), y1 = Math.floor(CARD_H * (inset + width));
    let s = 0, n = 0;
    for (let y = 0; y < CARD_H; y++) {
        for (let x = 0; x < CARD_W; x++) {
            const inX = (x >= x0 && x < x1) || (x >= CARD_W - x1 && x < CARD_W - x0);
            const inY = (y >= y0 && y < y1) || (y >= CARD_H - y1 && y < CARD_H - y0);
            if (!inX && !inY) continue;
            const o = (y * CARD_W + x) * 4;
            s += 0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2];
            n++;
        }
    }
    return n ? s / n : null;
}

/**
 * Pure Cosmos decision: given candidates and the catalog rim difference
 * (plain rim mean - Cosmos rim mean), return the ref that should lead, else null.
 * Only the dark-rim family (rimDiff >= COSMOS_RIM_MIN_DIFF) is eligible; within the
 * pair the strictly lower hash distance wins. Fail closed on ties/missing data.
 */
export function decideCosmosFromFeatures(cands, rimDiff, details = {}, familySize = null) {
    if (!Array.isArray(cands) || cands.length < 2) return null;
    if (!Number.isFinite(rimDiff) || rimDiff < COSMOS_RIM_MIN_DIFF) return null;
    const pair = cosmosPair(cands, details);
    if (!pair) return null;
    const { plain, cosmos } = pair;
    // A third special sibling with the same number (e.g. Pokemon Day, Prize Pack) breaks
    // the pair assumption: the hash cannot separate two foil promos, so abstain.
    const fam = familySize ?? new Set([cosmos.ref, ...(pair.plains || [plain]).map((c) => c.ref)]).size;
    if (fam !== 2) return null;
    if (!Number.isFinite(plain.d) || !Number.isFinite(cosmos.d)) return null;
    const lead = cands[0];
    if (lead?.ref === plain.ref && cosmos.d < plain.d - COSMOS_D_MARGIN) return cosmos.ref;
    if (lead?.ref === cosmos.ref && plain.d < cosmos.d - COSMOS_D_MARGIN) return plain.ref;
    return null;
}

const refImageSrc = (c, details) => details?.[c?.ref]?.image || c?.tuple?.[6]
    || (/^p:(\d+)$/.exec(c?.ref || '') ? `https://cdn.tcgtracking.com/product/${RegExp.$1}_400w.jpg` : '');

/**
 * Resolve a plain/Cosmos Holo sibling pair by hash distance when their catalog
 * borders genuinely differ. Returns the winning candidate `ref`, else `null`.
 */
export async function detectCosmosRef(row, pack = null) {
    if (pack && pack.game !== 'tcgp:3') return null;
    const cands = row?.cands;
    const details = row?.details || {};
    if (!Array.isArray(cands) || cands.length < 2) return null;
    const pair = cosmosPair(cands, details);
    if (!pair) return null;
    const [plainRgba, cosmosRgba] = await Promise.all([
        loadRgba200(refImageSrc(pair.plain, details)).catch(() => null),
        loadRgba200(refImageSrc(pair.cosmos, details)).catch(() => null),
    ]);
    const plainRim = rimMean200(plainRgba?.data ?? plainRgba);
    const cosmosRim = rimMean200(cosmosRgba?.data ?? cosmosRgba);
    if (plainRim == null || cosmosRim == null) return null;
    const familySize = cosmosFamilySize(pack, pair, details);
    if (familySize == null) return null; // need the pack family to rule out third siblings
    return decideCosmosFromFeatures(cands, plainRim - cosmosRim, details, familySize);
}
