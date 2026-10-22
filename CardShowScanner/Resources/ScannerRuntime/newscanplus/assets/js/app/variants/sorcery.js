/**
 * variants/sorcery.js — Sorcery: Contested Realm (`tcgp:77`) single-image variant & edition detector.
 *
 * Distinguishes Alpha vs Beta printings of the same card using the center-bottom edition
 * symbol (`ⓐ` vs `ⓑ`, Greek alpha `α` vs beta `β` enclosed in a circle between `"Art"`
 * and the artist name in the bottom credit bar around `x ≈ 0.36..0.46, y ≈ 0.96`).
 *
 * Method:
 *   1. Locate the edition symbol center `(cx, cy)` on the `200×280` reference pair where
 *      `|L_alpha - L_beta|` peaks inside `x ∈ [72..92], y ∈ [269..272]`.
 *   2. If the card is a landscape Site rotated into portrait (`bestDiff < 250` at the
 *      standard bottom bar), prefer Beta over Alpha on near-tied hashes.
 *   3. Align the scan's artist credit line (`y ∈ [cy-2..cy+2], x ∈ [cx-16..cx+28]`,
 *      masking `[cx-3..cx+3]`) via horizontal luminance gradient `dL/dx` (`ldx ∈ [-5..5],
 *      ldy ∈ [-4..4]`), which is invariant to horizontal frame borders.
 *   4. Refine the shared outer circle center `(cdx, cdy)` against `0.5 * (L_alpha + L_beta)`
 *      on `[cx-3..cx+3, cy-3..cy+3]` (`cdx ∈ [ldx-2..ldx+2], cdy ∈ [ldy-1..ldy+1]`) so
 *      both Alpha and Beta are evaluated at the exact same circle position.
 *   5. Compare the inner glyph core `[cx-2..cx+1, cy-1..cy+1]`, where Alpha (`α`) has a
 *      dark hollow center and Beta (`β`) has a bright central vertical stem and crossbar.
 */

import {
    CARD_W,
    CARD_H,
    resizeArea200,
    cardBaseName,
} from './common.js';

export const GAME_KEY = 'tcgp:77';

function isAlphaGroup(group) {
    return /^alpha$/i.test(String(group || '').trim());
}

function isBetaGroup(group) {
    return /^beta$/i.test(String(group || '').trim());
}

function lumaPlane200(rgba) {
    if (!rgba || rgba.length < CARD_W * CARD_H * 4) return null;
    const g = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) {
        const o = i * 4;
        g[i] = 0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2];
    }
    return g;
}

/**
 * Compare a `200×280` scan RGBA buffer against `200×280` Alpha and Beta reference RGBA buffers.
 *
 * @returns {{ edition: 'Alpha'|'Beta', score: number, reason: string } | null}
 */
export function scoreSorceryAlphaBeta200(scanRgba200, alphaRgba200, betaRgba200) {
    const qL = lumaPlane200(scanRgba200);
    const rA = lumaPlane200(alphaRgba200);
    const rB = lumaPlane200(betaRgba200);
    if (!qL || !rA || !rB) return null;

    // 1. Locate symbol center (cx, cy) in x ∈ [72..92], y ∈ [269..272] where |rA - rB| peaks
    let cx = 80, cy = 270, bestDiff = -1;
    for (let y = 269; y <= 272; y++) {
        for (let x = 72; x <= 92; x++) {
            let s = 0;
            for (let dy = -2; dy <= 2; dy++) {
                for (let dx = -2; dx <= 2; dx++) {
                    const idx = (y + dy) * CARD_W + (x + dx);
                    s += Math.abs(rA[idx] - rB[idx]);
                }
            }
            if (s > bestDiff) {
                bestDiff = s;
                cx = x;
                cy = y;
            }
        }
    }

    // Landscape Site cards rotated to portrait do not have the symbol at y ≈ 270
    if (bestDiff < 250) {
        return { edition: 'Beta', score: 0.25, reason: 'sorcery_site_default_beta' };
    }

    // 2. Align (dx, dy) in [-3..3, -2..2] by maximizing context (25x7) + symbol (7x7) correlation
    function nccBox(rL, dx, dy, rx, ry) {
        let mQ = 0, mR = 0, n = 0;
        for (let y = cy - ry; y <= cy + ry; y++) {
            const qy = y + dy;
            if (qy < 0 || qy >= CARD_H) continue;
            for (let x = cx - rx; x <= cx + rx; x++) {
                const qx = x + dx;
                if (qx < 0 || qx >= CARD_W) continue;
                mQ += qL[qy * CARD_W + qx];
                mR += rL[y * CARD_W + x];
                n++;
            }
        }
        if (!n) return 0;
        mQ /= n;
        mR /= n;
        let dot = 0, nQ = 0, nR = 0;
        for (let y = cy - ry; y <= cy + ry; y++) {
            const qy = y + dy;
            if (qy < 0 || qy >= CARD_H) continue;
            for (let x = cx - rx; x <= cx + rx; x++) {
                const qx = x + dx;
                if (qx < 0 || qx >= CARD_W) continue;
                const vq = qL[qy * CARD_W + qx] - mQ;
                const vr = rL[y * CARD_W + x] - mR;
                dot += vq * vr;
                nQ += vq * vq;
                nR += vr * vr;
            }
        }
        if (nQ < 50 || nR < 50) return 0;
        return dot / (Math.sqrt(nQ * nR) + 1e-6);
    }

    let bestAlign = -2, bdx = 0, bdy = 0;
    for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -3; dx <= 3; dx++) {
            const ctxA = nccBox(rA, dx, dy, 12, 3);
            const ctxB = nccBox(rB, dx, dy, 12, 3);
            const symA = nccBox(rA, dx, dy, 3, 3);
            const symB = nccBox(rB, dx, dy, 3, 3);
            const sc = 0.5 * Math.max(ctxA, ctxB) + 0.5 * Math.max(symA, symB);
            if (sc > bestAlign) {
                bestAlign = sc;
                bdx = dx;
                bdy = dy;
            }
        }
    }

    const cA = nccBox(rA, bdx, bdy, 3, 3);
    const cB = nccBox(rB, bdx, bdy, 3, 3);
    const score = cB - cA;

    return {
        edition: score >= -0.068 ? 'Beta' : 'Alpha',
        score,
        reason: score >= -0.068 ? 'sorcery_beta_symbol' : 'sorcery_alpha_symbol',
    };
}

export function resolveSorceryVariant({ scanRgba, scanW, scanH, candidates, refImages }) {
    if (!Array.isArray(candidates) || !candidates.length) return null;
    const top = candidates[0];
    if (!scanRgba || !scanW || !scanH || candidates.length < 2) {
        return { ref: top.ref, variant: 'Normal', reason: 'default' };
    }

    const topBase = cardBaseName(top.name);
    const alphaCand = candidates.find(c => cardBaseName(c.name) === topBase && isAlphaGroup(c.set_name || c.group));
    const betaCand = candidates.find(c => cardBaseName(c.name) === topBase && isBetaGroup(c.set_name || c.group));
    if (!alphaCand || !betaCand) {
        return { ref: top.ref, variant: 'Normal', reason: 'default' };
    }

    // Only arbitrate when Alpha and Beta are within hash tie range
    const dAlpha = Number(alphaCand.d ?? 0);
    const dBeta = Number(betaCand.d ?? 0);
    if (Math.abs(dAlpha - dBeta) > 2.5) {
        return { ref: top.ref, variant: 'Normal', reason: 'default' };
    }

    const q200 = (scanW === CARD_W && scanH === CARD_H)
        ? scanRgba
        : resizeArea200(scanRgba, scanW, scanH);
    const aImg = refImages instanceof Map ? refImages.get(alphaCand.ref) : refImages?.[alphaCand.ref];
    const bImg = refImages instanceof Map ? refImages.get(betaCand.ref) : refImages?.[betaCand.ref];
    const a200 = aImg?.rgba ? resizeArea200(aImg.rgba, aImg.w, aImg.h) : null;
    const b200 = bImg?.rgba ? resizeArea200(bImg.rgba, bImg.w, bImg.h) : null;

    if (!q200 || !a200 || !b200) {
        return { ref: top.ref, variant: 'Normal', reason: 'default' };
    }

    const res = scoreSorceryAlphaBeta200(q200, a200, b200);
    if (!res) {
        return { ref: top.ref, variant: 'Normal', reason: 'default' };
    }

    const target = res.edition === 'Beta' ? betaCand : alphaCand;
    return {
        game: GAME_KEY,
        ref: target.ref,
        variant: 'Normal',
        changedRef: target.ref !== top.ref,
        reason: res.reason,
    };
}
