/**
 * variants/gundam.js — Dedicated single-image (C+) Holofoil sibling vs Normal detection for Gundam Card Game (tcgp:86).
 *
 * In Gundam Starter Decks (e.g. Heroic Beginnings [ST01], Zeon's Rush [ST03], SEED Strike [ST04]),
 * every card has a Normal printing (`ST01-015`) and a same-art `(C+)` Holofoil sibling (`ST01-015 (C+)`).
 * Comparing the scan against the clean base reference separates `(C+)` Holofoil from Normal.
 */

import {
    toWorkSurface,
    alignReference,
    zoneFlatFoilMetrics,
    findVariant,
    baseCardName,
} from './common.js';

export const GAME_KEY = 'tcgp:86';

export const GUNDAM_CARD_ZONE = [0.08, 0.08, 0.92, 0.88];
export const GUNDAM_BODY_ZONE = [0.10, 0.56, 0.90, 0.86];

function isCPlusSibling(cand) {
    return /\((?:C|U|R|LR)\+\)/i.test(String(cand?.name || ''));
}

function flatResidual(m) {
    return m.card.lumaStd + m.body.lumaStd;
}

/**
 * Evaluate Gundam `(C+)` Holofoil vs Normal on `scanSurf` against aligned `refSurf` (and `holoSurf` when available).
 */
export function detectGundamHolofoil(scanSurf, refSurf, holoSurf = null) {
    if (!scanSurf || !refSurf) return { isHolofoil: false, confidence: 0, metrics: null };
    const aligned = alignReference(scanSurf, refSurf);
    const card = zoneFlatFoilMetrics(scanSurf, aligned, GUNDAM_CARD_ZONE);
    const body = zoneFlatFoilMetrics(scanSurf, aligned, GUNDAM_BODY_ZONE);

    let holo = null;
    if (holoSurf) {
        const alignedH = alignReference(scanSurf, holoSurf);
        holo = {
            card: zoneFlatFoilMetrics(scanSurf, alignedH, GUNDAM_CARD_ZONE),
            body: zoneFlatFoilMetrics(scanSurf, alignedH, GUNDAM_BODY_ZONE),
        };
    }
    const baseRes = flatResidual({ card, body });
    const holoRes = holo ? flatResidual(holo) : Infinity;
    const foilSignal =
        card.waveL >= 22.0 ||
        body.lumaStd >= 24.0 ||
        (card.chromaP90 >= 25.0 && card.lumaStd >= 18.0);
    const isHolofoil = holo
        ? (holoRes < baseRes && holoRes <= 55 && foilSignal)
        : ((card.chromaP90 >= 25.0 && card.lumaStd >= 18.0) || body.lumaStd >= 24.0 || card.waveL >= 22.0);

    return {
        isHolofoil,
        confidence: isHolofoil ? 0.92 : 0.85,
        metrics: { card, body, holo },
    };
}

/**
 * Main entry point for Gundam single-image `(C+)` sibling & Holofoil resolution when on 'Any' scan.
 */
export function resolveGundamVariant({
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
    const topCPlus = isCPlusSibling(top);
    const cPlusSibling = candidates.slice(1).find((c) => {
        if (c.set_name !== top.set_name || baseCardName(c.name) !== topBase) return false;
        return topCPlus !== isCPlusSibling(c);
    });

    if (cPlusSibling) {
        const baseCand = topCPlus ? cPlusSibling : top;
        const holoCand = topCPlus ? top : cPlusSibling;
        const refSurf = getRefSurf(baseCand.ref) || getRefSurf(top.ref);
        const holoSurf = getRefSurf(holoCand.ref);
        if (refSurf) {
            const res = detectGundamHolofoil(scanSurf, refSurf, holoSurf);
            const target = res.isHolofoil ? holoCand : baseCand;
            const targetVars = target.variants || [];
            const chosenVar =
                (res.isHolofoil ? findVariant(targetVars, 'Holofoil') : findVariant(targetVars, 'Normal')) ||
                targetVars.find((v) => v.primary) ||
                targetVars[0] ||
                null;
            return {
                game: GAME_KEY,
                ref: target.ref,
                variantId: chosenVar?.id ?? null,
                printing: chosenVar?.label ?? null,
                changedRef: target.ref !== top.ref,
                reason: res.isHolofoil ? 'gundam_cplus_holo_sibling' : 'gundam_base_normal_sibling',
                confidence: res.confidence,
                metrics: res.metrics,
            };
        }
    }

    return null;
}

function zdotRgbaPatch(rgbaA, rgbaB, x0, y0, x1, y1, dy, dx) {
    const W = 200, H = 280;
    const n = (x1 - x0) * (y1 - y0);
    let sA = 0, sB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(H - 1, y + dy)) * W;
        const ry = y * W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(W - 1, x + dx));
            const pq = (qy + qx) * 4, pr = (ry + x) * 4;
            sA += 0.299 * rgbaA[pq] + 0.587 * rgbaA[pq + 1] + 0.114 * rgbaA[pq + 2];
            sB += 0.299 * rgbaB[pr] + 0.587 * rgbaB[pr + 1] + 0.114 * rgbaB[pr + 2];
        }
    }
    const mA = sA / n, mB = sB / n;
    let dot = 0, nA = 0, nB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(H - 1, y + dy)) * W;
        const ry = y * W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(W - 1, x + dx));
            const pq = (qy + qx) * 4, pr = (ry + x) * 4;
            const a = (0.299 * rgbaA[pq] + 0.587 * rgbaA[pq + 1] + 0.114 * rgbaA[pq + 2]) - mA;
            const b = (0.299 * rgbaB[pr] + 0.587 * rgbaB[pr + 1] + 0.114 * rgbaB[pr + 2]) - mB;
            dot += a * b; nA += a * a; nB += b * b;
        }
    }
    return dot / (Math.sqrt(nA * nB) + 1e-6);
}

/**
 * Shift-tolerant normalized cross-correlation over the Gundam top-right ID banner `[136, 4, 195, 18]`
 * and block/edition icon `[174, 4, 194, 18]` (`β` on Edition Beta vs `1` on main/starter sets).
 */
export function gundamIdBannerCorr(qRgba, rRgba, maxShift = 10) {
    if (!qRgba || !rRgba) return -2;
    let best = -2;
    for (let dy = -maxShift; dy <= maxShift; dy++) {
        for (let dx = -maxShift; dx <= maxShift; dx++) {
            const cBanner = zdotRgbaPatch(qRgba, rRgba, 136, 4, 195, 18, dy, dx);
            if (cBanner < 0.55) continue;
            const cPip = zdotRgbaPatch(qRgba, rRgba, 174, 4, 194, 18, dy, dx);
            const c = 0.45 * cBanner + 0.55 * cPip;
            if (c > best) best = c;
        }
    }
    return best;
}

/**
 * Resolves Gundam Edition Beta (`β` in top-right block circle) vs regular set (`1` in top-right block circle)
 * for same-number plain reprints (e.g. Resource `R-001` Edition Beta vs Newtype Rising).
 */
export function decideGundamReprintFromFeatures(qFeat, pool, refFeats, details = {}) {
    if (!qFeat?.rgba || !Array.isArray(pool) || pool.length < 2) return null;
    const cur = pool[0].ref;
    const rf0 = refFeats.get(cur);
    if (!rf0?.rgba) return null;
    const curName = details[cur]?.name || pool[0].tuple?.[1] || '';
    const curGroup = details[cur]?.group_name || details[cur]?.group_id || pool[0].tuple?.[4] || '';
    const curNum = details[cur]?.number || pool[0].tuple?.[2] || '';
    if (!curNum || /\((?:C|U|R|LR)\+\)/i.test(curName)) return null;
    const curIsBeta = /\bedition beta\b/i.test(curGroup);
    const c0 = gundamIdBannerCorr(qFeat.rgba, rf0.rgba);
    if (c0 < -1) return null;

    let best = null;
    for (const c of pool.slice(1)) {
        const cName = details[c.ref]?.name || c.tuple?.[1] || '';
        const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
        const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
        if (cNum !== curNum || /\((?:C|U|R|LR)\+\)|judge pack|release event/i.test(`${cName} ${cGroup}`)) continue;
        const cIsBeta = /\bedition beta\b/i.test(cGroup);
        if (cIsBeta === curIsBeta) continue;
        const rfX = refFeats.get(c.ref);
        if (!rfX?.rgba) continue;
        const cX = gundamIdBannerCorr(qFeat.rgba, rfX.rgba);
        const gain = cX - c0;
        if (cX >= 0.85 && gain >= 0.08) {
            if (!best || gain > best.sc) best = { ref: c.ref, stage: 'gundam_beta_sym', sc: gain };
        }
    }
    return best;
}
