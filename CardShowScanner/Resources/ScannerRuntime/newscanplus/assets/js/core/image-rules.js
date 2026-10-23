/**
 * image-rules.js - still-image (desktop upload) thresholds and the one-off single-card rule. No cv.
 *
 * IMAGE_GATES
 *   fullAspect [lo, hi]   min/max side ratio at which the frame itself is treated as one card
 *   maxRounds             paint-out passes after the first (image-scan.js)
 *   weakPct               match_pct of a solid extra card once two are already accepted
 *   noisePct              unaccepted quads below this match_pct are dropped
 *   noiseConf             desktop.js: unaccepted, no collector number, confidence under this is "No card found";
 *                         image-scan.js recrops only cards under it
 * ONE_OFF.trims           fractions of image height cut from top or bottom (larger leftover margin side first).
 *                         4% and 6% are the band that accepts a scanner crop with extra top and a clipped bottom;
 *                         2% and 8% do not. Tried only when a single-card upload accepted nothing.
 * ONE_OFF.pads            fractions of width/height the full frame grows on every side (warp fills black). For a
 *                         scan cut inside the card edge (black border lost, e.g. Makindi Sliderunner image0304.jpg:
 *                         d 13.3 gap 1.2 -> pad 3% d 7.0 gap 4.8). Tried only after the trims accepted nothing.
 *                         Lab eval (scripts/p4ub): 0 wrong accepts on 259 accepted + 62 unaccepted desk photos,
 *                         125 non-Magic negatives; recovers 8-26% of synthetic 1.5-3.5% inner crops.
 * oneOffQuads(W, H, quads) -> [{q, full: true, support: 0, trim, side}]
 *   [] unless the frame has a card aspect. q is the full frame with top or bottom trimmed. full stays true so the
 *   saved photo is the whole upload. Side order: the first non-full entry's larger of top/bottom margin first,
 *   then the opposite side (an interior art contour or glare edge can report the wrong margin side, e.g. desk
 *   T5TTE8BG Pompous Battlemage). Pass quads best match first (image-scan.js passes its matched list).
 * padQuads(W, H) -> [{q, full: true, support: 0, pad}]
 *   [] unless the frame has a card aspect. q is the full frame grown by each ONE_OFF.pads (corners off-image).
 */
export const IMAGE_GATES = Object.freeze({
    fullAspect: [0.55, 0.9],
    maxRounds: 4,
    weakPct: 35,
    noisePct: 24,
    noiseConf: 55,
});

export const ONE_OFF = Object.freeze({ trims: [0.04, 0.06], pads: [0.02, 0.03] });

function cardFrame(W, H) {
    const aspect = Math.min(W, H) / Math.max(W, H);
    const [lo, hi] = IMAGE_GATES.fullAspect;
    return W > 1 && H > 1 && aspect >= lo && aspect <= hi;
}

export function padQuads(W, H) {
    if (!cardFrame(W, H)) return [];
    return ONE_OFF.pads.map((p) => {
        const x = p * W, y = p * H;
        return { q: [[-x, -y], [W - 1 + x, -y], [W - 1 + x, H - 1 + y], [-x, H - 1 + y]], full: true, support: 0, pad: p };
    });
}

export function oneOffQuads(W, H, quads) {
    if (!cardFrame(W, H)) return [];
    const det = (quads || []).find((e) => e && !e.full && e.q?.length);
    let side = 't';
    if (det) {
        const ys = det.q.map((p) => p[1]);
        const top = Math.min(...ys);
        const bot = H - 1 - Math.max(...ys);
        if (bot > top) side = 'b';
    }
    const sides = side === 'b' ? ['b', 't'] : ['t', 'b'];
    return sides.flatMap((s) => ONE_OFF.trims.map((t) => {
        const cut = Math.round(t * H);
        const q = s === 'b'
            ? [[0, 0], [W - 1, 0], [W - 1, H - 1 - cut], [0, H - 1 - cut]]
            : [[0, cut], [W - 1, cut], [W - 1, H - 1], [0, H - 1]];
        return { q, full: true, support: 0, trim: t, side: s };
    }));
}

export function oneOffHorizontalQuads(W, H, quads) {
    if (!cardFrame(W, H)) return [];
    const det = (quads || []).find((e) => e && !e.full && e.q?.length);
    let hSide = 'r';
    if (det) {
        const xs = det.q.map((p) => p[0]);
        const left = Math.min(...xs);
        const right = W - 1 - Math.max(...xs);
        if (left > right) hSide = 'l';
    }
    const sides = hSide === 'l' ? ['l', 'r'] : ['r', 'l'];
    return sides.flatMap((s) => ONE_OFF.trims.map((t) => {
        const cut = Math.round(t * W);
        const q = s === 'r'
            ? [[0, 0], [W - 1 - cut, 0], [W - 1 - cut, H - 1], [0, H - 1]]
            : [[cut, 0], [W - 1, 0], [W - 1, H - 1], [cut, H - 1]];
        return { q, full: true, support: 0, trim: t, side: s };
    }));
}

export function padQuadsAspectAware(W, H) {
    if (!cardFrame(W, H)) return [];
    const out = [];
    const pushPad = (px, py, portraitForce = false) => {
        const x = px * W, y = py * H;
        out.push({
            q: [[-x, -y], [W - 1 + x, -y], [W - 1 + x, H - 1 + y], [-x, H - 1 + y]],
            full: true,
            support: 0,
            pad: Math.max(px, py),
            portraitForce,
        });
    };
    for (const p of [0.02, 0.03, 0.04, 0.06]) pushPad(p, p);
    const aspect = Math.min(W, H) / Math.max(W, H);
    if (W < H && aspect < 0.675) {
        for (const [px, py] of [[0.06, 0.02], [0.06, 0.03], [0.07, 0.02], [0.07, 0.03], [0.08, 0.02], [0.08, 0.03], [0.08, 0.04]]) {
            pushPad(px, py);
        }
    }
    if (W > H && aspect < 0.715) {
        for (const [px, py] of [[0.02, 0.06], [0.03, 0.06], [0.02, 0.08], [0.03, 0.08], [0.02, 0.10], [0.03, 0.10]]) {
            pushPad(px, py);
        }
    }
    if (W > H && aspect > 0.72) {
        for (const [px, py] of [[0.02, 0.12], [0.03, 0.14], [0.02, 0.18], [0.03, 0.18]]) {
            pushPad(px, py, true);
        }
        for (const pyTop of [0.12, 0.18, 0.72]) {
            const yTop = pyTop * H, yBot = 0.02 * H;
            out.push({
                q: [[0, -yTop], [W - 1, -yTop], [W - 1, H - 1 + yBot], [0, H - 1 + yBot]],
                full: true,
                support: 0,
                pad: pyTop,
                portraitForce: true,
            });
        }
    }
    return out;
}
