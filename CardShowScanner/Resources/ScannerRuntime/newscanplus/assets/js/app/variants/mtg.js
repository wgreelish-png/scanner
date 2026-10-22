/**
 * variants/mtg.js — Dedicated single-image variant & special-finish sibling detection for MTG (tcgp:1).
 *
 * Note: The List Reprints (Planeswalker bottom-left symbol) is already handled in the main scanner
 * pipeline and is intentionally excluded here.
 *
 * Handles when scanning on 'Any' printing preference:
 *  1. Same-card Foil vs Normal using reference-aligned flat-region chroma p90, vertical rainbow
 *     wavelength modulation (`waveAB`), and paper-grain smoothing (`texExcess`).
 *  2. Same-art Special-Finish Siblings:
 *     - Surge Foil (Fallout / Warhammer / LOTR / Final Fantasy / Doctor Who): diagonal ripple energy
 *       (`diagExcess`) and rainbow chroma excess on flat reference regions.
 *     - Rainbow Foil (Secret Lair Drop Series): foil chroma / vertical rainbow wave against the clean
 *       non-foil base reference (avoids synthetic rainbow overlay bias on Secret Lair stock refs).
 *     - Foil Etched / Galaxy Foil: frame comparison and flat-pixel chroma against base reference.
 *  3. Prerelease Cards (`['Foil']` with gold date stamp) vs Base Set (`['Normal', 'Foil']`).
 *  4. Promo Pack (`Promo Pack:` sets) sibling switching.
 */

import {
    toWorkSurface,
    alignReference,
    zoneFlatFoilMetrics,
    findVariant,
    baseCardName,
    dgVote,
    cornerVote,
    isPlainReprintName,
    extractMtgReprintPools,
    extractReprintFeatures,
    stampRegionVote,
    CARD_W,
    CARD_H,
} from './common.js';
import { canonNumber, numbersMatch } from '../../core/ocr/layouts.js';

export { extractMtgReprintPools, stampRegionVote };

export const GAME_KEY = 'tcgp:1';

export const MTG_CARD_ZONE = [0.08, 0.08, 0.92, 0.88];
export const MTG_BODY_ZONE = [0.10, 0.56, 0.90, 0.86];
export const MTG_ART_ZONE = [0.10, 0.12, 0.90, 0.54];
export const MTG_STAMP_RIGHT_ZONE = [0.70, 0.48, 0.92, 0.58];
export const MTG_STAMP_LEFT_ZONE = [0.08, 0.48, 0.30, 0.58];
export const REG_MTG_SYM = [0.82, 0.54, 0.95, 0.61, 16, 8, 2, 2];
export const REG_LIST = [0.03, 0.92, 0.10, 0.98, 10, 10, 2, 2];
export const STAMP_MTG_ART = [[0.40, 0.54]];
const STAMP_MTG_LEFT_X = [0.06, 0.34];
const STAMP_MTG_RIGHT_X = [0.72, 0.94];

const SPECIAL_FINISH_SIBLING_LABELS = [
    'Surge Foil',
    'Rainbow Foil',
    'Foil Etched',
    'Galaxy Foil',
    'Textured Foil',
    'Gilded Foil',
    'Halo Foil',
    'Confetti Foil',
    'Step-and-Compleat Foil',
];

function meanAbsLumaDiff(scanSurf, refSurf, rect = MTG_CARD_ZONE) {
    const { W, H } = scanSurf;
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
            sum += Math.abs(scanSurf.L[i] - refSurf.L[i]);
            cnt++;
        }
    }
    return cnt ? sum / cnt : 999;
}

/**
 * Evaluate MTG Foil vs Normal on `scanSurf` against aligned `refSurf`.
 */
export function detectMtgFoil(scanSurf, refSurf) {
    if (!scanSurf || !refSurf) return { isFoil: false, confidence: 0, metrics: null };
    const aligned = alignReference(scanSurf, refSurf);
    const card = zoneFlatFoilMetrics(scanSurf, aligned, MTG_CARD_ZONE);
    const body = zoneFlatFoilMetrics(scanSurf, aligned, MTG_BODY_ZONE);

    // Three complementary physical signatures of MTG traditional / rainbow foil:
    //  1. Smooth metallic specular sheen (`texExcess <= 3.6` with elevated chroma/wave)
    //  2. Broad rainbow color-band shift across flat card areas (`card.chromaP90 >= 30 && body.chromaP90 >= 22`)
    //  3. Strong vertical rainbow gradient (`waveAB >= 12.5 && card.chromaP90 >= 24`)
    const isFoil =
        (card.texExcess <= 3.6 && (card.chromaP90 >= 22.0 || card.waveAB >= 10.5)) ||
        (card.chromaP90 >= 30.0 && body.chromaP90 >= 22.0) ||
        (card.waveAB >= 12.5 && card.chromaP90 >= 24.0);

    return {
        isFoil,
        confidence: isFoil ? Math.min(0.92, Math.max(card.chromaP90 / 35, card.waveAB / 16)) : 0.78,
        metrics: { card, body },
    };
}

function getSpecialSiblingFinish(cand) {
    const name = String(cand?.name || '');
    for (const label of SPECIAL_FINISH_SIBLING_LABELS) {
        if (name.includes(label)) return label;
    }
    const vars = Array.isArray(cand?.variants) ? cand.variants : [];
    for (const v of vars) {
        if (SPECIAL_FINISH_SIBLING_LABELS.includes(v.label)) return v.label;
    }
    return null;
}

/**
 * Main entry point for MTG single-image variant & sibling resolution when on 'Any' scan.
 */
export function resolveMtgVariant({
    scanRgba,
    scanW = 200,
    scanH = 280,
    candidates = [],
    refImages = null,
    allowGenericSameRefFoil = true,
}) {
    if (!candidates.length) return null;
    const top = candidates[0];
    const scanSurf = toWorkSurface(scanRgba, scanW, scanH);
    if (!scanSurf) return null;

    const getRefEntry = (refKey) => {
        if (!refImages || !refKey) return null;
        const entry = refImages instanceof Map ? refImages.get(refKey) : refImages[refKey];
        return entry && entry.rgba ? entry : null;
    };
    const getRefSurf = (refKey) => {
        const entry = getRefEntry(refKey);
        if (!entry) return null;
        return toWorkSurface(entry.rgba, entry.w || 200, entry.h || 280);
    };

    const topBase = baseCardName(top.name);

    // 1. Check Surge Foil / Rainbow Foil / Foil Etched / Galaxy Foil same-set sibling
    const topSpec = getSpecialSiblingFinish(top);
    const specSibling = candidates.slice(1).find((c) => {
        if (c.set_name !== top.set_name || baseCardName(c.name) !== topBase) return false;
        const cSpec = getSpecialSiblingFinish(c);
        return Boolean(topSpec) !== Boolean(cSpec);
    });

    if (specSibling) {
        const baseCand = topSpec ? specSibling : top;
        const specCand = topSpec ? top : specSibling;
        const specKind = getSpecialSiblingFinish(specCand);
        const baseSurf = getRefSurf(baseCand.ref);
        const specSurf = getRefSurf(specCand.ref);

        if (baseSurf) {
            const alignedBase = alignReference(scanSurf, baseSurf);
            const fc = zoneFlatFoilMetrics(scanSurf, alignedBase, MTG_CARD_ZONE);
            const fb = zoneFlatFoilMetrics(scanSurf, alignedBase, MTG_BODY_ZONE);

            let isSpecial = false;
            if (specKind === 'Surge Foil') {
                // Surge Foil has high diagonal ripple energy (`diagExcess >= 28`) or strong body/card chroma
                isSpecial = fc.diagExcess >= 28.0 || fb.chromaP90 >= 38.0 || (fc.chromaP90 >= 45.0 && fb.chromaP90 >= 30.0);
            } else if (specKind === 'Foil Etched') {
                // Foil Etched has a distinct dark metallic frame; only switch when spec ref is much closer
                if (specSurf) {
                    const alignedSpec = alignReference(scanSurf, specSurf);
                    const diffBase = meanAbsLumaDiff(scanSurf, alignedBase, MTG_BODY_ZONE);
                    const diffSpec = meanAbsLumaDiff(scanSurf, alignedSpec, MTG_BODY_ZONE);
                    isSpecial = diffSpec + 4.0 < diffBase && fb.chromaP90 >= 25.0;
                }
            } else {
                // Rainbow Foil (Secret Lair) / Galaxy Foil / other special finishes
                isSpecial = fb.chromaP90 >= 16.0 && (fc.chromaP90 >= 25.0 || fb.chromaP90 >= 20.0 || fc.waveAB >= 11.5);
            }

            // Only switch candidate ref when the scan contradicts `top`:
            // - When both siblings share the same collector number (e.g. FIC Surge Foil #95 vs Normal #95),
            //   OCR did not choose between them, so `sameCollectorNum` allows both demotion and promotion.
            const sameCollectorNum = !top.num || !specSibling.num || listOrCollectorNumbersMatch(top.num, specSibling.num);
            const canDemoteTopSpec = topSpec && !isSpecial && (!top.ocr || sameCollectorNum);
            const canPromoteToSpec = !topSpec && isSpecial && (!top.ocr || sameCollectorNum);
            const shouldSwitchRef = canDemoteTopSpec || canPromoteToSpec;
            if (shouldSwitchRef || topSpec) {
                const keepSpec = topSpec ? !canDemoteTopSpec : isSpecial;
                const target = keepSpec ? specCand : baseCand;
                const targetVars = target.variants || [];
                const chosenVar =
                    (keepSpec
                        ? findVariant(targetVars, specKind) || findVariant(targetVars, 'Foil')
                        : findVariant(targetVars, 'Normal')) ||
                    targetVars.find((v) => v.primary) ||
                    targetVars[0] ||
                    null;

                return {
                    game: GAME_KEY,
                    ref: target.ref,
                    variantId: chosenVar?.id ?? null,
                    printing: chosenVar?.label ?? null,
                    changedRef: target.ref !== top.ref,
                    reason: keepSpec ? `special_sibling_${specKind}` : `base_normal_over_${specKind}`,
                    confidence: 0.88,
                    metrics: { card: fc, body: fb, specKind },
                };
            }
        }
    }

    // 2. Check Prerelease Cards (`['Foil']`) vs Base Set (`['Normal', 'Foil']`) sibling
    // Prerelease siblings are plain-named cards with the same collector number as the base card, never Extended Art / Showcase / Surge Foil.
    const isTopPrerelease = String(top.set_name || '').includes('Prerelease') || String(top.name || '').includes('Prerelease');
    const prereleaseSibling = !topSpec && isPlainReprintName(top.name)
        ? candidates.slice(1).find((c) => {
            if (baseCardName(c.name) !== topBase) return false;
            if (getSpecialSiblingFinish(c) || !isPlainReprintName(c.name)) return false;
            if (top.num && c.num && !listOrCollectorNumbersMatch(top.num, c.num)) return false;
            const cPre = String(c.set_name || '').includes('Prerelease') || String(c.name || '').includes('Prerelease');
            return isTopPrerelease !== cPre;
        })
        : null;
    if (prereleaseSibling) {
        const baseCand = isTopPrerelease ? prereleaseSibling : top;
        const preCand = isTopPrerelease ? top : prereleaseSibling;
        const baseSurf = getRefSurf(baseCand.ref) || getRefSurf(top.ref);
        if (baseSurf) {
            const aligned = alignReference(scanSurf, baseSurf);
            const fc = zoneFlatFoilMetrics(scanSurf, aligned, MTG_CARD_ZONE);
            const fb = zoneFlatFoilMetrics(scanSurf, aligned, MTG_BODY_ZONE);
            const sr = zoneFlatFoilMetrics(scanSurf, aligned, MTG_STAMP_RIGHT_ZONE);
            const sl = zoneFlatFoilMetrics(scanSurf, aligned, MTG_STAMP_LEFT_ZONE);
            const stampChroma = Math.max(sr.chromaP90, sl.chromaP90);

            let noPreStamp = false;
            const baseEntry = getRefEntry(baseCand.ref);
            const preEntry = getRefEntry(preCand.ref);
            if (baseEntry && preEntry && scanRgba) {
                const qFeat = extractReprintFeatures(scanRgba, scanW || 200, scanH || 280);
                const bFeat = extractReprintFeatures(baseEntry.rgba, baseEntry.w || 200, baseEntry.h || 280);
                const pFeat = extractReprintFeatures(preEntry.rgba, preEntry.w || 200, preEntry.h || 280);
                if (qFeat && bFeat && pFeat) {
                    const vsMtgArt = dgVote(qFeat.dg, bFeat.dg, pFeat.dg, 12, STAMP_MTG_ART);
                    const svPreR = stampRegionVote(qFeat, pFeat, bFeat, STAMP_MTG_ART, STAMP_MTG_RIGHT_X[0], STAMP_MTG_RIGHT_X[1], 10);
                    const svPreL = stampRegionVote(qFeat, pFeat, bFeat, STAMP_MTG_ART, STAMP_MTG_LEFT_X[0], STAMP_MTG_LEFT_X[1], 10);
                    if (
                        (vsMtgArt.v3 <= -0.30 && vsMtgArt.d >= 0.45)
                        || (svPreR.v >= 0.30 && svPreR.d >= 4.0 && vsMtgArt.v3 <= -0.75)
                        || (svPreL.v >= 0.45 && svPreL.d >= 7.0)
                        || (isTopPrerelease && vsMtgArt.d < 0.05 && svPreR.d < 0.5 && svPreL.d < 0.5)
                    ) {
                        noPreStamp = true;
                    }
                }
            }

            const isPreFoil = !noPreStamp && (
                (fb.chromaP90 >= 16.0 && (fc.chromaP90 >= 25.0 || fb.chromaP90 >= 22.0)) ||
                (fb.chromaP90 >= 14.0 && fb.texExcess <= 6.0 && stampChroma >= 30.0)
            );
            if (isTopPrerelease || isPreFoil) {
                const target = isPreFoil ? preCand : baseCand;
                const targetVars = target.variants || [];
                const chosenVar =
                    (isPreFoil ? findVariant(targetVars, 'Foil') : findVariant(targetVars, 'Normal')) ||
                    targetVars.find((v) => v.primary) ||
                    targetVars[0] ||
                    null;
                return {
                    game: GAME_KEY,
                    ref: target.ref,
                    variantId: chosenVar?.id ?? null,
                    printing: chosenVar?.label ?? null,
                    changedRef: target.ref !== top.ref,
                    reason: isPreFoil ? 'prerelease_foil_sibling' : 'base_normal_over_prerelease',
                    confidence: 0.9,
                    metrics: { card: fc, body: fb, stampChroma },
                };
            }
        }
    }

    // 2b. Check Retro Frame / Old Border vs Modern Frame sibling with matching artwork
    const isRetroName = (name) => /\((?:retro\s+frame|old\s+border)\)/i.test(String(name || ''));
    const topIsRetro = isRetroName(top.name);
    const retroSibling = !topSpec
        ? candidates.slice(1).find((c) => baseCardName(c.name) === topBase && isRetroName(c.name) !== topIsRetro)
        : null;
    if (retroSibling) {
        const modCand = topIsRetro ? retroSibling : top;
        const retCand = topIsRetro ? top : retroSibling;
        const modSurf = getRefSurf(modCand.ref);
        const retSurf = getRefSurf(retCand.ref);
        if (modSurf && retSurf) {
            const { W, H } = scanSurf;
            const ax0 = Math.round(0.14 * W), ay0 = Math.round(0.14 * H);
            const ax1 = Math.round(0.86 * W), ay1 = Math.round(0.50 * H);
            let mA = 0, mB = 0, nArt = 0;
            for (let y = ay0; y < ay1; y++) {
                for (let x = ax0; x < ax1; x++) {
                    const i = y * W + x;
                    mA += modSurf.L[i];
                    mB += retSurf.L[i];
                    nArt++;
                }
            }
            mA /= nArt;
            mB /= nArt;
            let dot = 0, dA = 0, dB = 0;
            for (let y = ay0; y < ay1; y++) {
                for (let x = ax0; x < ax1; x++) {
                    const i = y * W + x;
                    const va = modSurf.L[i] - mA;
                    const vb = retSurf.L[i] - mB;
                    dot += va * vb;
                    dA += va * va;
                    dB += vb * vb;
                }
            }
            const artNcc = dot / (Math.sqrt(dA * dB) + 1e-6);
            if (artNcc >= 0.30) {
                const borderZones = [
                    [0.04, 0.12, 0.10, 0.85],
                    [0.90, 0.12, 0.96, 0.85],
                    [0.10, 0.88, 0.90, 0.95],
                ];
                const frameChromaDist = (rSurf) => {
                    let s = 0, cnt = 0;
                    for (const [rx0, ry0, rx1, ry1] of borderZones) {
                        const x0 = Math.round(rx0 * W), y0 = Math.round(ry0 * H);
                        const x1 = Math.round(rx1 * W), y1 = Math.round(ry1 * H);
                        for (let y = y0; y < y1; y++) {
                            for (let x = x0; x < x1; x++) {
                                const i = y * W + x;
                                const da = scanSurf.A[i] - rSurf.A[i];
                                const db = scanSurf.B[i] - rSurf.B[i];
                                s += Math.hypot(da, db);
                                cnt++;
                            }
                        }
                    }
                    return cnt ? s / cnt : 999;
                };
                const dMod = frameChromaDist(modSurf);
                const dRet = frameChromaDist(retSurf);
                // Modern frame prints BLACK title letters on a bright pill box [20, 14, 130, 30];
                // Retro frame prints WHITE serif title letters directly on the dark/textured frame.
                const titleZncc = (sA, sB, maxDx = 6, maxDy = 10) => {
                    const x0 = 20, y0 = 14, x1 = 130, y1 = 30;
                    const n = (x1 - x0) * (y1 - y0);
                    let mB = 0;
                    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) mB += sB.L[y * W + x];
                    mB /= n;
                    let vB = 0;
                    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const b = sB.L[y * W + x] - mB; vB += b * b; }
                    if (vB < 1e-3) return 0;
                    let best = -2;
                    for (let dy = -maxDy; dy <= maxDy; dy++) {
                        for (let dx = -maxDx; dx <= maxDx; dx++) {
                            let mA = 0;
                            for (let y = y0; y < y1; y++) {
                                const yy = Math.max(0, Math.min(H - 1, y + dy)) * W;
                                for (let x = x0; x < x1; x++) mA += sA.L[yy + Math.max(0, Math.min(W - 1, x + dx))];
                            }
                            mA /= n;
                            let dotT = 0, vA = 0;
                            for (let y = y0; y < y1; y++) {
                                const yy = Math.max(0, Math.min(H - 1, y + dy)) * W;
                                const ry = y * W;
                                for (let x = x0; x < x1; x++) {
                                    const a = sA.L[yy + Math.max(0, Math.min(W - 1, x + dx))] - mA;
                                    const b = sB.L[ry + x] - mB;
                                    dotT += a * b;
                                    vA += a * a;
                                }
                            }
                            const c = dotT / (Math.sqrt(vA * vB) + 1e-6);
                            if (c > best) best = c;
                        }
                    }
                    return best;
                };
                const refTitleCorr = titleZncc(modSurf, retSurf, 2, 2);
                const tMod = refTitleCorr <= 0.45 ? titleZncc(scanSurf, modSurf) : 0;
                const tRet = refTitleCorr <= 0.45 ? titleZncc(scanSurf, retSurf) : 0;
                const retroByTitle = !topIsRetro && refTitleCorr <= 0.45 && tRet >= 0.42 && (tRet - tMod) >= 0.14;
                if (!topIsRetro && ((artNcc >= 0.55 && dRet + 6.0 < dMod) || retroByTitle)) {
                    const targetVars = retCand.variants || [];
                    const chosenVar = findVariant(targetVars, 'Normal') || targetVars.find((v) => v.primary) || targetVars[0] || null;
                    return {
                        game: GAME_KEY,
                        ref: retCand.ref,
                        variantId: chosenVar?.id ?? null,
                        printing: chosenVar?.label ?? null,
                        changedRef: true,
                        reason: 'retro_frame_chroma',
                        confidence: 0.9,
                        metrics: { dMod, dRet, artNcc, tMod, tRet },
                    };
                }
                const retroTitleHolds = refTitleCorr <= 0.45 && tRet >= 0.60 && (tRet - tMod) >= 0.25;
                if (topIsRetro && artNcc >= 0.55 && dMod + 6.0 < dRet && !retroTitleHolds) {
                    const targetVars = modCand.variants || [];
                    const chosenVar = findVariant(targetVars, 'Normal') || targetVars.find((v) => v.primary) || targetVars[0] || null;
                    return {
                        game: GAME_KEY,
                        ref: modCand.ref,
                        variantId: chosenVar?.id ?? null,
                        printing: chosenVar?.label ?? null,
                        changedRef: true,
                        reason: 'modern_frame_over_retro',
                        confidence: 0.9,
                        metrics: { dMod, dRet, artNcc },
                    };
                }
            }
        }
    }

    // 3. Same-ref Foil vs Normal
    const vars = Array.isArray(top.variants) ? top.variants : [];
    const varLabels = new Set(vars.map((v) => v.label));
    const topRefSurf = getRefSurf(top.ref);
    if (allowGenericSameRefFoil && varLabels.has('Foil') && varLabels.has('Normal') && topRefSurf) {
        const foilRes = detectMtgFoil(scanSurf, topRefSurf);
        const v = findVariant(vars, foilRes.isFoil ? 'Foil' : 'Normal');
        if (v) {
            return {
                game: GAME_KEY,
                ref: top.ref,
                variantId: v.id,
                printing: v.label,
                changedRef: false,
                reason: foilRes.isFoil ? 'mtg_flat_chroma_foil' : 'mtg_flat_clean_normal',
                confidence: foilRes.confidence,
                metrics: foilRes.metrics,
            };
        }
    }

    return null;
}

/**
 * Phone photos re-hash a tight warp that often clips the retro frame border, so frame chroma
 * on that warp stays silent. A decision from the original photo is used only for the two
 * frame-color reasons; every other variant reason stays on the warp result.
 */
export function framePhotoDecision(thumbDecision, photoDecision) {
    if (thumbDecision) return thumbDecision;
    if (photoDecision?.reason === 'retro_frame_chroma' || photoDecision?.reason === 'modern_frame_over_retro') return photoDecision;
    return null;
}

export function l2Dist(a, b) {
    if (!a || !b || a.length !== b.length) return 999;
    let s = 0;
    for (let i = 0; i < a.length; i++) { const d = a[i] - b[i]; s += d * d; }
    return Math.sqrt(s);
}

/** Match collector numbers including The List's "TMP-315" or "046/279" against "315" or "46". */
export function listOrCollectorNumbersMatch(a, b) {
    if (numbersMatch(a, b)) return true;
    const stripSetPrefix = (s) => String(s || '').replace(/^[A-Z0-9]{2,5}-/i, '').replace(/\/.*$/, '');
    const ca = canonNumber(stripSetPrefix(a));
    const cb = canonNumber(stripSetPrefix(b));
    return !!(ca && cb && ca === cb);
}

function rgbaLumaRange(rgba, x0, y0, x1, y1) {
    let mn = 999, mx = -999;
    for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
            const p = (y * CARD_W + x) * 4;
            const l = 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
            if (l < mn) mn = l;
            if (l > mx) mx = l;
        }
    }
    return mx - mn;
}

function mtgListIconCheck(qRgba, rListRgba, rBaseRgba) {
    if (!qRgba || !rListRgba || !rBaseRgba) return null;
    const bw = 8, bh = 9;
    let bestDiff = 0, bx = 6, by = 262;
    for (let y = 259; y <= 272 - bh; y++) {
        for (let x = 4; x <= 15 - bw; x++) {
            let d = 0;
            for (let yy = y; yy < y + bh; yy++) {
                for (let xx = x; xx < x + bw; xx++) {
                    const p = (yy * CARD_W + xx) * 4;
                    const lL = 0.299 * rListRgba[p] + 0.587 * rListRgba[p + 1] + 0.114 * rListRgba[p + 2];
                    const lB = 0.299 * rBaseRgba[p] + 0.587 * rBaseRgba[p + 1] + 0.114 * rBaseRgba[p + 2];
                    d += Math.max(0, lL - lB);
                }
            }
            if (d > bestDiff) { bestDiff = d; bx = x; by = y; }
        }
    }
    const n = bw * bh;
    const patchStats = (rgba, x0, y0) => {
        let s = 0, mn = 999, mx = -999;
        for (let y = y0; y < y0 + bh; y++) {
            for (let x = x0; x < x0 + bw; x++) {
                const p = (y * CARD_W + x) * 4;
                const l = 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
                s += l;
                if (l < mn) mn = l;
                if (l > mx) mx = l;
            }
        }
        const m = s / n;
        let v = 0;
        const vec = new Float32Array(n);
        let k = 0;
        for (let y = y0; y < y0 + bh; y++) {
            for (let x = x0; x < x0 + bw; x++) {
                const p = (y * CARD_W + x) * 4;
                const d = (0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2]) - m;
                vec[k++] = d;
                v += d * d;
            }
        }
        return { rng: mx - mn, std: Math.sqrt(v / n), norm: Math.sqrt(v), vec };
    };
    const lRef = patchStats(rListRgba, bx, by);
    const bRef = patchStats(rBaseRgba, bx, by);
    if (lRef.std < 45 || lRef.rng < 140 || bRef.std > 32 || bRef.rng > 90) return null;
    let bestC = -2, bestQ = null;
    for (let dy = -3; dy <= 5; dy++) {
        for (let dx = -2; dx <= 4; dx++) {
            const qx = bx + dx, qy = by + dy;
            if (qx < 2 || qx + bw > 20 || qy < 255 || qy + bh > 276) continue;
            const qS = patchStats(qRgba, qx, qy);
            let dot = 0;
            for (let i = 0; i < n; i++) dot += qS.vec[i] * lRef.vec[i];
            const cL = dot / (qS.norm * lRef.norm + 1e-6);
            if (cL > bestC) { bestC = cL; bestQ = qS; }
        }
    }
    if (!bestQ) return null;
    return { cL: bestC, stdQ: bestQ.std, rngQ: bestQ.rng, stdL: lRef.std, stdB: bRef.std };
}

function mtgPromoArtStampCheck(qRgba, rPromoRgba, rBaseRgba) {
    if (!qRgba || !rPromoRgba || !rBaseRgba) return null;
    const bw = 14, bh = 16;
    let bestDiff = 0, bx = 164, by = 130;
    for (let y = 122; y <= 148 - bh; y++) {
        for (let x = 152; x <= 184 - bw; x++) {
            let d = 0;
            for (let yy = y; yy < y + bh; yy++) {
                for (let xx = x; xx < x + bw; xx++) {
                    const p = (yy * CARD_W + xx) * 4;
                    const lP = 0.299 * rPromoRgba[p] + 0.587 * rPromoRgba[p + 1] + 0.114 * rPromoRgba[p + 2];
                    const lB = 0.299 * rBaseRgba[p] + 0.587 * rBaseRgba[p + 1] + 0.114 * rBaseRgba[p + 2];
                    d += Math.abs(lP - lB);
                }
            }
            if (d > bestDiff) { bestDiff = d; bx = x; by = y; }
        }
    }
    const refDiff = bestDiff / (bw * bh);
    if (refDiff < 20) return null;
    const n = bw * bh;
    const patchAt = (rgba, x0, y0) => {
        let s = 0;
        for (let y = y0; y < y0 + bh; y++) {
            for (let x = x0; x < x0 + bw; x++) {
                const p = (y * CARD_W + x) * 4;
                s += 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
            }
        }
        const m = s / n;
        let v = 0;
        const vec = new Float32Array(n);
        let k = 0;
        for (let y = y0; y < y0 + bh; y++) {
            for (let x = x0; x < x0 + bw; x++) {
                const p = (y * CARD_W + x) * 4;
                const d = (0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2]) - m;
                vec[k++] = d;
                v += d * d;
            }
        }
        return { std: Math.sqrt(v / n), norm: Math.sqrt(v), vec };
    };
    const cor = (a, b) => {
        let dot = 0;
        for (let i = 0; i < n; i++) dot += a.vec[i] * b.vec[i];
        return dot / (a.norm * b.norm + 1e-6);
    };
    const pRef = patchAt(rPromoRgba, bx, by);
    const bRef = patchAt(rBaseRgba, bx, by);
    let bestP = -2, stdQAtP = 0, bestB = -2;
    for (let dy = -3; dy <= 3; dy++) {
        for (let dx = -3; dx <= 3; dx++) {
            const qS = patchAt(qRgba, bx + dx, by + dy);
            const cP = cor(qS, pRef);
            const cB = cor(qS, bRef);
            if (cP > bestP) { bestP = cP; stdQAtP = qS.std; }
            if (cB > bestB) { bestB = cB; }
        }
    }
    let promGain = -2, promCP = -2, promCB = 0, promStdQ = 0;
    for (let dy = -4; dy <= 4; dy++) {
        for (let dx = -3; dx <= 13; dx++) {
            const qx = bx + dx, qy = by + dy;
            if (qx < 150 || qx + bw > 190 || qy < 118 || qy + bh > 154) continue;
            const qS = patchAt(qRgba, qx, qy);
            const bS = patchAt(rBaseRgba, qx, qy);
            const cP = cor(qS, pRef);
            const cB = cor(qS, bS);
            if (cP - Math.max(0, cB) > promGain) {
                promGain = cP - Math.max(0, cB);
                promCP = cP;
                promCB = cB;
                promStdQ = qS.std;
            }
        }
    }
    return {
        refDiff,
        cP: bestP,
        cB: bestB,
        stdP: pRef.std,
        stdB: bRef.std,
        stdQ: stdQAtP,
        promCP,
        promCB,
        promStdQ,
    };
}

/**
 * MTG Stage 3: The List bottom-left Planeswalker icon subhash & MTG Promo Pack / Prerelease art-box stamp.
 */
export function decideMtgReprintStage3(qFeat, pool, refFeats, details = {}, ocrDecided = false) {
    if (!qFeat || !Array.isArray(pool) || pool.length < 2) return null;
    const cur = pool[0].ref;
    const rf0 = refFeats.get(cur);
    if (!rf0) return null;

    const curName = details[cur]?.name || pool[0].tuple?.[1] || '';
    const curGroup = details[cur]?.group_name || details[cur]?.group_id || pool[0].tuple?.[4] || '';
    const curNum = details[cur]?.number || pool[0].tuple?.[2] || '';
    if (!curNum) return null;

    const STAMP_RE = /\b(?:stamped|prize pack|battle academy|trick or trade|pre-?release|promo pack)\b/i;
    const curStampText = `${curName} ${curGroup}`;
    const curHasStamp = STAMP_RE.test(curStampText);
    const curIsList = /^the list/i.test(curGroup);
    let bestStamp = null;

    for (const c of pool.slice(1)) {
        const cName = details[c.ref]?.name || c.tuple?.[1] || '';
        const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
        const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
        if (!cNum || !listOrCollectorNumbersMatch(curNum, cNum) || (cGroup && curGroup && cGroup === curGroup)) continue;
        const rfX = refFeats.get(c.ref);
        if (!rfX) continue;
        const cStampText = `${cName} ${cGroup}`;
        const cHasStamp = STAMP_RE.test(cStampText);
        const cIsList = /^the list/i.test(cGroup);

        const qList = qFeat.listIcon200 || qFeat.listIcon;
        if ((curIsList !== cIsList) && qList && rf0.listIcon && rfX.listIcon) {
            const d0 = l2Dist(qList, rf0.listIcon);
            const dX = l2Dist(qList, rfX.listIcon);
            const rr = l2Dist(rf0.listIcon, rfX.listIcon);
            if (rr >= 0.50 && (d0 - dX) >= 0.07) {
                const sc = d0 - dX;
                if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'the_list' };
                continue;
            }
            if (curIsList && !cIsList && qFeat.rgba && rf0.rgba && rfX.rgba) {
                const rng0 = rgbaLumaRange(rf0.rgba, 5, 262, 11, 270);
                const rngX = rgbaLumaRange(rfX.rgba, 5, 262, 11, 270);
                const rngQ = rgbaLumaRange(qFeat.rgba, 5, 262, 11, 270);
                if (rng0 >= 120 && rngX <= 40 && rngQ <= 35) {
                    const sc = 0.35;
                    if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'the_list' };
                    continue;
                }
            }
            if (!curIsList && cIsList && qFeat.rgba && rf0.rgba && rfX.rgba) {
                const listBox = mtgListIconCheck(qFeat.rgba, rfX.rgba, rf0.rgba);
                if (listBox && listBox.cL >= 0.85 && listBox.stdQ >= 30 && listBox.rngQ >= 100) {
                    const sc = 0.45;
                    if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'the_list' };
                    continue;
                }
            }
        }
        if (ocrDecided && !curIsList && !cIsList && !STAMP_RE.test(`${curStampText} ${cStampText}`)) {
            continue;
        }
        if (!numbersMatch(curNum, cNum)) continue;
        if (!curHasStamp && !cHasStamp) continue;

        const vs = dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, [[0.50, 0.68]]);
        const sv = stampRegionVote(qFeat, rf0, rfX, [[0.50, 0.68]], 0.50, 0.92, 12);
        const isMtgStamp = /\b(?:promo pack|pre-?release)\b/i.test(`${curStampText} ${cStampText}`);
        const svMtg = isMtgStamp ? stampRegionVote(qFeat, rf0, rfX, STAMP_MTG_ART, STAMP_MTG_RIGHT_X[0], STAMP_MTG_RIGHT_X[1], 10) : { v: 0, frac: 0, d: 0 };
        const svMtgLeft = isMtgStamp ? stampRegionVote(qFeat, rf0, rfX, STAMP_MTG_ART, STAMP_MTG_LEFT_X[0], STAMP_MTG_LEFT_X[1], 10) : { v: 0, frac: 0, d: 0 };
        const vsMtgArt = isMtgStamp ? dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, STAMP_MTG_ART) : { v3: 0, frac: 0, d: 0 };
        const promoBox = (isMtgStamp && curHasStamp && !cHasStamp)
            ? mtgPromoArtStampCheck(qFeat.rgba, rf0.rgba, rfX.rgba)
            : null;
        const promoBoxP = (isMtgStamp && !curHasStamp && cHasStamp)
            ? mtgPromoArtStampCheck(qFeat.rgba, rfX.rgba, rf0.rgba)
            : null;
        const okPromoDemote = !!(promoBox && (
            (promoBox.cB - promoBox.cP >= 0.20 && promoBox.cB >= 0.70)
            || (promoBox.stdP >= 30 && promoBox.stdB <= 15 && promoBox.stdQ <= 12 && promoBox.cP <= 0.55)
        ));
        const okPromoPromote = !!(promoBoxP && (
            promoBoxP.promCP >= 0.70
            && (promoBoxP.promCP - promoBoxP.promCB) >= 0.35
            && promoBoxP.promStdQ >= 25
            && promoBoxP.stdP >= 40
        ));

        const okDg = !isMtgStamp && (vs.v3 >= 0.55 && vs.frac >= 0.83 && vs.d >= 1.1) && (curHasStamp || sv.v >= 0.25);
        const okCh = !isMtgStamp && sv.v >= 0.25 && sv.frac >= 0.75 && sv.d >= 4.0 && vs.v3 >= 0.30 && (sv.v >= 0.30 || vs.frac >= 0.90);
        const okMtgArt = isMtgStamp && (
            (svMtg.v >= 0.25 && svMtg.frac >= 0.75 && svMtg.d >= 3.0 && vsMtgArt.v3 >= 0.15 && vsMtgArt.frac >= 0.55)
            || okPromoDemote
            || okPromoPromote
            || (curHasStamp && !cHasStamp && (
                (svMtg.v >= 0.25 && svMtg.frac >= 0.75 && vsMtgArt.v3 >= 0.10)
                || (vsMtgArt.v3 >= 0.50 && vsMtgArt.frac >= 0.75 && vsMtgArt.d >= 0.35)
                || (svMtgLeft.v >= 0.45 && svMtgLeft.frac >= 0.75 && svMtgLeft.d >= 7.0 && vsMtgArt.v3 >= 0.25)
            ))
        );
        if (okDg || okCh || okMtgArt) {
            const sc = Math.max(vs.v3, sv.v, svMtg.v, svMtgLeft.v, isMtgStamp ? vsMtgArt.v3 : 0, okPromoDemote ? 0.50 : 0, okPromoPromote ? 0.55 : 0);
            if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'stamp' };
        }
    }
    return bestStamp;
}

function zdotSymPatch(pA, pB, x0, y0, x1, y1, dy, dx) {
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

function zdotRgbaPatch(rgbaA, rgbaB, x0, y0, x1, y1, dy, dx) {
    const n = (x1 - x0) * (y1 - y0);
    let sA = 0, sB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(CARD_H - 1, y + dy)) * CARD_W;
        const ry = y * CARD_W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(CARD_W - 1, x + dx));
            const pq = (qy + qx) * 4;
            const pr = (ry + x) * 4;
            sA += 0.299 * rgbaA[pq] + 0.587 * rgbaA[pq + 1] + 0.114 * rgbaA[pq + 2];
            sB += 0.299 * rgbaB[pr] + 0.587 * rgbaB[pr + 1] + 0.114 * rgbaB[pr + 2];
        }
    }
    const mA = sA / n, mB = sB / n;
    let dot = 0, nA = 0, nB = 0;
    for (let y = y0; y < y1; y++) {
        const qy = Math.max(0, Math.min(CARD_H - 1, y + dy)) * CARD_W;
        const ry = y * CARD_W;
        for (let x = x0; x < x1; x++) {
            const qx = Math.max(0, Math.min(CARD_W - 1, x + dx));
            const pq = (qy + qx) * 4;
            const pr = (ry + x) * 4;
            const a = (0.299 * rgbaA[pq] + 0.587 * rgbaA[pq + 1] + 0.114 * rgbaA[pq + 2]) - mA;
            const b = (0.299 * rgbaB[pr] + 0.587 * rgbaB[pr + 1] + 0.114 * rgbaB[pr + 2]) - mB;
            dot += a * b;
            nA += a * a;
            nB += b * b;
        }
    }
    return dot / (Math.sqrt(nA * nB) + 1e-6);
}

/**
 * Shift-tolerant normalized cross-correlation over the MTG expansion symbol `[164, 153, 186, 170]`
 * and inner glyph `[171, 160, 183, 167]` on `200×280`.
 */
export function mtgSymCorr(qFeat, rFeat, maxShift = 4) {
    if (qFeat?.rgba && rFeat?.rgba) {
        let best = -2;
        for (let dy = -maxShift; dy <= maxShift; dy++) {
            for (let dx = -maxShift; dx <= maxShift; dx++) {
                const c = 0.45 * zdotRgbaPatch(qFeat.rgba, rFeat.rgba, 164, 153, 186, 170, dy, dx)
                    + 0.55 * zdotRgbaPatch(qFeat.rgba, rFeat.rgba, 171, 160, 183, 167, dy, dx);
                if (c > best) best = c;
            }
        }
        return best;
    }
    if (!qFeat?.hp1 || !qFeat?.hp3 || !rFeat?.hp1 || !rFeat?.hp3) return 0;
    let best = -2;
    for (let dy = -maxShift; dy <= maxShift; dy++) {
        for (let dx = -maxShift; dx <= maxShift; dx++) {
            const c = 0.5 * zdotSymPatch(qFeat.hp1, rFeat.hp1, 162, 152, 187, 171, dy, dx)
                + 0.5 * zdotSymPatch(qFeat.hp3, rFeat.hp3, 162, 152, 187, 171, dy, dx);
            if (c > best) best = c;
        }
    }
    return best;
}

/**
 * Guard Stage 4 ('corner') on MTG: do not let a noisy bottom-left corner flip when the MTG Set Symbol favors current candidate
 * or when the target candidate has a much worse full-card hash distance.
 */
export function guardMtgCornerDecision(baseDec, qFeat, rf0, refFeats, pool = null) {
    if (!baseDec || baseDec.stage !== 'corner') return baseDec;
    const rfWin = refFeats.get(baseDec.ref);
    const sym0 = (qFeat?.rgba && rf0?.rgba) ? mtgSymCorr(qFeat, rf0) : null;
    const symWin = (qFeat?.rgba && rfWin?.rgba) ? mtgSymCorr(qFeat, rfWin) : null;
    if (Array.isArray(pool) && pool.length >= 2) {
        const d0 = Number(pool[0]?.d ?? 0);
        const cWin = pool.find((c) => c.ref === baseDec.ref);
        const dWin = Number(cWin?.d ?? d0);
        const strongSymSupport = sym0 !== null && symWin !== null && symWin >= 0.82 && (symWin - sym0) >= 0.20;
        if (dWin - d0 >= 0.45 && !strongSymSupport) {
            return null;
        }
    }
    if (sym0 !== null && symWin !== null) {
        if (sym0 - symWin > 0.06) {
            return null;
        }
        if (Array.isArray(pool)) {
            for (const c of pool) {
                if (c.ref === baseDec.ref) continue;
                const rfC = refFeats.get(c.ref);
                if (rfC?.rgba && mtgSymCorr(qFeat, rfC) - symWin >= 0.10) {
                    return null;
                }
            }
        }
    } else if (qFeat?.hp1 && rf0?.hp1 && rfWin?.hp1) {
        const s0 = mtgSymCorr(qFeat, rf0);
        const sWin = mtgSymCorr(qFeat, rfWin);
        if (s0 - sWin > 0.06) {
            return null;
        }
    }
    if (qFeat?.mtgSym && rf0?.mtgSym && rfWin?.mtgSym) {
        const dSym0 = l2Dist(qFeat.mtgSym, rf0.mtgSym);
        const dSymWin = l2Dist(qFeat.mtgSym, rfWin.mtgSym);
        if (dSym0 - dSymWin < -0.10) {
            return null;
        }
    }
    return baseDec;
}

/**
 * Stage 4b: MTG Set Symbol + Collector Corner combined subhash tiebreak for same-art cross-set MTG reprints.
 */
export function decideMtgSymCornerStage4b(qFeat, pool, refFeats, details = {}) {
    if (!qFeat?.mtgSym || !Array.isArray(pool) || pool.length < 2) return null;
    const cur = pool[0].ref;
    const rf0 = refFeats.get(cur);
    if (!rf0?.mtgSym) return null;
    const curName = details[cur]?.name || pool[0].tuple?.[1] || '';
    const curGroup = details[cur]?.group_name || details[cur]?.group_id || pool[0].tuple?.[4] || '';
    if (!isPlainReprintName(curName)) return null;

    const STAMP_OR_LIST_RE = /\b(?:promo pack|pre-?release|prize pack|battle academy|trick or trade|the list)\b/i;
    const d0 = Number(pool[0]?.d ?? 0);
    let bestSym = null;
    const dSym0 = l2Dist(qFeat.mtgSym, rf0.mtgSym);
    const symCorr0 = mtgSymCorr(qFeat, rf0);
    for (const c of pool.slice(1)) {
        const cName = details[c.ref]?.name || c.tuple?.[1] || '';
        const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
        if (!isPlainReprintName(cName) || (cGroup && curGroup && cGroup === curGroup)) continue;
        if (STAMP_OR_LIST_RE.test(`${cName} ${cGroup}`)) continue;
        const rfX = refFeats.get(c.ref);
        if (!rfX?.mtgSym) continue;
        const dSymX = l2Dist(qFeat.mtgSym, rfX.mtgSym);
        const rrSym = l2Dist(rf0.mtgSym, rfX.mtgSym);
        const symCorrX = mtgSymCorr(qFeat, rfX);
        const symCorrGain = symCorrX - symCorr0;
        const cv = cornerVote(qFeat, rf0, rfX);
        const symGain = dSym0 - dSymX;
        const dx = Number(c.d ?? d0);
        const dGain = (Number.isFinite(d0) && Number.isFinite(dx)) ? (d0 - dx) : 0;
        const overwhelmingSymCorner = symCorrX >= 0.84 && symCorrGain >= 0.25 && cv.v >= 0.14 && cv.frac >= 0.55 && (cv.fitB - cv.fitA) >= 0.15;
        if ((dx - d0) >= 0.45 && !overwhelmingSymCorner) continue;
        // Pre-M15 bottom-left corners (illustrator + copyright) barely differ between sets and read dark, so a
        // decisive symbol match stands without the corner vote.
        const strongAlignedSym = overwhelmingSymCorner
            || (symCorrX >= 0.78 && symCorrGain >= 0.30)
            || (symCorrX >= 0.78 && symCorrGain >= 0.09 && (cv.v >= -0.05 || dGain >= 0.30))
            || (symCorrX >= 0.74 && symCorrGain >= 0.07 && cv.v >= 0.05 && cv.frac >= 0.50);
        const combinedSymCorner = rrSym >= 0.35 && symGain >= 0.22 && symCorrGain >= 0.05 && cv.v >= 0.08 && cv.frac >= 0.52 && (cv.fitB - cv.fitA) >= 0.01;
        if (strongAlignedSym || combinedSymCorner) {
            const sc = overwhelmingSymCorner
                ? 2.0 + symCorrGain
                : Math.max(symGain + cv.v, symCorrGain * 1.2 + Math.max(0, cv.v) + Math.max(0, dGain) * 0.4);
            if (!bestSym || sc > bestSym.sc) bestSym = { sc, ref: c.ref, stage: 'mtg_sym_corner' };
        }
    }
    return bestSym;
}
