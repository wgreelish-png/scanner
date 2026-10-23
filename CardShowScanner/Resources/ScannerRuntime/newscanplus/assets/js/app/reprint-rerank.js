/**
 * reprint-rerank.js - fast client-side Stage 1 (subhash text/bottom) + Stage 2 (difference-guided
 * stroke map) reprint resolver over the 200x280 scan warp and same-origin catalog images.
 *
 * Works in pure typed arrays (<4 ms per card feature extraction, <0.5 ms per candidate pair) and
 * mirrors the verified Python 3-stage pipeline (`nsp_test_suite.py`: 67 FIX, 0 REGRESS).
 */
import { readableImageUrl } from './desk-variance.js';
import { numbersMatch } from '../core/ocr/layouts.js';
import {
    CARD_W,
    CARD_H,
    cardBaseName,
    isPlainReprintName,
    subhashDist,
    extractReprintFeatures,
    dgVote,
    stampVote,
    cornerVote,
    resizeArea200,
} from './variants/common.js';
import {
    listOrCollectorNumbersMatch,
    decideMtgReprintStage3,
    guardMtgCornerDecision,
    decideMtgSymCornerStage4b,
    framePhotoDecision,
} from './variants/mtg.js';
import { decidePokemonReprintStage3 } from './variants/pokemon.js';
import { decideYugiohReprintFromFeatures } from './variants/yugioh.js';
import { detectRiftboundOpPromo } from './variants/riftbound.js';
import { extractOnePieceFeatures, resolveOnePieceReprint } from './variants/onepiece.js';
import { scoreSorceryAlphaBeta200 } from './variants/sorcery.js';
import { decideGundamReprintFromFeatures } from './variants/gundam.js';
import { resolveVariantForGame } from './variants/index.js';

export {
    CARD_W,
    CARD_H,
    cardBaseName,
    isPlainReprintName,
    subhashDist,
    extractReprintFeatures,
    dgVote,
    stampVote,
    cornerVote,
    resizeArea200,
};

export const SPECIAL_PRINTING_RE = /\b(?:stamped|battle academy|pre-?release|promo pack|prize pack|trick or trade|the list)\b/i;

/**
 * Phone-ingest acceptance filter for a reprint decision (offline-soaked, improvement-only).
 * The full stage set both fixes and regresses on phone photos (MTG 1,000-pick soak: 8 fix /
 * 24 regress; Pokemon 515-pick soak: 17 fix / 14 regress), so phone rows accept only the
 * stage/direction subsets with a clean record on those soaks:
 *   MTG: Stage 1b/1c subhash decisions, stamp/The List demotions, and high-confidence
 *        The List / aligned set-symbol decisions.
 *   Pokemon: Stage 3 'stamp' / 'pp_logo' decisions that DEMOTE a stamped / Battle Academy / prerelease /
 *        promo-pack / Trick or Trade / Prize Pack lead to its plain same-number sibling, plus high-confidence
 *        Trick or Trade pumpkin stamp promotions.
 * Other games keep the unrestricted decision. `leadText` / `targetText` are "name group"
 * strings for the current lead and the decision target.
 */
export function restrictedReprintDecision(dec, leadText = '', targetText = '', gameKey = '') {
    if (!dec?.ref) return null;
    const demote = SPECIAL_PRINTING_RE.test(leadText) && !SPECIAL_PRINTING_RE.test(targetText);
    if (gameKey === 'tcgp:1') {
        if (dec.stage === 's1a' || dec.stage === 's1b' || dec.stage === 's1c') return dec;
        if ((dec.stage === 'stamp' || dec.stage === 'the_list') && demote) return dec;
        if (dec.stage === 'stamp' && /\bpromo pack\b/i.test(targetText) && Number(dec.sc || 0) >= 0.50) return dec;
        if (dec.stage === 'the_list' && Number(dec.sc || 0) >= 0.25) return dec;
        if (dec.stage === 'mtg_sym_corner' && Number(dec.sc || 0) >= 0.50) return dec;
        return null;
    }
    if (gameKey === 'tcgp:3') {
        if ((dec.stage === 'stamp' || dec.stage === 'pp_logo') && demote) return dec;
        if (dec.stage === 'stamp' && /\btrick or trade\b/i.test(targetText) && Number(dec.sc || 0) >= 0.20) return dec;
        return null;
    }
    return dec;
}

const ID_BANDS = [[0.52, 0.62], [0.915, 0.99]];
const STAMP_BANDS = [[0.35, 0.54]];
const STAMP_BANDS_LOWER = [[0.72, 0.88]];
const MTG_WB_ANY_RE = /^(?:Unlimited Edition|Revised Edition|Fourth Edition|Fifth Edition|Classic Sixth Edition|7th Edition|Anthologies|Beatdown Box Set|Battle Royale Box Set|Summer Magic|Introductory Two-Player Set)$/i;
const MTG_WB_NOSYM_RE = /^(?:Unlimited Edition|Revised Edition|Fourth Edition|Fifth Edition|Summer Magic|Introductory Two-Player Set)$/i;

/** Pure Stage 1 + Stage 2 + Stage 3 + Stage 4 decision given pre-extracted features `{ref: feat}` and query `qFeat`. */
export function decideReprintFromFeatures(qFeat, cands, refFeats, details = {}, ocrDecided = false, gameKey = '') {
    if (!qFeat || !Array.isArray(cands) || cands.length < 2) return null;
    const cur = cands[0].ref;
    const rf0 = refFeats.get(cur);
    if (!rf0) return null;

    const base0 = cardBaseName(cands[0].tuple?.[1] || details[cur]?.name || '');
    const pool = cands.filter((c) => {
        if (!refFeats.has(c.ref)) return false;
        return cardBaseName(c.tuple?.[1] || details[c.ref]?.name || '') === base0;
    });
    if (pool.length < 2) return null;

    const curName = details[cur]?.name || cands[0].tuple?.[1] || '';
    const curGroup = details[cur]?.group_name || details[cur]?.group_id || cands[0].tuple?.[4] || '';
    const curNum = details[cur]?.number || cands[0].tuple?.[2] || '';
    const curPlain = isPlainReprintName(curName);

    // 1. Per-game Stage 3 (Stamps + The List Planeswalker icon) — allowed even when ocrDecided is true!
    if (gameKey === 'tcgp:1') {
        const s3Mtg = decideMtgReprintStage3(qFeat, pool, refFeats, details, ocrDecided);
        if (s3Mtg) return s3Mtg;
    } else if (gameKey === 'tcgp:3') {
        const s3Pkmn = decidePokemonReprintStage3(qFeat, pool, refFeats, details, ocrDecided);
        if (s3Pkmn) return s3Pkmn;
        if (/\btrick or trade\b/i.test(`${curName} ${curGroup}`)) return null;
    } else if (gameKey === 'tcgp:86') {
        const s3Gundam = decideGundamReprintFromFeatures(qFeat, pool, refFeats, details);
        if (s3Gundam) return s3Gundam;
    } else if (gameKey === 'tcgp:2') {
        if (ocrDecided) return null;
        return decideYugiohReprintFromFeatures(qFeat, pool, refFeats, details);
    } else if (gameKey === 'tcgp:77') {
        const alphaCand = pool.find((c) => /^alpha$/i.test(String(details[c.ref]?.group_name || c.tuple?.[4] || '').trim()));
        const betaCand = pool.find((c) => /^beta$/i.test(String(details[c.ref]?.group_name || c.tuple?.[4] || '').trim()));
        if (alphaCand && betaCand && qFeat.rgba) {
            const rfA = refFeats.get(alphaCand.ref);
            const rfB = refFeats.get(betaCand.ref);
            if (rfA?.rgba && rfB?.rgba) {
                const ab = scoreSorceryAlphaBeta200(qFeat.rgba, rfA.rgba, rfB.rgba);
                if (ab) {
                    const target = ab.edition === 'Beta' ? betaCand : alphaCand;
                    if (target.ref !== cur) return { ref: target.ref, stage: 'sorcery_ab', sc: Math.abs(ab.score) };
                    return null;
                }
            }
        }
    }

    if (ocrDecided) return null;

    const curIsSpecial = SPECIAL_PRINTING_RE.test(`${curName} ${curGroup}`);
    const isUnauthorizedSpecialPromote = (c) => {
        if (curIsSpecial) return false;
        const cName = details[c.ref]?.name || c.tuple?.[1] || '';
        const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
        return SPECIAL_PRINTING_RE.test(`${cName} ${cGroup}`);
    };

    const scores = new Map();
    for (const c of pool) {
        const rf = refFeats.get(c.ref);
        scores.set(c.ref, {
            bht: subhashDist(qFeat.bht, rf.bht),
            bhb: subhashDist(qFeat.bhb, rf.bhb),
            inkt: subhashDist(qFeat.inkt, rf.inkt),
            inkb: subhashDist(qFeat.inkb, rf.inkb),
        });
    }

    const minBhb = Math.min(...[...scores.values()].map((s) => s.bhb));
    const useBhb = minBhb <= 0.5;
    const tot = (ref) => {
        const s = scores.get(ref);
        return s.bht + (useBhb ? s.bhb : 0);
    };
    const rrBh = (refA, refB) => {
        const a = refFeats.get(refA), b = refFeats.get(refB);
        return subhashDist(a.bht, b.bht) + (useBhb ? subhashDist(a.bhb, b.bhb) : 0);
    };

    // Find best plain-reprint candidate by (bht + bhb)
    let bestBh = pool[0].ref;
    if (curPlain) {
        for (const c of pool.slice(1)) {
            if (isUnauthorizedSpecialPromote(c)) continue;
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            if (isPlainReprintName(cName) && tot(c.ref) < tot(bestBh)) bestBh = c.ref;
        }
    }

    if (curPlain && bestBh !== cur) {
        const rr = rrBh(bestBh, cur);
        const m = tot(cur) - tot(bestBh);
        // Stage 1a: RR >= 0.50, TAU >= 0.60 (+ vote3 tie-breaker)
        if (rr >= 0.50 && m >= 0.60 * rr) {
            let pick = bestBh;
            const totP1 = tot(pick);
            const v3P1 = dgVote(qFeat.dg, rf0.dg, refFeats.get(pick).dg, 30).v3;
            for (const c of pool) {
                if (isUnauthorizedSpecialPromote(c)) continue;
                const cName = details[c.ref]?.name || c.tuple?.[1] || '';
                if (c.ref !== cur && c.ref !== pick && isPlainReprintName(cName) && tot(c.ref) <= totP1 + 0.02) {
                    const vt = dgVote(qFeat.dg, rf0.dg, refFeats.get(c.ref).dg, 30);
                    if (vt.v3 >= v3P1 + 0.25 && vt.frac >= 0.90) {
                        pick = c.ref;
                        break;
                    }
                }
            }
            return { ref: pick, stage: 's1a' };
        }
        // Stage 1b: RR >= 0.50, TAU >= 0.50 corroborated by vote3 > 0
        if (rr >= 0.50 && m >= 0.50 * rr) {
            const vt = dgVote(qFeat.dg, rf0.dg, refFeats.get(bestBh).dg, 30);
            if (vt.v3 > 0) return { ref: bestBh, stage: 's1b' };
        }
    }

    // Stage 1c & Stage 2 apply to plain-named reprints from different sets
    if (curPlain) {
        let best1c = null;
        for (const c of pool.slice(1)) {
            if (isUnauthorizedSpecialPromote(c)) continue;
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
            if (!isPlainReprintName(cName) || (cGroup && curGroup && cGroup === curGroup)) continue;
            const sc0 = scores.get(cur), scX = scores.get(c.ref);
            const bhtM = sc0.bht - scX.bht;
            const bhbM = sc0.bhb - scX.bhb;
            const inktM = sc0.inkt - scX.inkt;
            const inkbM = sc0.inkb - scX.inkb;
            const rfX = refFeats.get(c.ref);
            const rrSum = subhashDist(rfX.bht, rf0.bht) + subhashDist(rfX.bhb, rf0.bhb);
            const v3 = dgVote(qFeat.dg, rf0.dg, rfX.dg, 30);
            const v4 = dgVote(qFeat.dg, rf0.dg, rfX.dg, 15, ID_BANDS);
            const ok1 = (bhtM + bhbM >= 0.45 * rrSum && rrSum >= 0.12 && inktM + inkbM > 0.05 && v3.v3 >= 0.45 && v3.frac >= 0.75 && v4.v3 >= 0.35);
            const ok2 = (bhtM + bhbM >= 0.34 * Math.min(rrSum, 1.0) && rrSum >= 0.45 && inktM + inkbM >= 0.15 && v3.v3 >= 0.08 && v3.frac >= 0.50 && v4.v3 >= 0.30 && v4.frac >= 0.65);
            const ok3 = (bhtM >= 0.45 && inktM >= 0.30 && inkbM >= 0.0 && v4.v3 >= 0.50 && v4.frac >= 0.75 && v3.v3 >= 0.0);
            const ok4 = (bhtM + bhbM >= 0.45 * rrSum && rrSum >= 0.25 && inktM + inkbM >= 0.08 && v3.v3 >= 0.58 && v3.frac >= 0.80 && v3.d >= 1.1 && v4.v3 >= 0.04);
            const ok5 = (bhtM >= 0.11 && bhbM >= 0.11 && inktM >= 0.11 && inkbM >= 0.11 && (bhtM + bhbM + inktM + inkbM) >= 0.54 && rrSum >= 0.35 && v3.v3 > 0 && v3.frac >= 0.60);
            const vCopy = (gameKey === 'tcgp:1' && MTG_WB_ANY_RE.test(curGroup) && MTG_WB_NOSYM_RE.test(cGroup))
                ? dgVote(qFeat.dg, rf0.dg, rfX.dg, 15, [[0.915, 0.99]])
                : null;
            const ok6 = !!(vCopy && bhtM >= 0.04 && inktM >= 0.04 && (bhtM + inktM) >= 0.14 && (v3.v3 >= -0.25 || vCopy.v3 >= 0.15));
            if (ok1 || ok2 || ok3 || ok4 || ok5 || ok6) {
                const sc = ok6 && !(ok1 || ok2 || ok3 || ok4 || ok5)
                    ? (bhtM + inktM + Math.max(0, v3.v3) + Math.max(0, vCopy.v3))
                    : (bhtM + bhbM + inktM + inkbM + v3.v3 + v4.v3);
                if (!best1c || sc > best1c.sc) best1c = { sc, ref: c.ref };
            }
        }
        if (best1c) return { ref: best1c.ref, stage: 's1c' };

        // Stage 2: Difference-guided stroke map + collector/type-line band OR text-box subhash agreement
        let best2 = null;
        for (const c of pool.slice(1)) {
            if (isUnauthorizedSpecialPromote(c)) continue;
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
            if (!isPlainReprintName(cName) || (cGroup && curGroup && cGroup === curGroup)) continue;
            const rfX = refFeats.get(c.ref);
            const v3 = dgVote(qFeat.dg, rf0.dg, rfX.dg, 30);
            if (!(v3.v3 >= 0.70 && v3.frac >= 0.85 && v3.d >= 1.0)) continue;
            const v4 = dgVote(qFeat.dg, rf0.dg, rfX.dg, 15, ID_BANDS);
            let ok = v4.v3 >= 0.15;
            if (!ok && v4.d < 0.80) {
                const sc0 = scores.get(cur), scX = scores.get(c.ref);
                if (sc0.bht - scX.bht >= 0.12 && sc0.bhb - scX.bhb >= -0.05) ok = true;
            }
            if (ok && (!best2 || v3.v3 > best2.v)) best2 = { v: v3.v3, ref: c.ref };
        }
        if (best2) return { ref: best2.ref, stage: 'dg' };
    }

    // Stage 3: Same collector-number artwork / text-box stamp disambiguation (Trick or Trade / Prize Pack / Battle Academy / Prerelease)
    if (curNum) {
        let bestStamp = null;
        const curStampText = `${curName} ${curGroup}`;
        const curHasStamp = /\b(?:stamped|prize pack|battle academy|trick or trade|pre-?release)\b/i.test(curStampText);
        for (const c of pool.slice(1)) {
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
            const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
            if (!cNum || !numbersMatch(curNum, cNum) || (cGroup && curGroup && cGroup === curGroup)) continue;
            if (gameKey === 'tcgp:86' && !isPlainReprintName(cName)) continue;
            const rfX = refFeats.get(c.ref);
            const vs = dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, STAMP_BANDS);
            const sv = stampVote(qFeat, rf0, rfX, 12);
            const cStampText = `${cName} ${cGroup}`;
            const hasLowerStamp = /\b(?:battle academy|stamped)\b/i.test(`${curStampText} ${cStampText}`);
            const vsLo = hasLowerStamp ? dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, STAMP_BANDS_LOWER) : { v3: 0, frac: 0, d: 0 };
            const okDg = ((vs.v3 >= 0.55 && vs.frac >= 0.83 && vs.d >= 1.1) && (curHasStamp || sv.v >= 0.25))
                || (vsLo.v3 >= 0.55 && vsLo.frac >= 0.83 && vsLo.d >= 1.1 && curHasStamp);
            const okCh = (sv.v >= 0.25 && sv.frac >= 0.75 && sv.d >= 4.0 && vs.v3 >= 0.30 && (sv.v >= 0.30 || vs.frac >= 0.90))
                || (!curHasStamp && /\b(?:trick or trade|pre-?release|stamped)\b/i.test(cStampText) && sv.v >= 0.20 && sv.frac >= 0.65 && sv.d >= 4.9);
            if (okDg || okCh) {
                const sc = Math.max(vs.v3, vsLo.v3, sv.v);
                if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref };
            }
        }
        if (bestStamp) return { ref: bestStamp.ref, stage: 'stamp' };
    }

    // Stage 4: Bottom-left collector corner micro-hash disambiguation for plain cross-set reprints
    if (isPlainReprintName(curName) && gameKey !== 'tcgp:2') {
        let bestCorner = null;
        for (const c of pool.slice(1)) {
            if (isUnauthorizedSpecialPromote(c)) continue;
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
            const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
            if (!isPlainReprintName(cName) || (cGroup && curGroup && cGroup === curGroup) || (curNum && cNum && curNum === cNum)) continue;
            const cv = cornerVote(qFeat, rf0, refFeats.get(c.ref));
            if (cv.v >= 0.16 && cv.frac >= 0.57 && cv.fitB >= 0.55 && (cv.fitB - cv.fitA) >= 0.04
                && cv.setD >= -0.12 && cv.numD >= -0.05 && cv.nB >= 0.35) {
                if (!bestCorner || cv.v > bestCorner.v) bestCorner = { v: cv.v, ref: c.ref };
            }
        }
        if (bestCorner) {
            const cDec = { ref: bestCorner.ref, stage: 'corner' };
            const guarded = gameKey === 'tcgp:1' ? guardMtgCornerDecision(cDec, qFeat, rf0, refFeats, pool) : cDec;
            if (guarded) {
                if (gameKey === 'tcgp:1') {
                    const s4b = decideMtgSymCornerStage4b(qFeat, pool, refFeats, details);
                    if (s4b && s4b.ref === guarded.ref) return s4b;
                }
                return guarded;
            }
        }
    }

    // Stage 4b: MTG Set Symbol + Collector Corner combined subhash tiebreak for same-art cross-set MTG reprints
    if (gameKey === 'tcgp:1') {
        const s4b = decideMtgSymCornerStage4b(qFeat, pool, refFeats, details);
        if (s4b) return s4b;
    }

    return null;
}

const featCache = new Map();

export async function loadRgba200(src) {
    if (typeof document === 'undefined' || typeof Image === 'undefined') return null;
    const url = readableImageUrl(src) || src;
    if (!url) return null;
    return new Promise((resolve) => {
        try {
            const img = new Image();
            img.onload = () => {
                try {
                    const sw = img.naturalWidth || img.width || CARD_W;
                    const sh = img.naturalHeight || img.height || CARD_H;
                    const canvas = document.createElement('canvas');
                    canvas.width = sw;
                    canvas.height = sh;
                    const ctx = canvas.getContext('2d', { willReadFrequently: true });
                    if (!ctx) return resolve(null);
                    ctx.drawImage(img, 0, 0, sw, sh);
                    const raw = ctx.getImageData(0, 0, sw, sh);
                    if (!raw?.data) return resolve(null);
                    resolve(resizeArea200(raw.data, raw.width || sw, raw.height || sh));
                } catch {
                    resolve(null);
                }
            };
            img.onerror = () => resolve(null);
            img.src = url;
        } catch {
            resolve(null);
        }
    });
}

async function getRefFeat(ref, src) {
    if (!ref || !src) return null;
    if (!featCache.has(ref)) {
        if (featCache.size > 128) featCache.delete(featCache.keys().next().value);
        featCache.set(ref, loadRgba200(src).then((rgba) => (rgba ? extractReprintFeatures(rgba) : null)).catch(() => null));
    }
    return await featCache.get(ref);
}

const packReprintIndexCache = new WeakMap();

function getPackReprintIndex(pack) {
    if (!pack?.refs || !pack?.cl) return null;
    let idx = packReprintIndexCache.get(pack);
    if (idx) return idx;
    const byRef = new Map();
    const byCl = new Map();
    const byPg = new Map();
    const byRetroBase = new Map();
    const n = pack.n || pack.refs.length;
    const cl = pack.cl;
    const hasPg = cl.length >= 2 * n;
    for (let j = 0; j < n; j++) {
        const ref = pack.refs[j]?.[0];
        if (ref) byRef.set(ref, j);
        const nm = String(pack.refs[j]?.[1] || '');
        if (/\((?:retro\s+frame|old\s+border)\)/i.test(nm)) {
            const b = cardBaseName(nm);
            if (b) {
                let list = byRetroBase.get(b);
                if (!list) {
                    list = [];
                    byRetroBase.set(b, list);
                }
                list.push(j);
            }
        }
        const c = cl[j];
        if (c != null && c >= 0) {
            let list = byCl.get(c);
            if (!list) {
                list = [];
                byCl.set(c, list);
            }
            list.push(j);
        }
        if (hasPg) {
            const p = cl[n + j];
            if (p != null && p >= 0) {
                let list = byPg.get(p);
                if (!list) {
                    list = [];
                    byPg.set(p, list);
                }
                list.push(j);
            }
        }
    }
    idx = { byRef, byCl, byPg, byRetroBase };
    packReprintIndexCache.set(pack, idx);
    return idx;
}

/**
 * Run Stage 1 + Stage 2 + Stage 3 + Stage 4 reprint resolution on a desktop row.
 * Returns the winning `ref` string if a reprint flip is confirmed, else `null`.
 */
export async function detectReprintRef(row, thumb = null, pack = null, { restricted = false, allow = null } = {}) {
    const cands = row?.cands;
    const details = row?.details || {};
    if (!Array.isArray(cands) || !cands.length) return null;
    const mask = pack && allow && allow.length >= pack.n ? allow : null;
    const allowedIdx = (j) => !mask || !!mask[j];
    const ocrDecided = row.ocrState === 'decided';
    const gameKey = pack?.game || row?.game || '';

    const base0 = cardBaseName(cands[0].tuple?.[1] || details[cands[0].ref]?.name || '');
    const sameNameCands = cands.filter((c) => cardBaseName(c?.tuple?.[1] || details[c?.ref]?.name || '') === base0);
    if (pack?.refs && pack?.cl) {
        const pIdx = getPackReprintIndex(pack);
        const i0 = pIdx ? (pIdx.byRef.get(cands[0].ref) ?? -1) : -1;
        const cl = i0 >= 0 ? pack.cl[i0] : -1;
        const pg = i0 >= 0 && pack.cl.length >= 2 * pack.n ? pack.cl[pack.n + i0] : -1;
        const num0 = i0 >= 0 ? pack.refs[i0][2] : '';
        const seen = new Set(sameNameCands.map((c) => c.ref));
        const extra = [];
        if (cl >= 0 && pIdx) {
            for (const j of pIdx.byCl.get(cl) || []) {
                if (allowedIdx(j) && !seen.has(pack.refs[j][0])) {
                    seen.add(pack.refs[j][0]);
                    extra.push(j);
                }
            }
        }
        if (pg >= 0 && num0 && pIdx) {
            for (const j of pIdx.byPg.get(pg) || []) {
                if (allowedIdx(j) && listOrCollectorNumbersMatch(pack.refs[j][2], num0) && !seen.has(pack.refs[j][0])) {
                    seen.add(pack.refs[j][0]);
                    extra.push(j);
                }
            }
        }
        if (!ocrDecided && pg >= 0 && pIdx && isPlainReprintName(cands[0].tuple?.[1] || details[cands[0].ref]?.name || '')) {
            const pgList = pIdx.byPg.get(pg) || [];
            if (pgList.length <= 24) {
                for (const j of pgList) {
                    if (allowedIdx(j) && (cl < 0 || pack.cl[j] === cl) && isPlainReprintName(pack.refs[j]?.[1]) && !seen.has(pack.refs[j][0])) {
                        seen.add(pack.refs[j][0]);
                        extra.push(j);
                    }
                }
            }
        }
        if (extra.length && extra.length + sameNameCands.length <= 24) {
            for (const j of extra) {
                const t = pack.refs[j];
                sameNameCands.push({
                    ref: t[0],
                    tuple: t,
                    d: cands[0].d,
                    match_pct: cands[0].match_pct,
                    confidence: cands[0].confidence,
                    printingState: null,
                    ocr: '',
                    siblings: [],
                });
            }
        }
    }
    if (sameNameCands.length < 2) return null;

    let qRgba = null;
    if (thumb?.data && thumb.width === CARD_W && thumb.height === CARD_H) {
        qRgba = thumb.data;
    } else if (!row.full && (row.photo || row.shot)) {
        qRgba = await loadRgba200(row.photo || row.shot);
    }

    // Riftbound (tcgp:89) Organized Play Promotional Cards badge check (works even when OP Promo has image_count === 0)
    if (gameKey === 'tcgp:89' && qRgba) {
        const cur0 = sameNameCands[0];
        const curSet0 = details[cur0.ref]?.group_name || cur0.tuple?.[4] || '';
        const promoCand = sameNameCands.slice(1).find((c) => {
            const cSet = details[c.ref]?.group_name || c.tuple?.[4] || '';
            return /organized play promotional/i.test(cSet) && !/organized play promotional/i.test(curSet0);
        });
        if (promoCand) {
            const mainSrc = details[cur0.ref]?.image || cur0.tuple?.[6] || (cur0.ref.startsWith('p:') ? `https://cdn.tcgtracking.com/product/${cur0.ref.slice(2)}_400w.jpg` : '');
            const promoD = details[promoCand.ref];
            const promoHasImg = !promoD || Number(promoD.image_count) !== 0;
            const promoSrc = promoHasImg
                ? (promoD?.image || promoCand.tuple?.[6] || (promoCand.ref.startsWith('p:') ? `https://cdn.tcgtracking.com/product/${promoCand.ref.slice(2)}_400w.jpg` : ''))
                : '';
            const [mFeat, pFeat] = await Promise.all([
                getRefFeat(cur0.ref, mainSrc),
                promoSrc ? getRefFeat(promoCand.ref, promoSrc) : Promise.resolve(null),
            ]);
            const badge = detectRiftboundOpPromo(qRgba, mFeat?.rgba || null, pFeat?.rgba || null);
            if (badge.promo) return promoCand.ref;
        }
    }

    const qFeat = qRgba ? extractReprintFeatures(qRgba) : null;
    if (!qFeat) return null;

    const refFeats = new Map();
    await Promise.all(sameNameCands.map(async (c) => {
        const d = details[c.ref];
        if (d && Number(d.image_count) === 0) return;
        const src = d?.image || c.tuple?.[6] || (c.ref.startsWith('p:') ? `https://cdn.tcgtracking.com/product/${c.ref.slice(2)}_400w.jpg` : '');
        const f = await getRefFeat(c.ref, src);
        if (f) refFeats.set(c.ref, f);
    }));

    if (refFeats.size < 2 || !refFeats.has(cands[0].ref)) return null;

    // One Piece (tcgp:68) dedicated same-card-number reprint resolver
    if (gameKey === 'tcgp:68' && !ocrDecided) {
        const c0Num = details[sameNameCands[0].ref]?.number || sameNameCands[0].tuple?.[2] || '';
        const c0Name = details[sameNameCands[0].ref]?.name || sameNameCands[0].tuple?.[1] || '';
        const c0Group = details[sameNameCands[0].ref]?.group_name || sameNameCands[0].tuple?.[4] || '';
        const c0IsDeckOrPackPromo = /\b(?:Dash Pack|Welcome Pack|Set Sail Deck Set|Luffy Deck|Ace Deck|Koby Deck|Zoro Deck)\b/i.test(`${c0Name} ${c0Group}`);
        const opPool = sameNameCands.filter((c) => {
            if (!refFeats.has(c.ref)) return false;
            const n = details[c.ref]?.number || c.tuple?.[2] || '';
            const nm = details[c.ref]?.name || c.tuple?.[1] || '';
            return n === c0Num && !/Parallel|Alt|Manga|Treasure|SP|Serial/i.test(nm);
        });
        if (opPool.length >= 2) {
            const qOp = extractOnePieceFeatures({ data: qRgba, width: CARD_W, height: CARD_H, channels: 4 });
            const opMap = new Map();
            for (const c of opPool) {
                const rf = refFeats.get(c.ref);
                if (rf?.rgba) opMap.set(c.ref, extractOnePieceFeatures({ data: rf.rgba, width: CARD_W, height: CARD_H, channels: 4 }));
            }
            const opThreshold = c0IsDeckOrPackPromo ? 0.08 : 0.18;
            const opRes = resolveOnePieceReprint(qOp, opPool[0].ref, opPool.map((c) => c.ref), (r) => opMap.get(r), { threshold: opThreshold });
            if (opRes.switched) return opRes.chosen;
        }
    }

    const res = decideReprintFromFeatures(qFeat, sameNameCands, refFeats, details, ocrDecided, gameKey);
    if (!res) return null;
    if (restricted) {
        const textOf = (c) => `${details[c?.ref]?.name || c?.tuple?.[1] || ''} ${details[c?.ref]?.group_name || c?.tuple?.[4] || ''}`;
        const target = sameNameCands.find((c) => c.ref === res.ref);
        if (!restrictedReprintDecision(res, textOf(sameNameCands[0]), textOf(target), gameKey)) return null;
    }
    return res.ref;
}

/**
 * Runs dedicated per-game variant, edition stamp (`1st Edition` / `Unlimited`), and special-finish sibling
 * resolution (`variants/index.js`) on the 200x280 scan warp.
 */
export async function detectGameVariant(row, thumb, pack = null, { allowGenericSameRefFoil = false, framePhoto = false, photoRgba = null, refImages: refImagesIn = null } = {}) {
    const cands = row?.cands;
    if (!Array.isArray(cands) || !cands.length) return null;
    const gameKey = String(pack?.game || row?.game || '');
    if (!gameKey) return null;

    let qRgba = null;
    if (thumb?.data && thumb.width === CARD_W && thumb.height === CARD_H) {
        qRgba = thumb.data;
    } else if (!row.full && (row.photo || row.shot)) {
        qRgba = await loadRgba200(row.photo || row.shot);
    }
    if (!qRgba) return null;

    const details = row.details || {};
    const rawCands = cands.slice(0, 5);
    if (gameKey === 'tcgp:1' && pack?.cl && pack?.refs && cands[0]?.ref) {
        const pIdx = getPackReprintIndex(pack);
        const leadBase = cardBaseName(details[cands[0].ref]?.name || cands[0].tuple?.[1] || '');
        const retroIdxs = leadBase && pIdx?.byRetroBase ? (pIdx.byRetroBase.get(leadBase) || []) : [];
        if (retroIdxs.length) {
            const seenRefs = new Set(rawCands.map((c) => c.ref));
            for (const j of retroIdxs) {
                const t = pack.refs[j];
                if (!t || seenRefs.has(t[0])) continue;
                seenRefs.add(t[0]);
                rawCands.push({ ref: t[0], tuple: t, confidence: cands[0].confidence, match_pct: cands[0].match_pct, ocr: '' });
            }
        }
    }
    const candidates = rawCands.map((c) => {
        const d = details[c.ref] || {};
        const packVars = c.tuple?.[7] || [];
        const variants = packVars.length
            ? packVars.map((v) => ({ id: v.id ?? null, label: v.label || 'Default', primary: !!v.primary }))
            : (d.printings || []).map((p, i) => ({ id: p.sku_id ?? null, label: p.label || p.key || 'Default', primary: i === 0 }));
        return {
            ref: c.ref,
            score: c.confidence ?? c.match_pct ?? 0,
            name: d.name || c.tuple?.[1] || c.ref,
            set_name: d.group_name || c.tuple?.[4] || '',
            abbr: d.group_abbr || c.tuple?.[3] || '',
            num: d.number || c.tuple?.[2] || '',
            rarity: d.rarity || c.tuple?.[5] || '',
            ocr: c.ocr || '',
            variants,
        };
    });

    const refImages = refImagesIn instanceof Map ? refImagesIn : new Map();
    if (!(refImagesIn instanceof Map) && gameKey !== 'tcgp:2') {
        await Promise.all(candidates.map(async (c) => {
            const d = details[c.ref];
            if (d && Number(d.image_count) === 0) return;
            const rawTuple = rawCands.find((x) => x.ref === c.ref)?.tuple;
            const src = d?.image || rawTuple?.[6] || (c.ref.startsWith('p:') ? `https://cdn.tcgtracking.com/product/${c.ref.slice(2)}_400w.jpg` : '');
            const f = await getRefFeat(c.ref, src);
            if (f?.rgba) refImages.set(c.ref, { rgba: f.rgba, w: CARD_W, h: CARD_H });
        }));
    }

    const variantInput = (scanRgba) => ({
        scanRgba,
        scanW: CARD_W,
        scanH: CARD_H,
        candidates,
        refImages,
        allowGenericSameRefFoil,
    });
    let res = resolveVariantForGame(gameKey, variantInput(qRgba));
    // The phone rescan warp clips the retro border. The original photo still has it.
    if (!res && framePhoto && gameKey === 'tcgp:1') {
        const photo = photoRgba || (row?.photo ? await loadRgba200(row.photo) : null);
        if (photo) res = framePhotoDecision(null, resolveVariantForGame(gameKey, variantInput(photo)));
    }
    return res;
}

