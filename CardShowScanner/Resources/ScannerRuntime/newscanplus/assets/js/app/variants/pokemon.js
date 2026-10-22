/**
 * variants/pokemon.js — Dedicated single-image variant & sibling detection for Pokemon (tcgp:3).
 *
 * Handles when scanning on 'Any' printing preference:
 *  1. WOTC 1st Edition / 1st Edition Holofoil vs Unlimited / Unlimited Holofoil:
 *     - Creature lower-left art stamp patch (0.035..0.115, 0.515..0.590) with 8-connected
 *       component shape test, top-right art-frame leak rejection, and local patch clip guard.
 *     - WOTC Trainer bottom-left stamp patch (0.145..0.245, 0.875..0.922).
 *     - Reference-guided Unlimited flip: when the CDN reference image has the 1st Edition stamp
 *       (Jungle, Fossil, Team Rocket, Gym Heroes/Challenge, Neo Genesis/Discovery) and the scan
 *       patch is clean (`blob <= 0.025`), switches to Unlimited / Unlimited Holofoil.
 *  2. WOTC Holo Rare vs Non-Holo Rare sibling detection (Jungle / Fossil / Team Rocket / Base Set 2).
 *  3. Modern Reverse Holofoil vs Holofoil vs Normal detection using reference-aligned flat-pixel
 *     body/art luma variance and high-frequency foil pattern excess.
 *  4. Same-set Pattern / Stamped sibling switching (e.g. ME: Ascended Heroes / SV Poke Ball,
 *     Love Ball, Friend Ball, Dusk Ball, Quick Ball, Energy Symbol Pattern vs Base Normal).
 */

import {
    toWorkSurface,
    alignReference,
    zoneFlatFoilMetrics,
    findVariant,
    baseCardName,
    dgVote,
    stampRegionVote,
} from './common.js';
import { numbersMatch } from '../../core/ocr/layouts.js';

export const GAME_KEY = 'tcgp:3';

export const CREATURE_STAMP_RECT = [0.035, 0.515, 0.115, 0.59];
export const TRAINER_STAMP_RECT = [0.145, 0.875, 0.245, 0.922];
export const BODY_ZONE = [0.10, 0.56, 0.90, 0.86];
export const ART_ZONE = [0.12, 0.12, 0.88, 0.46];
export const STAMP_TOT_ART = [[0.46, 0.62]];
// Play! Pokemon Prize Pack logo: the boxed Poke Ball at the art's lower-right corner, [x0, y0, x1, y1] of the card.
export const PRIZE_PACK_LOGO_RECT = [0.83, 0.365, 0.97, 0.475];
// The Prize Pack ref only carries a logo (Series 3+) when it decorrelates from the plain ref inside the box.
export const PRIZE_PACK_REF_NCC_MAX = 0.6;
export const PRIZE_PACK_LOGO_MARGIN = 0.15;
// The winning ref must also match the scan box outright (an uncropped / tilted photo correlates with neither).
export const PRIZE_PACK_PRESENT_MIN = 0.5;
const PRIZE_PACK_RE = /\bprize pack\b/i;

const WOTC_1ST_SETS = new Set([
    'Base Set',
    'Jungle',
    'Fossil',
    'Team Rocket',
    'Gym Heroes',
    'Gym Challenge',
    'Neo Genesis',
    'Neo Discovery',
    'Neo Revelation',
    'Neo Destiny',
]);

const PATTERN_MARKERS = [
    'Energy Symbol Pattern',
    'Poke Ball',
    'Love Ball',
    'Friend Ball',
    'Dusk Ball',
    'Quick Ball',
    'Master Ball',
];

/**
 * Inspect a stamp patch `rect = [rx0, ry0, rx1, ry1]` for a compact dark ink blob
 * (Pokemon "Edition 1" circle+T stamp) against a lighter border surround.
 */
export function stampBlob(surf, rect = CREATURE_STAMP_RECT, use8Conn = true) {
    if (!surf) return { blob: 0, shaped: false, borderTouch: 4, cx: 0.5, cy: 0.5, localClip: 1, surMean: 0 };
    const { W, H, L, R, G, Bl } = surf;
    const x0 = Math.max(0, Math.round(rect[0] * W));
    const y0 = Math.max(0, Math.round(rect[1] * H));
    const x1 = Math.min(W, Math.round(rect[2] * W));
    const y1 = Math.min(H, Math.round(rect[3] * H));
    const pw = x1 - x0;
    const ph = y1 - y0;
    if (pw < 4 || ph < 4) {
        return { blob: 0, shaped: false, borderTouch: 4, cx: 0.5, cy: 0.5, localClip: 1, surMean: 0 };
    }

    // Local clip inside the stamp patch only (glare in the art window must not veto the stamp patch)
    let clipCnt = 0;
    const totalPx = pw * ph;
    for (let y = y0; y < y1; y++) {
        const row = y * W;
        for (let x = x0; x < x1; x++) {
            const i = row + x;
            if (R[i] >= 250 && G[i] >= 250 && Bl[i] >= 250) clipCnt++;
        }
    }
    const localClip = clipCnt / totalPx;

    // 2px border ring mean luma
    let surSum = 0;
    let surCnt = 0;
    for (let y = y0; y < y1; y++) {
        const row = y * W;
        for (let x = x0; x < x1; x++) {
            if (y - y0 < 2 || y1 - 1 - y < 2 || x - x0 < 2 || x1 - 1 - x < 2) {
                surSum += L[row + x];
                surCnt++;
            }
        }
    }
    const surMean = surCnt ? surSum / surCnt : 0;
    if (surMean < 55) {
        return { blob: 0, shaped: false, borderTouch: 4, cx: 0.5, cy: 0.5, localClip, surMean };
    }

    const cutoff = surMean * 0.78;
    const mask = new Uint8Array(pw * ph);
    let darkCnt = 0;
    for (let y = 0; y < ph; y++) {
        const row = (y0 + y) * W + x0;
        for (let x = 0; x < pw; x++) {
            if (L[row + x] < cutoff) {
                mask[y * pw + x] = 1;
                darkCnt++;
            }
        }
    }
    const blob = darkCnt / totalPx;
    if (!darkCnt) {
        return { blob: 0, shaped: false, borderTouch: 0, cx: 0.5, cy: 0.5, localClip, surMean };
    }

    const seen = new Uint8Array(pw * ph);
    const dirs = use8Conn
        ? [
              [-1, -1], [-1, 0], [-1, 1],
              [0, -1],           [0, 1],
              [1, -1],  [1, 0],  [1, 1],
          ]
        : [
              [-1, 0], [1, 0], [0, -1], [0, 1],
          ];

    let bestSize = 0;
    let bestTouch = 4;
    let bestCx = 0.5;
    let bestCy = 0.5;
    let bestTr = false;

    for (let sy = 0; sy < ph; sy++) {
        for (let sx = 0; sx < pw; sx++) {
            const start = sy * pw + sx;
            if (!mask[start] || seen[start]) continue;
            seen[start] = 1;
            const q = [start];
            let sz = 0;
            let sumX = 0;
            let sumY = 0;
            let top = false;
            let bot = false;
            let left = false;
            let right = false;
            while (q.length) {
                const cur = q.pop();
                const cx = cur % pw;
                const cy = (cur - cx) / pw;
                sz++;
                sumX += cx;
                sumY += cy;
                if (cy === 0) top = true;
                if (cy === ph - 1) bot = true;
                if (cx === 0) left = true;
                if (cx === pw - 1) right = true;
                for (const [dy, dx] of dirs) {
                    const ny = cy + dy;
                    const nx = cx + dx;
                    if (ny < 0 || ny >= ph || nx < 0 || nx >= pw) continue;
                    const ni = ny * pw + nx;
                    if (mask[ni] && !seen[ni]) {
                        seen[ni] = 1;
                        q.push(ni);
                    }
                }
            }
            if (sz > bestSize) {
                bestSize = sz;
                bestTouch = (top ? 1 : 0) + (bot ? 1 : 0) + (left ? 1 : 0) + (right ? 1 : 0);
                bestCx = sumX / sz / pw;
                bestCy = sumY / sz / ph;
                bestTr = top && right;
            }
        }
    }

    const compFrac = bestSize / totalPx;
    // Compute bounding box aspect ratio and fill density for the largest component
    // Re-scan mask for bounding box of largest component
    let minX = pw, maxX = 0, minY = ph, maxY = 0;
    const seen2 = new Uint8Array(pw * ph);
    for (let sy = 0; sy < ph; sy++) {
        for (let sx = 0; sx < pw; sx++) {
            const start = sy * pw + sx;
            if (!mask[start] || seen2[start]) continue;
            seen2[start] = 1;
            const q = [start];
            let sz = 0;
            let lx0 = pw, lx1 = 0, ly0 = ph, ly1 = 0;
            while (q.length) {
                const cur = q.pop();
                const cx = cur % pw;
                const cy = (cur - cx) / pw;
                sz++;
                if (cx < lx0) lx0 = cx;
                if (cx > lx1) lx1 = cx;
                if (cy < ly0) ly0 = cy;
                if (cy > ly1) ly1 = cy;
                for (const [dy, dx] of dirs) {
                    const ny = cy + dy;
                    const nx = cx + dx;
                    if (ny < 0 || ny >= ph || nx < 0 || nx >= pw) continue;
                    const ni = ny * pw + nx;
                    if (mask[ni] && !seen2[ni]) {
                        seen2[ni] = 1;
                        q.push(ni);
                    }
                }
            }
            if (sz === bestSize) {
                minX = lx0;
                maxX = lx1;
                minY = ly0;
                maxY = ly1;
            }
        }
    }
    const bw = Math.max(1, maxX - minX + 1);
    const bh = Math.max(1, maxY - minY + 1);
    const aspect = Math.max(bw / bh, bh / bw);
    const fill = bestSize / (bw * bh);
    const topRightCorner = bestCx >= 0.72 && bestCy <= 0.28;

    const shaped =
        compFrac >= 0.025 &&
        compFrac <= 0.42 &&
        bestTouch <= 2 &&
        !bestTr &&
        !topRightCorner &&
        aspect <= 3.0 &&
        fill >= 0.18 &&
        bestCx >= 0.18 &&
        bestCx <= 0.82 &&
        bestCy >= 0.18 &&
        bestCy <= 0.82;

    return { blob, shaped, borderTouch: bestTouch, cx: bestCx, cy: bestCy, localClip, surMean, compFrac, aspect, fill };
}

/**
 * Evaluate Pokemon 1st Edition vs Unlimited stamp state on `scanSurf` (and optional `refSurf`).
 */
export function detectPokemonEdition(scanSurf, refSurf = null) {
    const cScan = stampBlob(scanSurf, CREATURE_STAMP_RECT, true);
    const tScan = stampBlob(scanSurf, TRAINER_STAMP_RECT, false);
    const cRef = refSurf ? stampBlob(refSurf, CREATURE_STAMP_RECT, true) : null;

    const creature1st = cScan.localClip <= 0.08 && cScan.shaped && cScan.blob >= 0.025 && cScan.blob <= 0.45;
    const trainer1st =
        tScan.localClip <= 0.05 &&
        tScan.shaped &&
        tScan.blob >= 0.06 &&
        tScan.blob <= 0.42 &&
        tScan.compFrac >= 0.12 &&
        tScan.borderTouch <= 1 &&
        (cScan.blob < 0.08 || !cScan.shaped);

    if (creature1st || trainer1st) {
        return {
            edition: '1st Edition',
            confidence: creature1st ? Math.min(1, cScan.blob / 0.15) : Math.min(0.9, tScan.blob / 0.15),
            reason: creature1st ? 'creature_1st_stamp' : 'trainer_1st_stamp',
            metrics: { cScan, tScan, cRef },
        };
    }

    // Reference-guided Unlimited detection: when the CDN reference image has a visible 1st Edition
    // stamp (or simply when the scan's creature stamp patch is clean or unshaped compared to the ref stamp),
    // confirm Unlimited.
    const refHas1st = Boolean(cRef && cRef.shaped && cRef.blob >= 0.08);
    const scanClean =
        cScan.localClip <= 0.04 &&
        !cScan.shaped &&
        (cScan.blob <= 0.035 || (refHas1st && cScan.blob <= cRef.blob * 0.55)) &&
        cScan.surMean >= 75;
    if (scanClean && (refHas1st || cScan.blob <= 0.015)) {
        return {
            edition: 'Unlimited',
            confidence: refHas1st ? 0.95 : 0.82,
            reason: refHas1st ? 'ref_has_1st_stamp_scan_clean' : 'scan_patch_clean_unlimited',
            metrics: { cScan, tScan, cRef },
        };
    }

    return { edition: null, confidence: 0, reason: 'inconclusive_edition', metrics: { cScan, tScan, cRef } };
}

/**
 * Evaluate Modern Reverse Holofoil vs Holofoil vs Normal on `scanSurf` against `refSurf`.
 */
export function detectPokemonFinish(scanSurf, refSurf) {
    if (!scanSurf || !refSurf) return { finish: null, isReverseHolo: false, isHoloArt: false, metrics: null };
    const aligned = alignReference(scanSurf, refSurf);
    const body = zoneFlatFoilMetrics(scanSurf, aligned, BODY_ZONE);
    const art = zoneFlatFoilMetrics(scanSurf, aligned, ART_ZONE);

    const bodyArtLumaRatio = body.lumaStd / (art.lumaStd + 1.0);
    const isReverseHolo =
        (body.texExcess >= 7.5 && body.lumaStd >= 10.0) ||
        (body.lumaStd >= 18.0 && bodyArtLumaRatio >= 0.85);
    const isHoloArt = art.lumaStd >= 14.0 || art.chromaP90 >= 26.0 || art.waveL >= 18.0;

    return {
        finish: isReverseHolo ? 'Reverse Holofoil' : isHoloArt ? 'Holofoil' : 'Normal',
        isReverseHolo,
        isHoloArt,
        metrics: { body, art, bodyArtLumaRatio },
    };
}

function hasPatternMarker(name) {
    const text = String(name || '');
    return PATTERN_MARKERS.some((m) => text.includes(m));
}

/**
 * Main entry point for Pokemon single-image variant & sibling resolution when on 'Any' scan.
 *
 * @param {object} params
 * @param {Uint8ClampedArray|Uint8Array} params.scanRgba - Cropped scan RGBA pixels
 * @param {number} [params.scanW=200]
 * @param {number} [params.scanH=280]
 * @param {object[]} params.candidates - Ranked candidate array (each `{ ref, name, set_name, variants, ... }`)
 * @param {Map<string,{rgba:Uint8Array,w:number,h:number}>|Record<string,{rgba:Uint8Array,w:number,h:number}>} [params.refImages]
 */
export function resolvePokemonVariant({
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

    const getRefSurf = (refKey) => {
        if (!refImages || !refKey) return null;
        const entry = refImages instanceof Map ? refImages.get(refKey) : refImages[refKey];
        if (!entry || !entry.rgba) return null;
        return toWorkSurface(entry.rgba, entry.w || 200, entry.h || 280);
    };

    const topRefSurf = getRefSurf(top.ref);
    const vars = Array.isArray(top.variants) ? top.variants : [];
    const varLabels = new Set(vars.map((v) => v.label));

    // 1. Check WOTC Holo Rare vs Non-Holo Rare sibling first if top candidate is in a WOTC set
    const topBase = baseCardName(top.name);
    if (WOTC_1ST_SETS.has(top.set_name) && topRefSurf) {
        const wotcSib = candidates.slice(1).find((c) => {
            if (c.set_name !== top.set_name || baseCardName(c.name) !== topBase) return false;
            const tHolo = vars.some((v) => String(v.label).includes('Holofoil'));
            const cHolo = (c.variants || []).some((v) => String(v.label).includes('Holofoil'));
            return tHolo !== cHolo;
        });
        if (wotcSib) {
            const fin = detectPokemonFinish(scanSurf, topRefSurf);
            const tHolo = vars.some((v) => String(v.label).includes('Holofoil'));
            const targetCand = fin.isHoloArt === tHolo ? top : wotcSib;
            const targetRefSurf = getRefSurf(targetCand.ref) || topRefSurf;
            const ed = detectPokemonEdition(scanSurf, targetRefSurf);
            const targetVars = targetCand.variants || [];
            let chosenVar = targetVars.find((v) => v.primary) || targetVars[0] || null;
            if (ed.edition === '1st Edition') {
                chosenVar =
                    findVariant(targetVars, (v) => String(v.label).startsWith('1st Edition')) || chosenVar;
            } else if (ed.edition === 'Unlimited') {
                chosenVar =
                    findVariant(targetVars, (v) => String(v.label).startsWith('Unlimited')) || chosenVar;
            }
            return {
                game: GAME_KEY,
                ref: targetCand.ref,
                variantId: chosenVar?.id ?? null,
                printing: chosenVar?.label ?? null,
                changedRef: targetCand.ref !== top.ref,
                reason: 'wotc_holo_sibling_and_edition',
                confidence: Math.max(ed.confidence, 0.85),
                metrics: { finish: fin.metrics, edition: ed.metrics },
            };
        }
    }

    // 2. Same-ref 1st Edition / Unlimited (including 1st Edition Holofoil vs Unlimited Holofoil)
    const has1stOption = vars.some((v) => String(v.label).startsWith('1st Edition'));
    const hasUnlOption = vars.some((v) => String(v.label).startsWith('Unlimited'));
    if (has1stOption && hasUnlOption) {
        const ed = detectPokemonEdition(scanSurf, topRefSurf);
        if (ed.edition === '1st Edition') {
            const v = findVariant(vars, (x) => String(x.label).startsWith('1st Edition'));
            if (v) {
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
        } else if (ed.edition === 'Unlimited') {
            const v = findVariant(vars, (x) => String(x.label).startsWith('Unlimited'));
            if (v) {
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
        }
    }

    // 3. Same-set Base <-> Pattern (Energy Symbol Pattern / Poke Ball / Love Ball / Friend Ball / Dusk Ball / Quick Ball) sibling
    const patSibling = candidates.slice(1).find((c) => {
        if (c.set_name !== top.set_name || baseCardName(c.name) !== topBase) return false;
        return hasPatternMarker(c.name) !== hasPatternMarker(top.name);
    });
    if (patSibling && !(varLabels.has('Reverse Holofoil') && !hasPatternMarker(top.name))) {
        const topIsPat = hasPatternMarker(top.name);
        const baseCand = topIsPat ? patSibling : top;
        const patCand = topIsPat ? top : patSibling;
        const baseSurf = getRefSurf(baseCand.ref) || topRefSurf;
        if (baseSurf) {
            const aligned = alignReference(scanSurf, baseSurf);
            const fb = zoneFlatFoilMetrics(scanSurf, aligned, BODY_ZONE);
            const fa = zoneFlatFoilMetrics(scanSurf, aligned, ART_ZONE);
            const isPatFoil =
                (fb.texExcess >= 7.5 && fb.lumaStd >= 14.0) ||
                (fb.lumaStd >= 22.0 && fb.lumaStd / (fa.lumaStd + 1.0) >= 0.85);
            const target = isPatFoil ? patCand : baseCand;
            const targetVars = target.variants || [];
            const chosenVar =
                (isPatFoil
                    ? findVariant(targetVars, 'Reverse Holofoil') || findVariant(targetVars, 'Holofoil')
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
                reason: isPatFoil ? 'pattern_reverse_holo_sibling' : 'clean_base_normal_sibling',
                confidence: 0.88,
                metrics: { body: fb, art: fa },
            };
        }
    }

    // 4. Same-ref Modern Reverse Holofoil vs Normal / Holofoil
    if (allowGenericSameRefFoil && varLabels.has('Reverse Holofoil') && topRefSurf) {
        const fin = detectPokemonFinish(scanSurf, topRefSurf);
        if (fin.isReverseHolo) {
            const v = findVariant(vars, 'Reverse Holofoil');
            if (v) {
                return {
                    game: GAME_KEY,
                    ref: top.ref,
                    variantId: v.id,
                    printing: v.label,
                    changedRef: false,
                    reason: 'body_flat_reverse_holo',
                    confidence: 0.86,
                    metrics: fin.metrics,
                };
            }
        } else {
            const fallback =
                (varLabels.has('Normal') && findVariant(vars, 'Normal')) ||
                (varLabels.has('Holofoil') && findVariant(vars, 'Holofoil')) ||
                vars.find((v) => v.primary) ||
                vars[0];
            if (fallback) {
                return {
                    game: GAME_KEY,
                    ref: top.ref,
                    variantId: fallback.id,
                    printing: fallback.label,
                    changedRef: false,
                    reason: 'body_flat_non_reverse',
                    confidence: 0.82,
                    metrics: fin.metrics,
                };
            }
        }
    }

    return null;
}

/**
 * True when a Pokemon tuple belongs to a high-penalty promo group (`Miscellaneous Cards & Products`,
 * `Deck Exclusives`, `League & Championship Cards`, or Cosmos/Mirage Holo / Pokemon League outside Trick or Trade)
 * that should include same-number regular-set (`setPenalty === 0`) candidates in `candidatesFrom`.
 */
export function isPokemonFalsePosPromoGroup(tuple) {
    const group = tuple?.[4] || '';
    const name = tuple?.[1] || '';
    return /\b(?:miscellaneous cards|deck exclusives|league & championship)\b/i.test(group)
        || (/\((?:cosmos?|mirage)\s+holo\)|what's your favorite stamp|pokemon league/i.test(name) && !/trick or trade/i.test(group));
}

function grayOf(rgba, n) {
    const g = new Float32Array(n);
    for (let i = 0; i < n; i++) g[i] = 0.299 * rgba[4 * i] + 0.587 * rgba[4 * i + 1] + 0.114 * rgba[4 * i + 2];
    return g;
}

function boxNcc(a, b, w, [x0, y0, x1, y1], dx, dy) {
    let sa = 0, sb = 0, n = 0;
    for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) { sa += a[(y + dy) * w + x + dx]; sb += b[y * w + x]; n++; }
    }
    const ma = sa / n, mb = sb / n;
    let dot = 0, na = 0, nb = 0;
    for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
            const u = a[(y + dy) * w + x + dx] - ma, v = b[y * w + x] - mb;
            dot += u * v; na += u * u; nb += v * v;
        }
    }
    return dot / (Math.sqrt(na * nb) + 1e-6);
}

/**
 * Prize Pack logo presence on a 200x280 scan, judged against the Prize Pack ref and a same-number plain ref.
 * -> {state: 'present' | 'absent' | 'unknown' | 'no_logo', q2pp, q2plain, refNcc}
 *   'no_logo': the Prize Pack ref has no logo in the box (Series 1-2 / same render), so this cannot decide.
 */
export function prizePackLogoVote(qRgba, ppRgba, plainRgba, w = 200, h = 280) {
    if (!qRgba || !ppRgba || !plainRgba) return { state: 'unknown', q2pp: 0, q2plain: 0, refNcc: 1 };
    const n = w * h;
    const box = [
        Math.round(PRIZE_PACK_LOGO_RECT[0] * w), Math.round(PRIZE_PACK_LOGO_RECT[1] * h),
        Math.round(PRIZE_PACK_LOGO_RECT[2] * w), Math.round(PRIZE_PACK_LOGO_RECT[3] * h),
    ];
    const S = 4;
    if (box[0] - S < 0 || box[2] + S > w || box[1] - S < 0 || box[3] + S > h) return { state: 'unknown', q2pp: 0, q2plain: 0, refNcc: 1 };
    const q = grayOf(qRgba, n), pp = grayOf(ppRgba, n), pl = grayOf(plainRgba, n);
    const refNcc = boxNcc(pp, pl, w, box, 0, 0);
    if (refNcc > PRIZE_PACK_REF_NCC_MAX) return { state: 'no_logo', q2pp: 0, q2plain: 0, refNcc };
    let q2pp = -1, q2plain = -1;
    for (let dy = -S; dy <= S; dy++) {
        for (let dx = -S; dx <= S; dx++) {
            q2pp = Math.max(q2pp, boxNcc(q, pp, w, box, dx, dy));
            q2plain = Math.max(q2plain, boxNcc(q, pl, w, box, dx, dy));
        }
    }
    const m = q2pp - q2plain;
    const state = m >= PRIZE_PACK_LOGO_MARGIN && q2pp >= PRIZE_PACK_PRESENT_MIN ? 'present'
        : (-m >= PRIZE_PACK_LOGO_MARGIN && q2plain >= PRIZE_PACK_PRESENT_MIN ? 'absent' : 'unknown');
    return { state, q2pp, q2plain, refNcc };
}

/**
 * Pokemon Stage 3: Trick or Trade pumpkin art stamp, Prize Pack, and Battle Academy stamp disambiguation.
 * A Prize Pack candidate whose ref carries the logo is decided by prizePackLogoVote first: present promotes it
 * (stage 'pp_logo'), absent removes it from the generic stamp votes and demotes a Prize Pack lead.
 */
/**
 * Shift-tolerant zero-mean normalized cross-correlation over the Trick or Trade Pikachu pumpkin
 * stamp box `[144, 116, 184, 150]` on `200×280` (normalizes out phone exposure/glare).
 */
export function pokemonTotPumpkinCheck(qRgba, rBaseRgba, rTotRgba) {
    if (!qRgba || !rBaseRgba || !rTotRgba) return null;
    const W = 200, H = 280;
    const x0 = 144, y0 = 116, x1 = 184, y1 = 150;
    const n = (x1 - x0) * (y1 - y0);
    const extract = (rgba, dx, dy, chFn) => {
        const out = new Float32Array(n);
        let sum = 0, k = 0;
        for (let y = y0; y < y1; y++) {
            const yy = Math.max(0, Math.min(H - 1, y + dy));
            for (let x = x0; x < x1; x++) {
                const xx = Math.max(0, Math.min(W - 1, x + dx));
                const i = (yy * W + xx) * 4;
                const v = chFn(rgba[i], rgba[i + 1], rgba[i + 2]);
                out[k++] = v;
                sum += v;
            }
        }
        const mean = sum / n;
        let sq = 0;
        for (let i = 0; i < n; i++) { out[i] -= mean; sq += out[i] * out[i]; }
        const std = Math.sqrt(sq / n) || 1e-6;
        for (let i = 0; i < n; i++) out[i] /= std;
        return out;
    };
    const dot = (a, b) => { let s = 0; for (let i = 0; i < n; i++) s += a[i] * b[i]; return s / n; };
    const luma = (r, g, b) => 0.299 * r + 0.587 * g + 0.114 * b;
    const yb = (r, g, b) => 0.5 * (r + g) - b;

    const bL = extract(rBaseRgba, 0, 0, luma), tL = extract(rTotRgba, 0, 0, luma);
    const bY = extract(rBaseRgba, 0, 0, yb), tY = extract(rTotRgba, 0, 0, yb);
    const refCorr = 0.5 * dot(bL, tL) + 0.5 * dot(bY, tY);
    if (refCorr > 0.72) return null;

    let bestT = -2, bestB = -2;
    for (let dy = -3; dy <= 3; dy++) {
        for (let dx = -3; dx <= 3; dx++) {
            const qL = extract(qRgba, dx, dy, luma);
            const qY = extract(qRgba, dx, dy, yb);
            const cT = 0.5 * dot(qL, tL) + 0.5 * dot(qY, tY);
            const cB = 0.5 * dot(qL, bL) + 0.5 * dot(qY, bY);
            if (cT > bestT) bestT = cT;
            if (cB > bestB) bestB = cB;
        }
    }
    return { cT: bestT, cB: bestB, gain: bestT - bestB, refCorr };
}

export function decidePokemonReprintStage3(qFeat, pool, refFeats, details = {}, ocrDecided = false) {
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
    let bestStamp = null;

    const textOf = (c) => `${details[c.ref]?.name || c.tuple?.[1] || ''} ${details[c.ref]?.group_name || c.tuple?.[4] || ''}`;
    const sameNum = pool.filter((c) => {
        const n = details[c.ref]?.number || c.tuple?.[2] || '';
        return n && numbersMatch(curNum, n) && refFeats.get(c.ref)?.rgba;
    });
    const ppCand = sameNum.find((c) => PRIZE_PACK_RE.test(textOf(c)));
    const plainRef = sameNum.find((c) => !STAMP_RE.test(textOf(c)) && !/deck exclusives/i.test(textOf(c)))
        || sameNum.find((c) => !STAMP_RE.test(textOf(c)));
    let ppLogo = 'unknown';
    if (ppCand && plainRef && qFeat.rgba) {
        ppLogo = prizePackLogoVote(qFeat.rgba, refFeats.get(ppCand.ref).rgba, refFeats.get(plainRef.ref).rgba).state;
        const curIsPp = cur === ppCand.ref;
        if (ppLogo === 'present') return curIsPp ? null : { ref: ppCand.ref, stage: 'pp_logo', sc: 1 };
        if (ppLogo === 'absent' && curIsPp && !ocrDecided) {
            const target = sameNum.find((c) => c.ref !== cur && !PRIZE_PACK_RE.test(textOf(c)) && !STAMP_RE.test(textOf(c)) && !/deck exclusives/i.test(textOf(c)))
                || sameNum.find((c) => c.ref !== cur && !PRIZE_PACK_RE.test(textOf(c)));
            if (target) return { ref: target.ref, stage: 'pp_logo', sc: 1 };
        }
    }

    for (const c of pool.slice(1)) {
        const cName = details[c.ref]?.name || c.tuple?.[1] || '';
        const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
        const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
        if (!cNum || !numbersMatch(curNum, cNum) || (cGroup && curGroup && cGroup === curGroup)) continue;
        if (ppLogo === 'absent' && c.ref === ppCand?.ref) continue;
        if (ocrDecided && /\((?:cosmos?|mirage)\s+holo\)|what's your favorite stamp|pokemon league/i.test(cName) && !/trick or trade/i.test(cGroup)) {
            continue;
        }
        const cStampText = `${cName} ${cGroup}`;
        const cHasStamp = STAMP_RE.test(cStampText);
        if (!curHasStamp && !cHasStamp) continue;

        const rfX = refFeats.get(c.ref);
        if (!rfX) continue;

        const vs = dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, [[0.50, 0.68]]);
        const sv = stampRegionVote(qFeat, rf0, rfX, [[0.50, 0.68]], 0.50, 0.92, 12);
        const isTotStamp = /trick or trade/i.test(`${curStampText} ${cStampText}`);
        const svTot = isTotStamp ? stampRegionVote(qFeat, rf0, rfX, STAMP_TOT_ART, 0.68, 0.94, 10) : { v: 0, frac: 0, d: 0 };
        const hasLowerStamp = /\b(?:battle academy|stamped)\b/i.test(`${curStampText} ${cStampText}`);
        const vsLo = hasLowerStamp ? dgVote(qFeat.dg, rf0.dg, rfX.dg, 12, [[0.68, 0.85]]) : { v3: 0, frac: 0, d: 0 };

        // Trick or Trade lead is decided only by the pumpkin region (not text-box okDg).
        if (isTotStamp && curHasStamp) {
            const pumpkinAbsent = svTot.v >= 0.12 && svTot.frac >= 0.60 && svTot.d >= 2.2 && !cHasStamp;
            if (pumpkinAbsent) {
                const sc = svTot.v;
                if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'stamp' };
            }
            continue;
        }

        const totBox = (isTotStamp && !curHasStamp && qFeat.rgba && rf0.rgba && rfX.rgba)
            ? pokemonTotPumpkinCheck(qFeat.rgba, rf0.rgba, rfX.rgba)
            : null;
        const okTotNcc = !!(totBox && totBox.cT >= 0.68 && totBox.cB <= 0.65 && totBox.gain >= 0.08);

        const okDg = ((vs.v3 >= 0.55 && vs.frac >= 0.83 && vs.d >= 1.1) && (curHasStamp || sv.v >= 0.25))
            || (vsLo.v3 >= 0.55 && vsLo.frac >= 0.83 && vsLo.d >= 1.1 && curHasStamp);
        const okCh = (sv.v >= 0.25 && sv.frac >= 0.75 && sv.d >= 4.0 && vs.v3 >= 0.30 && (sv.v >= 0.30 || vs.frac >= 0.90))
            || (!curHasStamp && /\b(?:trick or trade|pre-?release|stamped)\b/i.test(cStampText) && sv.v >= 0.20 && sv.frac >= 0.65 && sv.d >= 4.9);
        const okTot = isTotStamp && !curHasStamp && (
            (svTot.v >= 0.12 && svTot.frac >= 0.60 && svTot.d >= 2.2)
            || (sv.v >= 0.14 && sv.frac >= 0.60 && sv.d >= 3.2)
            || (vs.v3 >= 0.35 && vs.frac >= 0.75 && vs.d >= 0.8)
            || okTotNcc
        );

        if (okDg || okCh || okTot) {
            const sc = Math.max(vs.v3, vsLo.v3, sv.v, svTot.v, okTotNcc ? Math.max(0.36, totBox.gain) : 0);
            if (!bestStamp || sc > bestStamp.sc) bestStamp = { sc, ref: c.ref, stage: 'stamp' };
        }
    }

    // Keep-gate: a Battle Academy 2022 / Prize Pack / Deck Exclusives (Non-Holo) lead stands only on positive stamp evidence.
    // In Oct 10-17 commit data BA2022 leads were corrected 35/35 and Prize Pack leads 33/44, while
    // BA2024 and Trick or Trade are mixed and stay hash-led. When neither the demote votes above
    // nor a mirrored keep-vote (query closer to the stamped ref than to the plain sibling)
    // confirm the stamp, the unique same-number plain sibling leads instead.
    if (!bestStamp && (!ocrDecided || /^deck exclusives$/i.test(curGroup)) && /battle academy 2022|prize pack|deck exclusives/i.test(curStampText)) {
        const plains = pool.slice(1).filter((c) => {
            const cName = details[c.ref]?.name || c.tuple?.[1] || '';
            const cGroup = details[c.ref]?.group_name || details[c.ref]?.group_id || c.tuple?.[4] || '';
            const cNum = details[c.ref]?.number || c.tuple?.[2] || '';
            return cNum && numbersMatch(curNum, cNum) && !(cGroup && curGroup && cGroup === curGroup)
                && !STAMP_RE.test(`${cName} ${cGroup}`) && !/^deck exclusives$/i.test(cGroup) && refFeats.get(c.ref);
        });
        if (plains.length === 1) {
            const rfP = refFeats.get(plains[0].ref);
            const vsK = dgVote(qFeat.dg, rfP.dg, rf0.dg, 12, [[0.50, 0.68]]);
            const svK = stampRegionVote(qFeat, rfP, rf0, [[0.50, 0.68]], 0.50, 0.92, 12);
            const vsLoK = dgVote(qFeat.dg, rfP.dg, rf0.dg, 12, [[0.68, 0.85]]);
            const keep = (vsK.v3 >= 0.55 && vsK.frac >= 0.83 && vsK.d >= 1.1)
                || (vsLoK.v3 >= 0.55 && vsLoK.frac >= 0.83 && vsLoK.d >= 1.1)
                || (svK.v >= 0.25 && svK.frac >= 0.75 && svK.d >= 4.0 && vsK.v3 >= 0.30 && (svK.v >= 0.30 || vsK.frac >= 0.90));
            if (!keep) bestStamp = { sc: 0, ref: plains[0].ref, stage: 'stamp' };
        }
    }
    return bestStamp;
}
