/**
 * variants/riftbound.js — Dedicated single-image Foil vs Normal & OP Promo sibling detection for Riftbound (tcgp:89).
 *
 * Handles when scanning on 'Any' printing preference:
 *  1. Same-card Foil vs Normal using reference-aligned flat-region luma std (`card.lumaStd`),
 *     vertical luma wave (`card.waveL`), and body flat-pixel luma std (`body.lumaStd`).
 *  2. Same-art `Riftbound Organized Play Promotional Cards` (`['Foil']`) vs Base Set (`['Normal', 'Foil']`)
 *     sibling resolution.
 */

import {
    toWorkSurface,
    alignReference,
    zoneFlatFoilMetrics,
    findVariant,
    baseCardName,
    subhashDist,
} from './common.js';

export const GAME_KEY = 'tcgp:89';

export const RIFTBOUND_CARD_ZONE = [0.08, 0.08, 0.92, 0.88];
export const RIFTBOUND_BODY_ZONE = [0.10, 0.56, 0.90, 0.86];
export const REG_PROMO = [0.40, 0.915, 0.60, 0.955, 16, 6, 2, 3];

const CARD_W = 200;
const CARD_H = 280;

function luma200(rgba) {
    const g = new Float32Array(CARD_W * CARD_H);
    for (let i = 0; i < CARD_W * CARD_H; i++) {
        const o = i * 4;
        g[i] = 0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2];
    }
    return g;
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

/**
 * Riftbound Organized Play Promo Badge Detector on 200x280 RGBA:
 *   1. Direct subhash comparison on REG_PROMO [0.40..0.60, 0.915..0.955] when OP Promo ref image exists.
 *   2. Reference-free badge detector comparing query bottom-center PROMO pill against flat Main Set border:
 *      - Standard light-textbox cards: measures excess luma in the PROMO pill wings ([91..96] U [104..109])
 *        over the dark bottom border flanks ([78..86] U [114..122]) across y = 251..258.
 *      - Dark-textbox Champion Unit cards (single bottom gold frame line in y = 258..260 with dark row above):
 *        measures the wider dark PROMO pill cutout at inner shoulders ([91..93] U [106..108]) vs outer gold line.
 */
export function detectRiftboundOpPromo(qRgba, mainRefRgba = null, promoRefRgba = null) {
    if (!qRgba || qRgba.length < CARD_W * CARD_H * 4) {
        return { promo: false, subhashWin: false, subhashMargin: 0, isLightPill: false, isDarkChampionPill: false };
    }
    let subhashMargin = 0;
    let subhashWin = false;
    if (mainRefRgba && promoRefRgba && mainRefRgba.length >= CARD_W * CARD_H * 4 && promoRefRgba.length >= CARD_W * CARD_H * 4) {
        const qPool = areaPoolRegion(luma200(qRgba), REG_PROMO);
        const mPool = areaPoolRegion(luma200(mainRefRgba), REG_PROMO);
        const pPool = areaPoolRegion(luma200(promoRefRgba), REG_PROMO);
        const dMain = subhashDist(qPool, mPool);
        const dPromo = subhashDist(qPool, pPool);
        subhashMargin = dMain - dPromo;
        if (dPromo < 0.18 && subhashMargin >= 0.04) {
            subhashWin = true;
        }
    }

    let bestExcess = -999;
    let sumExcess = 0;
    let darkRows = 0;
    for (let y = 251; y <= 258; y++) {
        let outerSum = 0, outerN = 0;
        for (const [x0, x1] of [[78, 86], [114, 122]]) {
            for (let x = x0; x <= x1; x++) {
                const i = (y * CARD_W + x) * 4;
                outerSum += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
                outerN++;
            }
        }
        const outerMean = outerSum / outerN;
        let wingSum = 0, wingN = 0;
        for (const [x0, x1] of [[91, 96], [104, 109]]) {
            for (let x = x0; x <= x1; x++) {
                const i = (y * CARD_W + x) * 4;
                wingSum += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
                wingN++;
            }
        }
        const wingMean = wingSum / wingN;
        if (outerMean < 25) {
            const ex = wingMean - outerMean;
            if (ex > bestExcess) bestExcess = ex;
            if (ex > 25) {
                sumExcess += ex;
                darkRows++;
            }
        }
    }
    const isLightPill = bestExcess >= 50 && sumExcess >= 140 && darkRows >= 3;

    let tbSum = 0, tbN = 0;
    for (let y = 246; y <= 252; y++) {
        for (const [x0, x1] of [[78, 86], [114, 122]]) {
            for (let x = x0; x <= x1; x++) {
                const i = (y * CARD_W + x) * 4;
                tbSum += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
                tbN++;
            }
        }
    }
    const tbMean = tbSum / tbN;
    let bestRow = 259, maxOuter = -1;
    for (let y = 258; y <= 260; y++) {
        let s = 0, n = 0;
        for (const [x0, x1] of [[78, 85], [115, 122]]) {
            for (let x = x0; x <= x1; x++) {
                const i = (y * CARD_W + x) * 4;
                s += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
                n++;
            }
        }
        if (s / n > maxOuter) {
            maxOuter = s / n;
            bestRow = y;
        }
    }
    let row257Outer = 0, row257N = 0;
    for (const [x0, x1] of [[78, 85], [115, 122]]) {
        for (let x = x0; x <= x1; x++) {
            const i = (257 * CARD_W + x) * 4;
            row257Outer += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
            row257N++;
        }
    }
    const row257Mean = row257Outer / row257N;
    let shSum = 0, shN = 0;
    for (const [x0, x1] of [[91, 93], [106, 108]]) {
        for (let x = x0; x <= x1; x++) {
            const i = (bestRow * CARD_W + x) * 4;
            shSum += 0.299 * qRgba[i] + 0.587 * qRgba[i + 1] + 0.114 * qRgba[i + 2];
            shN++;
        }
    }
    const shMean = shSum / shN;
    const shRatio = maxOuter > 0 ? shMean / maxOuter : 1;
    const isDarkChampionPill = tbMean < 28 && row257Mean < 8 && maxOuter >= 55 && shRatio < 0.25;

    return {
        promo: subhashWin || isLightPill || isDarkChampionPill,
        subhashWin,
        subhashMargin: +subhashMargin.toFixed(3),
        isLightPill,
        isDarkChampionPill,
        bestExcess: +bestExcess.toFixed(1),
        sumExcess: +sumExcess.toFixed(1),
        darkRows,
        shRatio: +shRatio.toFixed(3),
    };
}

/**
 * Evaluate Riftbound Foil vs Normal on `scanSurf` against aligned `refSurf`.
 */
export function detectRiftboundFoil(scanSurf, refSurf) {
    if (!scanSurf || !refSurf) return { isFoil: false, confidence: 0, metrics: null };
    const aligned = alignReference(scanSurf, refSurf);
    const card = zoneFlatFoilMetrics(scanSurf, aligned, RIFTBOUND_CARD_ZONE);
    const body = zoneFlatFoilMetrics(scanSurf, aligned, RIFTBOUND_BODY_ZONE);

    const isFoil =
        (card.lumaStd >= 23.0 && card.waveL >= 18.0) ||
        body.lumaStd >= 23.0 ||
        (card.chromaP90 >= 40.0 && card.lumaStd >= 20.0);

    return {
        isFoil,
        confidence: isFoil ? 0.9 : 0.82,
        metrics: { card, body },
    };
}

/**
 * Main entry point for Riftbound single-image variant & Promo sibling resolution when on 'Any' scan.
 */
export function resolveRiftboundVariant({
    scanRgba,
    scanW = 200,
    scanH = 280,
    candidates = [],
    refImages = null,
}) {
    if (!candidates.length) return null;
    const top = candidates[0];
    const scanSurf = toWorkSurface(scanRgba, scanW, scanH);
    if (!scanSurf) return null;

    const getRefSurf = (refKey) => {
        if (!refImages || !refKey) return null;
        const entry = refImages instanceof Map ? refImages.get(refKey) : refImages[refKey];
        if (!entry || !entry.rgba) return null;
        return toWorkSurface(entry.rgba, entry.w || 200, entry.h || 280);
    };

    const topBase = baseCardName(top.name);
    const topIsPromo = String(top.set_name || '').includes('Promotional');
    const promoSibling = candidates.slice(1).find((c) => {
        if (baseCardName(c.name) !== topBase) return false;
        return topIsPromo !== String(c.set_name || '').includes('Promotional');
    });

    if (promoSibling) {
        const baseCand = topIsPromo ? promoSibling : top;
        const promoCand = topIsPromo ? top : promoSibling;
        const refSurf = getRefSurf(baseCand.ref) || getRefSurf(top.ref);
        const promoSurf = getRefSurf(promoCand.ref);
        const badge = scanSurf.W === CARD_W && scanSurf.H === CARD_H
            ? detectRiftboundOpPromo(scanSurf.rgba, refSurf?.rgba || null, promoSurf?.rgba || null)
            : { promo: false };
        if (refSurf) {
            const aligned = alignReference(scanSurf, refSurf);
            const card = zoneFlatFoilMetrics(scanSurf, aligned, RIFTBOUND_CARD_ZONE);
            const body = zoneFlatFoilMetrics(scanSurf, aligned, RIFTBOUND_BODY_ZONE);
            const isPromoFoil =
                badge.promo ||
                card.chromaP90 >= 30.0 ||
                (card.lumaStd >= 20.0 && card.waveL >= 18.0) ||
                body.lumaStd >= 20.0;
            const target = isPromoFoil ? promoCand : baseCand;
            const targetVars = target.variants || [];
            const chosenVar =
                (isPromoFoil ? findVariant(targetVars, 'Foil') : findVariant(targetVars, 'Normal')) ||
                targetVars.find((v) => v.primary) ||
                targetVars[0] ||
                null;
            return {
                game: GAME_KEY,
                ref: target.ref,
                variantId: chosenVar?.id ?? null,
                printing: chosenVar?.label ?? null,
                changedRef: target.ref !== top.ref,
                reason: isPromoFoil ? 'riftbound_promo_foil_sibling' : 'riftbound_base_normal_sibling',
                confidence: isPromoFoil ? 0.9 : 0.82,
                metrics: { card, body, badge },
            };
        }
    }

    const vars = Array.isArray(top.variants) ? top.variants : [];
    const varLabels = new Set(vars.map((v) => v.label));
    const topRefSurf = getRefSurf(top.ref);
    if (varLabels.has('Foil') && varLabels.has('Normal') && topRefSurf) {
        const foilRes = detectRiftboundFoil(scanSurf, topRefSurf);
        const v = findVariant(vars, foilRes.isFoil ? 'Foil' : 'Normal');
        if (v) {
            return {
                game: GAME_KEY,
                ref: top.ref,
                variantId: v.id,
                printing: v.label,
                changedRef: false,
                reason: foilRes.isFoil ? 'riftbound_flat_foil' : 'riftbound_flat_normal',
                confidence: foilRes.confidence,
                metrics: foilRes.metrics,
            };
        }
    }

    return null;
}
