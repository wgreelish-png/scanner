/**
 * tiebreak.js - re-rank hash top-K / same-art printings from the collector corner.
 *
 * tieBreak({card, game, cands, refCards?, refCorners?}) ->
 *   {number, conf, boosts:{ref:delta}, decided_ref|null, text, ms, via, ncc, skipped}
 *   card: {data,width,height,channels?} RGBA or RGB, or a cv.Mat (copied immediately).
 *         The 600x840 warp (warpOcrCard), not the 200x280 hash warp.
 *   cands: [{ref, number, set_abbr}]  hash top-K and/or same-art printings. Not a catalog lookup.
 *   refCards: [{ref, data, width, height, channels?}] full reference cards, any size.
 *   refCorners: [{ref, data, width, height}] already-cropped search windows (larger than the query corner).
 *   boosts values are OCR_DELTA / NCC_DELTA (-8), added to bh1 distance only when sorting this list.
 *   decided_ref is set only when one candidate's printed number is singled out. When the collector line
 *   also shows a candidate's set code ("FDC · EN"), only candidates from that set can be singled out;
 *   MTG Promo Pack (PP + code) and Prerelease (PRE) prints show their base set's code and stay in.
 *   It is a picker preselect. It must not flip `accepted`.
 * setCodesIn(text, cands) -> Set of candidate set codes that appear as whole tokens in the OCR text.
 *
 * cornerNCC(queryCorner, refCornerImages) -> number[]
 *   Gray normalised cross-correlation. Each ref image should be the corner expanded by ±3% of the
 *   card (the query is the tight corner); the query is slid across that window.
 *   cdn.tcgtracking.com product JPEGs send no Access-Control-Allow-Origin (checked 2026-10-06),
 *   so a page canvas cannot read them. loadRefCard() returns null and tieBreak stays OCR-only
 *   until the caller already has pixels.
 *
 * applyBoosts(result, tb, refOf) reorders result.top in place's copy. accepted and gap are unchanged.
 *   When accepted, best.i moves only among best.siblings. When not accepted, best.i follows a
 *   promoted top row so the picker highlights it. Hash `d` / match_pct are not rewritten with the delta.
 * shouldTieBreak(cands) is true when at least two candidates have different canon numbers.
 * preselectRef(options, tb) -> index in printingOptions() whose ref is decided_ref, or -1.
 * warpOcrCard(frame, quad) -> cv.Mat CV_8UC3 RGB 600x840. Same perspective as core/warp.js
 *   (dst corners at 0 and at OCR_W/OCR_H, INTER_LINEAR) with no INTER_AREA downsample. Caller deletes.
 *
 * Integration (master; do not run this in the phone live loop):
 *   1. quickscan-worker.js scanImage, after scanImagePasses, while `image` is still the RGBA
 *      the quads were scaled back onto. Not in scan() / scan-engine.js.
 *   2. The worker pack message today is {n, lo, hi, cl} and image-scan setPack drops refs.
 *      Send pack.refs (or {ref, number, abbr} per index) with the pack so the worker can build
 *      cands from result.top and result.best.siblings. image-scan copies siblings but drops
 *      best.printing; siblings plus top is the candidate set.
 *   3. Call only when !result.accepted or best.siblings.length, AND shouldTieBreak(cands).
 *      Also on an explicit desktop "read the number" message, same warp.
 *   4. const mat = rgbaMat(image); const warp = warpOcrCard(mat, card.quad); try { tb = await tieBreak(...) }
 *      finally { warp.delete(); mat.delete(); }
 *      card.result = applyBoosts(card.result, tb, (i) => refs[i][0]);
 *   5. Main-thread fallback is scan-backends.js mainBackend.scanImage, which still holds `image` and pack.refs.
 *   6. Picker: if result.ocr.decided_ref, preselectRef(printingOptions(...), result.ocr) wins over the
 *      catalog primary. Leave accepted as the hash gap left it.
 *   7. Yu-Gi-Oh (layout.ocr false) and generic games: no recogniser. NCC runs for Yu-Gi-Oh only when
 *      ref pixels were passed in. CDN corners are not readable (CDN_CORS false) — OCR-only otherwise.
 *   8. loadOcr() downloads ~4.6 MB det + ~4.3 MB rec + ~11 MB WASM once per worker. First call is cold.
 */
import { cv } from '../cv.js';
import { recognizeCorner } from './engine.js';
import {
    OCR_W, OCR_H, layoutFor, cropPixels, canonNumber, numbersMatch, fractionsIn,
} from './layouts.js';
import { matchYugiohCandidatesByOcr } from '../../app/variants/yugioh.js';

export { OCR_W, OCR_H };

export const OCR_DELTA = -8;
export const NCC_DELTA = -8;
export const NCC_GAP = 0.05;
export const CDN_CORS = false;
const LIST_ABBR_RE = /^P?LIST$/i;

function hHasDistinctCode(ocrNum, hit) {
    const n = String(ocrNum || '');
    const cn = String(hit?.number || '');
    if (n.includes('/') && cn.includes('/')) return canonNumber(n) === canonNumber(cn);
    return /[A-Za-z]/.test(n) && n.includes('-');
}

export function shouldTieBreak(cands) {
    const seen = new Set();
    for (const c of cands || []) {
        const n = canonNumber(c.number || '');
        if (!n) continue;
        seen.add(n);
        if (seen.size >= 2) return true;
    }
    return false;
}

export function warpOcrCard(frame, quad) {
    if (!cv) throw new Error('OpenCV is not ready');
    const src = cv.matFromArray(4, 1, cv.CV_32FC2, quad.flat());
    const dst = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, OCR_W, 0, OCR_W, OCR_H, 0, OCR_H]);
    const M = cv.getPerspectiveTransform(src, dst);
    const out = new cv.Mat();
    try {
        cv.warpPerspective(frame, out, M, new cv.Size(OCR_W, OCR_H), cv.INTER_LINEAR, cv.BORDER_CONSTANT, new cv.Scalar());
        if (out.channels() === 4) cv.cvtColor(out, out, cv.COLOR_RGBA2RGB);
        return out;
    } catch (e) {
        out.delete();
        throw e;
    } finally {
        src.delete();
        dst.delete();
        M.delete();
    }
}

function cardPixels(card) {
    if (card && card.data && card.width && card.height) {
        const ch = card.channels || ((card.data.length / (card.width * card.height)) | 0);
        const data = card.data instanceof Uint8Array ? card.data : new Uint8Array(card.data);
        return { data, width: card.width, height: card.height, channels: ch };
    }
    const m = card && (card.mat || card);
    if (m && m.cols && m.data) {
        return { data: new Uint8Array(m.data), width: m.cols, height: m.rows, channels: m.channels() };
    }
    throw new Error('tieBreak card needs pixels or a cv.Mat');
}

function resizeTo(img, tw, th) {
    if (img.width === tw && img.height === th) return img;
    if (!cv) throw new Error('OpenCV is not ready');
    const ch = img.channels || ((img.data.length / (img.width * img.height)) | 0);
    const type = ch === 4 ? cv.CV_8UC4 : ch === 1 ? cv.CV_8UC1 : cv.CV_8UC3;
    const src = new cv.Mat(img.height, img.width, type);
    const dst = new cv.Mat();
    try {
        src.data.set(img.data);
        const down = tw <= img.width && th <= img.height;
        cv.resize(src, dst, new cv.Size(tw, th), 0, 0, down ? cv.INTER_AREA : cv.INTER_LINEAR);
        return { data: new Uint8Array(dst.data), width: dst.cols, height: dst.rows, channels: ch };
    } finally {
        src.delete();
        dst.delete();
    }
}

export function expandRegion(region, shift = 0.03) {
    let x = region[0] - shift;
    let y = region[1] - shift;
    let w = region[2] + 2 * shift;
    let h = region[3] + 2 * shift;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > 1) w = 1 - x;
    if (y + h > 1) h = 1 - y;
    return [x, y, Math.max(0.01, w), Math.max(0.01, h)];
}

function toGray(img) {
    const w = img.width, h = img.height;
    const ch = img.channels || ((img.data.length / (w * h)) | 0);
    const g = new Float32Array(w * h);
    const d = img.data;
    if (ch === 1) {
        for (let i = 0; i < w * h; i++) g[i] = d[i];
        return { data: g, width: w, height: h };
    }
    for (let i = 0, p = 0; i < w * h; i++, p += ch) {
        const r = d[p], gc = d[p + 1], b = d[p + 2] || 0;
        g[i] = 0.299 * r + 0.587 * gc + 0.114 * b;
    }
    return { data: g, width: w, height: h };
}

function nccSlide(q, s) {
    if (s.width < q.width || s.height < q.height) s = fitGray(s, q.width, q.height);
    const qw = q.width, qh = q.height, sw = s.width, n = qw * qh;
    const qd = q.data, sd = s.data;
    let sumT = 0, sumT2 = 0;
    for (let i = 0; i < n; i++) { sumT += qd[i]; sumT2 += qd[i] * qd[i]; }
    const qvar = n * sumT2 - sumT * sumT;
    if (qvar < 1e-3) return 0;
    let best = -1;
    for (let y = 0; y <= s.height - qh; y++) {
        for (let x = 0; x <= sw - qw; x++) {
            let sumI = 0, sumI2 = 0, cross = 0;
            for (let yy = 0; yy < qh; yy++) {
                const rs = (y + yy) * sw + x;
                const qs = yy * qw;
                for (let xx = 0; xx < qw; xx++) {
                    const iv = sd[rs + xx];
                    sumI += iv;
                    sumI2 += iv * iv;
                    cross += qd[qs + xx] * iv;
                }
            }
            const ivar = n * sumI2 - sumI * sumI;
            const den = Math.sqrt(qvar * Math.max(0, ivar));
            const score = den > 1e-6 ? (n * cross - sumI * sumT) / den : 0;
            if (score > best) best = score;
        }
    }
    return best;
}

function fitGray(src, tw, th) {
    const out = new Float32Array(tw * th);
    for (let y = 0; y < th; y++) {
        const sy = Math.min(src.height - 1, Math.floor((y * src.height) / th));
        for (let x = 0; x < tw; x++) {
            const sx = Math.min(src.width - 1, Math.floor((x * src.width) / tw));
            out[y * tw + x] = src.data[sy * src.width + sx];
        }
    }
    return { data: out, width: tw, height: th };
}

export function cornerNCC(queryCorner, refCornerImages) {
    const q = toGray(queryCorner);
    return (refCornerImages || []).map((ref) => (ref && ref.data ? nccSlide(q, toGray(ref)) : 0));
}

function nccRank(query, layout, cands, refCards, refCorners) {
    const reg = layout.nccRegion || layout.region;
    const qCrop = cropPixels(query, reg);
    const window = expandRegion(reg, 0.03);
    const byRef = new Map();
    for (const ref of refCorners || []) {
        if (ref?.data && ref.ref) byRef.set(ref.ref, ref);
    }
    for (const ref of refCards || []) {
        if (!ref?.data || byRef.has(ref.ref)) continue;
        const sized = resizeTo(ref, query.width, query.height);
        byRef.set(ref.ref, cropPixels(sized, window));
    }
    const scored = [];
    for (const c of cands) {
        const img = byRef.get(c.ref);
        if (!img) continue;
        scored.push({ ref: c.ref, score: cornerNCC(qCrop, [img])[0] });
    }
    scored.sort((a, b) => b.score - a.score);
    if (!scored.length) return null;
    const second = scored.length > 1 ? scored[1].score : 0;
    return { bestRef: scored[0].ref, best: scored[0].score, second, gap: scored[0].score - second, scores: scored };
}

/** Candidate set codes printed in the OCR text as whole tokens ("FDC · EN"). Empty when none is readable. */
export function setCodesIn(text, cands) {
    const tokens = new Set(String(text || '').toUpperCase().split(/[^A-Z0-9]+/).filter((t) => t.length >= 2));
    const out = new Set();
    for (const c of cands || []) {
        const abbr = String(c.set_abbr || '').toUpperCase();
        if (abbr.length >= 2 && !/^\d+$/.test(abbr) && tokens.has(abbr)) out.add(abbr);
    }
    return out;
}

export async function tieBreak({ card, game, cands = [], refCards = null, refCorners = null } = {}) {
    const layout = layoutFor(game);
    const pixels = cardPixels(card);
    const distinct = shouldTieBreak(cands);
    let ocr = { text: '', number: '', conf: 0, ms: 0, nDet: 0, skipped: !layout || !layout.ocr };
    if (layout && layout.ocr) {
        ocr = await recognizeCorner(cropPixels(pixels, layout.region), game);
        if (Array.isArray(layout.altRegions) && (!ocr.number || layout.kind === 'yugioh')) {
            for (const altReg of layout.altRegions) {
                if (ocr.number && layout.kind !== 'yugioh') break;
                const altOcr = await recognizeCorner(cropPixels(pixels, altReg), game);
                ocr.ms = (ocr.ms || 0) + (altOcr.ms || 0);
                ocr.nDet = (ocr.nDet || 0) + (altOcr.nDet || 0);
                if (altOcr.text) ocr.text = ocr.text ? `${ocr.text}\n${altOcr.text}` : altOcr.text;
                if (altOcr.number && !ocr.number) {
                    ocr.number = altOcr.number;
                    ocr.conf = altOcr.conf || ocr.conf;
                }
                if (layout.kind === 'yugioh' && distinct && ocr.text) {
                    const ygoEarly = matchYugiohCandidatesByOcr(cands, ocr.text.split('\n'));
                    if (ygoEarly && ygoEarly.conf >= 0.78) break;
                }
            }
        }
    }
    // Small sets ("6/12" McDonald's, trainer kits) fail bestFraction's size prior; a fraction that is exactly
    // one candidate number's full fraction is still a read.
    if (distinct && !ocr.number && layout?.kind === 'fraction' && ocr.text) {
        const want = new Set(cands.map((c) => canonNumber(c.number || '')).filter((n) => n.includes('/')));
        const hits = fractionsIn(ocr.text).filter((f) => want.has(f));
        if (hits.length === 1) ocr.number = hits[0];
    }
    const boosts = {};
    let decided = null;
    let via = null;
    if (distinct && layout?.kind === 'yugioh' && ocr.text) {
        const ygoMatch = matchYugiohCandidatesByOcr(cands, ocr.text.split('\n'));
        if (ygoMatch) {
            ocr.number = ygoMatch.number;
            ocr.conf = Math.max(ocr.conf || 0, ygoMatch.conf);
            for (const ref of ygoMatch.hits) boosts[ref] = OCR_DELTA;
            if (ygoMatch.decidedRef) {
                decided = ygoMatch.decidedRef;
                via = 'ocr';
            }
        }
    }
    if (distinct && !decided && ocr.number && ! Object.keys(boosts).length) {
        let hits = cands.filter((c) => numbersMatch(c.number, ocr.number));
        if (hits.length > 1 && ocr.number.includes('/')) {
            const exactFrac = hits.filter((c) => c.number && c.number.includes('/') && canonNumber(c.number) === canonNumber(ocr.number));
            if (exactFrac.length) hits = exactFrac;
        }
        // The List reprints print the original card's set code and number, so the code cannot rule them out.
        const codes = hits.some((c) => LIST_ABBR_RE.test(String(c.set_abbr || ''))) ? new Set() : setCodesIn(ocr.text, cands);
        const codeOf = (c) => {
            const a = String(c.set_abbr || '').toUpperCase();
            if (game !== 'tcgp:1') return a;
            return a === 'PRE' ? '' : (/^PP./.test(a) && codes.has(a.slice(2)) ? a.slice(2) : a);
        };
        if (codes.size) hits = hits.filter((c) => { const a = codeOf(c); return !a || codes.has(a); });
        // A bare collector number ("20") without a readable set code cannot decide between two different
        // card names that happen to share that number across sets ("Phantom Flock" #16 vs "Indoctrination Attendant" #16).
        if (!codes.size) {
            const hitNames = new Set(hits.map((h) => h.name_id).filter((id) => id != null && id >= 0));
            if (hitNames.size > 1) hits = [];
            else if (hitNames.size === 1 && cands[0]?.name_id != null && !hitNames.has(cands[0].name_id)) {
                const fullCode = hHasDistinctCode(ocr.number, hits[0]);
                if (!fullCode) hits = [];
            }
        }
        if (hits.length) {
            for (const h of hits) boosts[h.ref] = OCR_DELTA;
            if (hits.length === 1) { decided = hits[0].ref; via = 'ocr'; }
        }
    }
    let ncc = null;
    if (distinct && !decided && layout && layout.region && ((refCards && refCards.length) || (refCorners && refCorners.length))) {
        ncc = nccRank(pixels, layout, cands, refCards, refCorners);
        if (ncc && ncc.gap >= NCC_GAP && ncc.bestRef) {
            const winner = cands.find((c) => c.ref === ncc.bestRef);
            const contradicted = !!(ocr.number && winner && !numbersMatch(winner.number, ocr.number));
            if (winner && !contradicted) {
                boosts[ncc.bestRef] = NCC_DELTA;
                decided = ncc.bestRef;
                via = 'ncc';
            }
        }
    }
    return {
        number: ocr.number || '',
        conf: via === 'ncc' && ncc ? ncc.best : (ocr.conf || 0),
        boosts,
        decided_ref: decided,
        text: ocr.text || '',
        ms: ocr.ms || 0,
        via,
        nDet: ocr.nDet || 0,
        ncc,
        skipped: !!ocr.skipped,
    };
}

export async function loadRefCard(url) {
    try {
        const res = await fetch(url, { mode: 'cors' });
        if (!res.ok) return null;
        const bmp = await createImageBitmap(await res.blob());
        const canvas = typeof OffscreenCanvas === 'function'
            ? new OffscreenCanvas(bmp.width, bmp.height)
            : Object.assign(document.createElement('canvas'), { width: bmp.width, height: bmp.height });
        const ctx = canvas.getContext('2d', { willReadFrequently: true });
        ctx.drawImage(bmp, 0, 0);
        if (bmp.close) bmp.close();
        const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
        return { data: image.data, width: image.width, height: image.height, channels: 4 };
    } catch {
        return null;
    }
}

export function applyBoosts(result, tb, refOf) {
    if (!result || !tb) return result;
    const boosts = tb.boosts || {};
    const deltaOf = (i) => {
        const ref = refOf(i);
        return ref != null && boosts[ref] ? boosts[ref] : 0;
    };
    const top = (result.top || []).map((row, n) => ({ ...row, ocrDelta: deltaOf(row.i), _n: n }));
    top.sort((a, b) => (a.d + a.ocrDelta) - (b.d + b.ocrDelta) || a._n - b._n);
    const best = result.best ? { ...result.best } : null;
    if (best) {
        if (result.accepted) {
            const sib = new Set([best.i, ...(best.siblings || [])]);
            const pool = top.filter((row) => sib.has(row.i));
            pool.sort((a, b) => (a.d + a.ocrDelta) - (b.d + b.ocrDelta) || a._n - b._n);
            if (pool.length > 1 && pool[0].ocrDelta < 0 && pool[0].i !== best.i) {
                best.i = pool[0].i;
                best.d = pool[0].d;
                best.match_pct = pool[0].match_pct;
            }
        } else if (top.length && top[0].ocrDelta < 0) {
            best.i = top[0].i;
            best.d = top[0].d;
            best.match_pct = top[0].match_pct;
        }
    }
    return {
        ...result,
        accepted: result.accepted,
        gap: result.gap,
        best,
        top: top.map(({ _n, ...row }) => row),
        ocr: {
            number: tb.number || '',
            conf: tb.conf || 0,
            decided_ref: tb.decided_ref || null,
            via: tb.via || null,
            ms: tb.ms || 0,
        },
    };
}

export function preselectRef(options, tb) {
    if (!tb || !tb.decided_ref) return -1;
    return (options || []).findIndex((o) => o.ref === tb.decided_ref);
}
