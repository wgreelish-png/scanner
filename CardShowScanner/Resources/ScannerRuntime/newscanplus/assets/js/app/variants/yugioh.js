/**
 * variants/yugioh.js — Dedicated single-image 1st Edition vs Unlimited detection for Yu-Gi-Oh! (tcgp:2).
 *
 * Combines two orthogonal physical signals on a Yu-Gi-Oh! card:
 *  1. Classic under-art left edition line (0.10..0.30, 0.727..0.762) vs right set-code line
 *     (0.66..0.90, 0.727..0.762), minus 0.5x middle under-art Pendulum guard (0.34..0.62, 0.727..0.762)
 *     so Pendulum scale boxes never masquerade as "1st Edition" text.
 *  2. Eye of Anubis bottom-right corner stamp gold vs silver chroma (0.89..0.955, 0.918..0.965)
 *     relative to its adjacent bottom-border background (0.81..0.87, 0.918..0.965).
 *     Every 1st Edition Yu-Gi-Oh! card (including Series 9+ where "1st Edition" moved to the bottom
 *     border) has a GOLD Eye of Anubis stamp; Unlimited cards have a SILVER Eye of Anubis stamp.
 */

import { toWorkSurface, patchTexture, findVariant, dgVote } from './common.js';
import { canonNumber } from '../../core/ocr/layouts.js';

export const GAME_KEY = 'tcgp:2';

export const YGO_ED_CLASSIC_RECT = [0.10, 0.727, 0.30, 0.762];
export const YGO_MID_GUARD_RECT = [0.34, 0.727, 0.62, 0.762];
export const YGO_SETCODE_RECT = [0.66, 0.727, 0.90, 0.762];
export const YGO_EYE_STAMP_RECT = [0.89, 0.918, 0.955, 0.965];
export const YGO_EYE_BG_RECT = [0.81, 0.918, 0.87, 0.965];
export const YGO_ED_MODERN_RECT = [0.15, 0.915, 0.36, 0.950];
export const YGO_BOT_BG_RECT = [0.42, 0.915, 0.62, 0.950];

function meanYellowB(surf, rect) {
    const { W, H, R, G, Bl } = surf;
    const x0 = Math.max(0, Math.round(rect[0] * W));
    const y0 = Math.max(0, Math.round(rect[1] * H));
    const x1 = Math.min(W, Math.round(rect[2] * W));
    const y1 = Math.min(H, Math.round(rect[3] * H));
    let sum = 0;
    let cnt = 0;
    for (let y = y0; y < y1; y++) {
        const row = y * W;
        for (let x = x0; x < x1; x++) {
            const i = row + x;
            sum += 0.5 * (R[i] + G[i]) - Bl[i];
            cnt++;
        }
    }
    return cnt ? sum / cnt : 0;
}

/**
 * Evaluate 1st Edition vs Unlimited on a Yu-Gi-Oh! work surface.
 */
export function detectYugiohEdition(scanSurf) {
    if (!scanSurf || scanSurf.clip > 0.08) {
        return { edition: null, confidence: 0, reason: 'clipped_or_empty', metrics: null };
    }
    const tEd = patchTexture(scanSurf, YGO_ED_CLASSIC_RECT);
    const tMid = patchTexture(scanSurf, YGO_MID_GUARD_RECT);
    const tSc = patchTexture(scanSurf, YGO_SETCODE_RECT);
    const tMod = patchTexture(scanSurf, YGO_ED_MODERN_RECT);
    const tBotBg = patchTexture(scanSurf, YGO_BOT_BG_RECT);

    const rawRatio = tEd / (tSc + 1.0);
    const netRatio = Math.max(0, tEd - 0.65 * tMid) / (tSc + 1.0);
    const modNet = tMod - tBotBg;

    const eyeB = meanYellowB(scanSurf, YGO_EYE_STAMP_RECT);
    const bgB = meanYellowB(scanSurf, YGO_EYE_BG_RECT);
    const eyeGold = eyeB - bgB;

    const metrics = { tEd, tMid, tSc, tMod, tBotBg, modNet, rawRatio, netRatio, eyeB, bgB, eyeGold };

    const isClassic1st =
        (netRatio >= 0.42 && eyeGold > -5.0 && (tSc >= 6.0 || tEd >= 12.0)) ||
        (netRatio >= 0.75 && tEd >= 12.0);
    const isModern1st = eyeGold >= 7.5 || (modNet >= 6.5 && eyeGold >= -5.5 && tSc >= 15.0);

    if (isClassic1st || isModern1st) {
        return {
            edition: '1st Edition',
            confidence: netRatio >= 0.6 || eyeGold >= 10.0 ? 0.94 : 0.86,
            reason: isClassic1st ? 'under_art_1st_edition_text' : 'modern_bottom_or_gold_anubis',
            metrics,
        };
    }

    if ((netRatio <= 0.40 || eyeGold <= -5.0) && eyeGold < 5.0 && modNet < 6.0 && tSc >= 6.0) {
        return {
            edition: 'Unlimited',
            confidence: 0.86,
            reason: 'empty_edition_zone_and_silver_anubis',
            metrics,
        };
    }

    return { edition: null, confidence: 0, reason: 'inconclusive_edition', metrics };
}

/**
 * Main entry point for Yu-Gi-Oh! single-image variant resolution when on 'Any' scan.
 */
export function resolveYugiohVariant({
    scanRgba,
    scanW = 200,
    scanH = 280,
    candidates = [],
}) {
    if (!candidates.length) return null;
    const top = candidates[0];
    const vars = Array.isArray(top.variants) ? top.variants : [];
    const has1st = vars.some((v) => String(v.label).includes('1st Edition'));
    const hasUnl = vars.some((v) => String(v.label).includes('Unlimited'));
    if (!has1st || !hasUnl) return null;

    const scanSurf = toWorkSurface(scanRgba, scanW, scanH);
    const ed = detectYugiohEdition(scanSurf);
    if (!ed.edition) return null;

    const v =
        ed.edition === '1st Edition'
            ? findVariant(vars, (x) => String(x.label).includes('1st Edition'))
            : findVariant(vars, (x) => String(x.label).includes('Unlimited'));
    if (!v) return null;

    return {
        game: GAME_KEY,
        ref: top.ref,
        variantId: v.id,
        printing: v.label,
        changedRef: false,
        reason: ed.reason,
        confidence: ed.confidence,
        metrics: ed.metrics,
    };
}

/**
 * YGO Base Card Name Normalization:
 * Removes parenthetical tags like (Blue), (Red), (Green), (Purple), (UTR), (CR), (QCSR), etc.
 * and trailing " - " card number suffixes so all same-name Yu-Gi-Oh! reprints share one pool.
 */
export function ygoBaseCardName(name) {
    let s = String(name || '').replace(/\s*\([^)]*\)\s*/g, ' ').trim();
    const dash = s.indexOf(' - ');
    if (dash > 0) s = s.slice(0, dash).trim();
    return s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

const CONFUSABLE_GROUPS = [
    '0ODQ',
    '1IL7T',
    '2Z',
    '5S',
    '8B',
    '6G',
    'UV',
    'CG',
    'FP',
    'RNM',
    'D0O',
];

function charCost(a, b) {
    if (a === b) return 0;
    for (const g of CONFUSABLE_GROUPS) {
        if (g.includes(a) && g.includes(b)) return 0.35;
    }
    if ((a === 'N' && b === 'D') || (a === 'D' && b === 'N')) return 0.45;
    return 1.0;
}

function weightedEditDist(s, t) {
    const m = s.length, n = t.length;
    const dp = Array.from({ length: m + 1 }, () => new Float32Array(n + 1));
    for (let i = 0; i <= m; i++) dp[i][0] = i;
    for (let j = 0; j <= n; j++) dp[0][j] = j;
    for (let i = 1; i <= m; i++) {
        for (let j = 1; j <= n; j++) {
            const cost = charCost(s[i - 1], t[j - 1]);
            dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
        }
    }
    return dp[m][n];
}

function normAlphaNum(s) {
    return String(s || '').toUpperCase().replace(/[^A-Z0-9-]/g, '');
}

function toDigits(s) {
    return String(s || '').toUpperCase()
        .replace(/[OQD]/g, '0')
        .replace(/[IL]/g, '1')
        .replace(/Z/g, '2')
        .replace(/S/g, '5')
        .replace(/B/g, '8')
        .replace(/G/g, '6');
}

// Straightened 600x840 OCR crops for all 4 Yu-Gi-Oh! set-code positions:
//  - Standard Monster/Spell/Trap (Modern Series 9-12): right side under art frame
//  - Standard Monster/Spell/Trap (Classic Series 1-8): right side slightly lower under art frame
//  - Link Monster: shifted left of the bottom-right red Link arrow
//  - Pendulum Monster: left side below the blue Pendulum Scale box
export const YGO_OCR_REGIONS = [
    [0.65, 0.696, 0.26, 0.032],
    [0.66, 0.704, 0.25, 0.032],
    [0.65, 0.715, 0.26, 0.034],
    [0.65, 0.726, 0.26, 0.034],
    [0.52, 0.703, 0.28, 0.032],
    [0.52, 0.714, 0.28, 0.032],
    [0.05, 0.612, 0.27, 0.034],
    [0.05, 0.626, 0.27, 0.034],
];

/**
 * Resolve Yu-Gi-Oh! candidate set codes against OCR text lines extracted from `YGO_OCR_REGIONS`.
 * Returns `{ number, conf, hits, decidedRef }` when a candidate set code is clearly matched.
 */
export function matchYugiohCandidatesByOcr(cands = [], ocrTexts = []) {
    if (!Array.isArray(cands) || !cands.length || !Array.isArray(ocrTexts) || !ocrTexts.length) return null;
    const byCanon = new Map();
    for (const c of cands) {
        const raw = String(c?.number || '').trim();
        const canon = canonNumber(raw);
        if (!raw || !canon) continue;
        const sc = scoreCandidateSetCodeOcr(raw, ocrTexts);
        const cur = byCanon.get(canon);
        if (!cur) {
            byCanon.set(canon, { canon, number: raw, score: sc.score, reason: sc.reason, refs: [c.ref] });
        } else {
            if (!cur.refs.includes(c.ref)) cur.refs.push(c.ref);
            if (sc.score > cur.score) {
                cur.score = sc.score;
                cur.reason = sc.reason;
                cur.number = raw;
            }
        }
    }
    const ranked = [...byCanon.values()].sort((a, b) => b.score - a.score);
    if (!ranked.length) return null;
    const top = ranked[0];
    const second = ranked[1] || { score: 0 };
    if (top.score >= 60 && top.score - second.score >= 8) {
        return {
            number: canonNumber(top.number),
            rawNumber: top.number,
            conf: Math.min(0.99, top.score / 100),
            hits: top.refs,
            decidedRef: top.refs.length === 1 ? top.refs[0] : null,
            reason: top.reason,
        };
    }
    return null;
}
export function scoreCandidateSetCodeOcr(candNumber, ocrTexts) {
    const rawCode = String(candNumber || '').toUpperCase().trim();
    if (!rawCode.includes('-')) return { score: 0, reason: '' };
    const [prefix, rightPart] = rawCode.split('-');
    const fullCanon = canonNumber(rawCode).toUpperCase();
    const numPart = rightPart.replace(/^[A-Z]+/, '');

    let bestScore = 0;
    let bestReason = '';

    for (const rawText of ocrTexts || []) {
        const clean = normAlphaNum(rawText);
        if (clean.length < 3) continue;
        const cleanNoDash = clean.replace(/-/g, '');
        if (cleanNoDash.length > 14) continue;
        const hasSetContext = clean.includes('-') || /EN|FN|EM|CN|[0-9]{2,}/.test(cleanNoDash);

        if (cleanNoDash.includes(fullCanon)) {
            return { score: 100, reason: `exact:${rawText}` };
        }

        let bestFullDist = 99;
        for (let wLen = Math.max(5, fullCanon.length - 2); wLen <= Math.min(cleanNoDash.length, fullCanon.length + 2); wLen++) {
            for (let i = 0; i + wLen <= cleanNoDash.length; i++) {
                const sub = cleanNoDash.slice(i, i + wLen);
                const d = weightedEditDist(sub, fullCanon);
                if (d < bestFullDist) bestFullDist = d;
            }
        }

        let bestPrefixDist = 99;
        const dashIdx = clean.indexOf('-');
        if (dashIdx >= 3) {
            const left = clean.slice(Math.max(0, dashIdx - 5), dashIdx).replace(/-/g, '');
            bestPrefixDist = weightedEditDist(left, prefix);
        }
        if (hasSetContext) {
            for (let wLen = Math.max(3, prefix.length - 1); wLen <= Math.min(cleanNoDash.length, prefix.length + 1); wLen++) {
                for (let i = 0; i <= Math.min(3, cleanNoDash.length - wLen); i++) {
                    const sub = cleanNoDash.slice(i, i + wLen);
                    const d = weightedEditDist(sub, prefix);
                    if (d < bestPrefixDist) bestPrefixDist = d;
                }
            }
        }

        let bestNumDist = 99;
        if (numPart.length >= 2) {
            const tailZone = dashIdx >= 0 ? clean.slice(dashIdx + 1) : cleanNoDash.slice(Math.max(0, cleanNoDash.length - 5));
            const tailDigits = toDigits(tailZone);
            for (let wLen = Math.max(2, numPart.length - 1); wLen <= Math.min(tailDigits.length, numPart.length + 1); wLen++) {
                for (let i = 0; i + wLen <= tailDigits.length; i++) {
                    const sub = tailDigits.slice(i, i + wLen);
                    const d = weightedEditDist(sub, numPart);
                    if (d < bestNumDist) bestNumDist = d;
                }
            }
        }

        let score = 0;
        if (bestFullDist <= 2.5) {
            score = Math.max(score, 90 - bestFullDist * 12);
        }
        if (bestPrefixDist <= 1.0 && bestNumDist <= 1.0) {
            score = Math.max(score, 88 - bestPrefixDist * 10 - bestNumDist * 10);
        } else if (bestPrefixDist <= 0.8 && hasSetContext) {
            score = Math.max(score, 72 - bestPrefixDist * 15);
        } else if (bestPrefixDist <= 1.4 && bestNumDist <= 1.5 && hasSetContext) {
            score = Math.max(score, 74 - bestPrefixDist * 10 - bestNumDist * 8);
        }

        if (score > bestScore) {
            bestScore = score;
            bestReason = `${rawText}(full=${bestFullDist.toFixed(1)},pre=${bestPrefixDist.toFixed(1)},num=${bestNumDist.toFixed(1)})`;
        }
    }
    return { score: bestScore, reason: bestReason };
}

function zdotRect(pA, pB, x0, y0, x1, y1, dy, dx) {
    const W = 200, H = 280, n = (x1 - x0) * (y1 - y0);
    let sA = 0, sB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(H - 1, y + dy)) * W, ry = y * W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(W - 1, x + dx));
            sA += pA[qy + qx]; sB += pB[ry + x];
        }
    }
    const mA = sA / n, mB = sB / n;
    let dot = 0, nA = 0, nB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(H - 1, y + dy)) * W, ry = y * W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(W - 1, x + dx));
            const a = pA[qy + qx] - mA, b = pB[ry + x] - mB;
            dot += a * b; nA += a * a; nB += b * b;
        }
    }
    return dot / (Math.sqrt(nA * nB) + 1e-6);
}

function normPatch(plane, x0, y0, x1, y1, dy, dx) {
    const W = 200, H = 280, w = x1 - x0, h = y1 - y0, n = w * h;
    const out = new Float32Array(n);
    let s = 0, k = 0;
    for (let y = y0; y < y1; y++) {
        const yy = Math.max(0, Math.min(H - 1, y + dy)) * W;
        for (let x = x0; x < x1; x++) {
            const xx = Math.max(0, Math.min(W - 1, x + dx));
            const v = plane[yy + xx]; out[k++] = v; s += v;
        }
    }
    const m = s / n;
    let sq = 0;
    for (let i = 0; i < n; i++) { out[i] -= m; sq += out[i] * out[i]; }
    const nr = Math.sqrt(sq / n) || 1;
    for (let i = 0; i < n; i++) out[i] /= nr;
    return out;
}

export function alignToRef(qFeat, rFeat, dyMin = -8, dyMax = 16, dxMin = -6, dxMax = 6) {
    let best = -1e9, bdy = 0, bdx = 0;
    for (let dy = dyMin; dy <= dyMax; dy++) {
        for (let dx = dxMin; dx <= dxMax; dx++) {
            const c = 0.5 * zdotRect(qFeat.hp1, rFeat.hp1, 25, 188, 185, 218, dy, dx)
                + 0.5 * zdotRect(qFeat.hp3, rFeat.hp3, 25, 188, 185, 218, dy, dx);
            if (c > best) { best = c; bdy = dy; bdx = dx; }
        }
    }
    let fBest = -1e9, fdy = bdy, fdx = bdx;
    for (let dy = bdy - 1; dy <= bdy + 1; dy++) {
        for (let dx = bdx - 1; dx <= bdx + 1; dx++) {
            const c = 0.5 * zdotRect(qFeat.hp1, rFeat.hp1, 105, 196, 184, 210, dy, dx)
                + 0.5 * zdotRect(qFeat.hp3, rFeat.hp3, 105, 196, 184, 210, dy, dx);
            if (c > fBest) { fBest = c; fdy = dy; fdx = dx; }
        }
    }
    return { dy: fdy, dx: fdx, corr: fBest, frameCorr: best };
}

export function ygoSetCodeVote2(qFeat, aFeat, bFeat) {
    const alA = alignToRef(qFeat, aFeat);
    const alB = alignToRef(qFeat, bFeat);
    const alBA = alignToRef(bFeat, aFeat, -5, 5, -4, 4);
    const patches = [
        [136, 199, 160, 207], // set prefix
        [158, 199, 182, 207], // card number
        [134, 198, 182, 208], // full standard set code
        [110, 198, 158, 208], // Link monster set code
    ];
    let sa = 0, sb = 0, dab = 0, wins = 0, tot = 0;
    const fitsA = [], fitsB = [];
    for (const [x0, y0, x1, y1] of patches) {
        for (const ch of ['hp1', 'hp3']) {
            const qA = normPatch(qFeat[ch], x0, y0, x1, y1, alA.dy, alA.dx);
            const qB = normPatch(qFeat[ch], x0, y0, x1, y1, alB.dy, alB.dx);
            const A = normPatch(aFeat[ch], x0, y0, x1, y1, 0, 0);
            const B = normPatch(bFeat[ch], x0, y0, x1, y1, 0, 0);
            const B_in_A = normPatch(bFeat[ch], x0, y0, x1, y1, alBA.dy, alBA.dx);
            let dA = 0, dB = 0;
            for (let i = 0; i < A.length; i++) { dA += qA[i] * A[i]; dB += qB[i] * B[i]; }
            fitsA.push(dA / A.length); fitsB.push(dB / B.length);
            const diffs = [];
            for (let i = 0; i < A.length; i++) {
                const d = Math.abs(A[i] - B_in_A[i]);
                if (d > 0.35) diffs.push({ i, d });
            }
            diffs.sort((x, y) => y.d - x.d);
            for (const cell of diffs.slice(0, 50)) {
                const ca = Math.abs(qA[cell.i] - A[cell.i]);
                const cb = Math.abs(qA[cell.i] - B_in_A[cell.i]);
                sa += ca; sb += cb; dab += cell.d;
                if (cb < ca) wins++;
                tot++;
            }
        }
    }
    const stdFitA = (fitsA[0] + fitsA[1] + fitsA[2] + fitsA[3] + fitsA[4] + fitsA[5]) / 6;
    const stdFitB = (fitsB[0] + fitsB[1] + fitsB[2] + fitsB[3] + fitsB[4] + fitsB[5]) / 6;
    const lnkFitA = (fitsA[6] + fitsA[7]) / 2;
    const lnkFitB = (fitsB[6] + fitsB[7]) / 2;
    return {
        v: (sa - sb) / (dab + 1e-6),
        frac: tot ? wins / tot : 0,
        stdFitA, stdFitB, stdD: stdFitB - stdFitA,
        lnkFitA, lnkFitB, lnkD: lnkFitB - lnkFitA,
        alA, alB,
    };
}

/**
 * Decide Yu-Gi-Oh! cross-set reprints using aligned set-code micro-patch vote + dgVote
 * (with Stage 4 bottom-left cornerVote disabled because bottom-left is the identical 8-digit passcode).
 */
export function decideYugiohReprintFromFeatures(qFeat, pool, refFeats, details = {}) {
    if (!qFeat || !Array.isArray(pool) || pool.length < 2) return null;
    const cur = pool[0].ref;
    const c0F = refFeats.get(cur);
    if (!c0F) return null;
    const curNum = details[cur]?.number || pool[0].tuple?.[2] || '';

    if (pool.length === 2) {
        const other = pool[1];
        const oNum = details[other.ref]?.number || other.tuple?.[2] || '';
        if (other && oNum !== curNum) {
            const bF = refFeats.get(other.ref);
            if (bF) {
                const yv = ygoSetCodeVote2(qFeat, c0F, bF);
                const dgv = dgVote(qFeat.dg, c0F.dg, bF.dg, 30);
                if (dgv.v3 > 0.06 && yv.lnkD > 0.04) {
                    return { ref: other.ref, stage: 'ygo_subhash_2cand' };
                }
            }
        }
    }

    let bestSub = null;
    for (const cand of pool.slice(1)) {
        const cNum = details[cand.ref]?.number || cand.tuple?.[2] || '';
        if (cand.ref === cur || cNum === curNum) continue;
        const bF = refFeats.get(cand.ref);
        if (!bF) continue;
        const yv = ygoSetCodeVote2(qFeat, c0F, bF);
        const dgv = dgVote(qFeat.dg, c0F.dg, bF.dg, 30);
        if (yv.v > 0.34 && yv.stdD > 0.30 && dgv.v3 > 0.30) {
            if (!bestSub || yv.v > bestSub.yv.v) {
                bestSub = { cand, yv, dgv };
            }
        }
    }
    if (bestSub) {
        const targetCanon = canonNumber(details[bestSub.cand.ref]?.number || bestSub.cand.tuple?.[2] || '');
        const groupFirst = pool.find((c) => {
            const n = canonNumber(details[c.ref]?.number || c.tuple?.[2] || '');
            const nm = details[c.ref]?.name || c.tuple?.[1] || '';
            return n === targetCanon && !nm.includes('(');
        }) || bestSub.cand;
        return { ref: groupFirst.ref, stage: 'ygo_subhash_group' };
    }

    return null;
}
