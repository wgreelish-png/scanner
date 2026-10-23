/**
 * variants/lorcana.js — Dedicated single-image Cold Foil vs Normal detection for Disney Lorcana (tcgp:71).
 *
 * Physical signature:
 *  Lorcana Cold Foil cards produce a strong vertical luminance wave (`card.waveL >= 24.0`) and
 *  elevated flat-pixel luma standard deviation (`card.lumaStd >= 21.0`) with chroma shift
 *  (`card.chromaP90 >= 40.0`) when compared against the aligned CDN reference image.
 */

import { toWorkSurface, alignReference, zoneFlatFoilMetrics, findVariant } from './common.js';

export const GAME_KEY = 'tcgp:71';

export const LORCANA_CARD_ZONE = [0.08, 0.08, 0.92, 0.88];
export const LORCANA_BODY_ZONE = [0.10, 0.56, 0.90, 0.86];

/**
 * Evaluate Cold Foil vs Normal on a Lorcana scan surface against its aligned reference surface.
 */
export function detectLorcanaColdFoil(scanSurf, refSurf) {
    if (!scanSurf || !refSurf) return { isColdFoil: false, confidence: 0, metrics: null };
    const aligned = alignReference(scanSurf, refSurf);
    const card = zoneFlatFoilMetrics(scanSurf, aligned, LORCANA_CARD_ZONE);
    const body = zoneFlatFoilMetrics(scanSurf, aligned, LORCANA_BODY_ZONE);

    const isColdFoil = card.waveL >= 24.0 || (card.lumaStd >= 21.0 && card.chromaP90 >= 40.0);
    return {
        isColdFoil,
        confidence: isColdFoil ? Math.min(0.96, Math.max(card.waveL / 35, card.lumaStd / 30)) : 0.92,
        metrics: { card, body },
    };
}

/**
 * Main entry point for Disney Lorcana single-image variant resolution when on 'Any' scan.
 */
export function resolveLorcanaVariant({
    scanRgba,
    scanW = 200,
    scanH = 280,
    candidates = [],
    refImages = null,
}) {
    if (!candidates.length) return null;
    const top = candidates[0];
    const vars = Array.isArray(top.variants) ? top.variants : [];
    const varLabels = new Set(vars.map((v) => v.label));
    if (!varLabels.has('Cold Foil') || !varLabels.has('Normal')) return null;

    const getRefSurf = (refKey) => {
        if (!refImages || !refKey) return null;
        const entry = refImages instanceof Map ? refImages.get(refKey) : refImages[refKey];
        if (!entry || !entry.rgba) return null;
        return toWorkSurface(entry.rgba, entry.w || 200, entry.h || 280);
    };

    const scanSurf = toWorkSurface(scanRgba, scanW, scanH);
    const refSurf = getRefSurf(top.ref);
    if (!scanSurf || !refSurf) return null;

    const res = detectLorcanaColdFoil(scanSurf, refSurf);
    const v = findVariant(vars, res.isColdFoil ? 'Cold Foil' : 'Normal');
    if (!v) return null;

    return {
        game: GAME_KEY,
        ref: top.ref,
        variantId: v.id,
        printing: v.label,
        changedRef: false,
        reason: res.isColdFoil ? 'lorcana_cold_foil_wave' : 'lorcana_flat_normal',
        confidence: res.confidence,
        metrics: res.metrics,
    };
}
