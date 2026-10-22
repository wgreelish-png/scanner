/**
 * variants/onepiece.js — Dedicated single-image Base vs Reprint & Foil sibling disambiguator for One Piece (tcgp:68).
 *
 * Implements targeted subhash & structural alignment regions for resolving same-card-number One Piece
 * base vs reprint printings (`PRB-01`, `PRB-02`, `ST15+`, `SD01`, `LT-01`, `ST-31..36`, `OP-RP`, `OP-DD`, `OP-PR`):
 *   - R1  [0.960, 0.082, 0.025, 0.150]: Top-right vertical border artist credit + paintbrush/pencil icon
 *         (Era 1 OP01..OP05 / ST01..ST12 has paintbrush at y=0.086..0.103 and shifts artist name down;
 *          Era 2/3 PRB-01, PRB-02, ST15+ removes paintbrush icon and shifts artist name up).
 *   - R2a [0.960, 0.650, 0.025, 0.030]: Bottom-right vertical border "EN" block icon
 *         (y=0.656..0.680 above MADE IN JAPAN; dark ink on PRB-02, ST-21..ST-36, OP10+,
 *          pure white on OP01..OP09, PRB-01, ST-01..ST-20).
 *   - R3b [0.912, 0.932, 0.035, 0.028]: Block number devil-fruit circle (① vs ④ on ST-31..ST-36).
 *   - R4a [0.775, 0.730, 0.155, 0.105]: SD01 / LT-01 deck emblem stamp (Luffy/Ace/Koby/Zoro Deck).
 *   - R4b [0.600, 0.614, 0.310, 0.122]: Pre-Release / Release Event / Serial gold stamp.
 *   - R6a [0.070, 0.600, 0.860, 0.210] & R6b [0.200, 0.820, 0.600, 0.150]:
 *         Effect text box & Name/Trait bar subhash + stroke density + anisotropy
 *         (post-errata OP-RP, OP-DD Demo Deck, OP-PR stamps, and JP vs EN text box diffs).
 */

import { cv } from '../../core/cv.js';
import {
    findVariant,
    baseCardName,
    resizeArea200,
    extractReprintFeatures,
    dgVote,
    subhashDist,
} from './common.js';

export const GAME_KEY = 'tcgp:68';

export const ONEPIECE_ROIS = {
    // R1: Top-right vertical border artist credit + paintbrush icon (y=0.086..0.103)
    R1_ARTIST:      [0.960, 0.082, 0.025, 0.150],
    R1_PAINTBRUSH:  [0.956, 0.086, 0.030, 0.020],
    // R2a: Bottom-right vertical border "EN" block icon (y=0.656..0.680) + copyright tail
    R2A_EN_ICON:    [0.960, 0.650, 0.025, 0.030],
    R2_COPYRIGHT:   [0.955, 0.640, 0.032, 0.280],
    // R3b: Bottom-right block number circle (① vs ④) + card number box
    R3B_BLOCK_NUM:  [0.912, 0.932, 0.035, 0.028],
    R3_CARD_ID:     [0.730, 0.920, 0.220, 0.050],
    // R4: Deck emblem stamp (SD01 / LT-01) & Pre-Release / Event stamp
    R4A_DECK_STAMP: [0.775, 0.730, 0.155, 0.105],
    R4B_PRE_STAMP:  [0.600, 0.614, 0.310, 0.122],
    // R6a & R6b: Effect text box & Name/Trait bar (JP vs EN stroke density + errata diffs)
    R6A_TEXTBOX:    [0.070, 0.600, 0.860, 0.210],
    R6B_NAME_BAR:   [0.200, 0.820, 0.600, 0.150],
};

/**
 * Resize an RGBA or RGB image to canonical 600x840 RGB (`INTER_AREA` when shrinking, `INTER_CUBIC` when enlarging).
 * Falls back to pure JS bilinear resize when OpenCV (`cv`) is not initialized in the current thread.
 */
export function toWarp600(img) {
    if (img.width === 600 && img.height === 840 && img.channels === 3) return img;
    const sw = img.width, sh = img.height;
    const ch = img.channels || (img.data.length === sw * sh * 4 ? 4 : 3);
    if (cv?.Mat) {
        const src = new cv.Mat(sh, sw, ch === 4 ? cv.CV_8UC4 : cv.CV_8UC3);
        src.data.set(img.data);
        const rgb = new cv.Mat();
        if (ch === 4) cv.cvtColor(src, rgb, cv.COLOR_RGBA2RGB);
        else src.copyTo(rgb);
        const dst = new cv.Mat();
        const interp = (sw > 600 && sh > 840) ? cv.INTER_AREA : cv.INTER_CUBIC;
        cv.resize(rgb, dst, new cv.Size(600, 840), 0, 0, interp);
        const out = { data: new Uint8Array(dst.data), width: 600, height: 840, channels: 3 };
        src.delete(); rgb.delete(); dst.delete();
        return out;
    }
    const W = 600, H = 840;
    const out = new Uint8Array(W * H * 3);
    const d = img.data;
    for (let y = 0; y < H; y++) {
        const fy = ((y + 0.5) * sh) / H - 0.5;
        const y0 = Math.max(0, Math.min(sh - 1, Math.floor(fy)));
        const y1 = Math.min(sh - 1, y0 + 1);
        const wy = Math.max(0, fy - y0);
        for (let x = 0; x < W; x++) {
            const fx = ((x + 0.5) * sw) / W - 0.5;
            const x0 = Math.max(0, Math.min(sw - 1, Math.floor(fx)));
            const x1 = Math.min(sw - 1, x0 + 1);
            const wx = Math.max(0, fx - x0);
            const i00 = (y0 * sw + x0) * ch, i01 = (y0 * sw + x1) * ch;
            const i10 = (y1 * sw + x0) * ch, i11 = (y1 * sw + x1) * ch;
            const di = (y * W + x) * 3;
            for (let c = 0; c < 3; c++) {
                const v0 = d[i00 + c] * (1 - wx) + d[i01 + c] * wx;
                const v1 = d[i10 + c] * (1 - wx) + d[i11 + c] * wx;
                out[di + c] = Math.round(v0 * (1 - wy) + v1 * wy);
            }
        }
    }
    return { data: out, width: W, height: H, channels: 3 };
}

/**
 * Extract 600x840 grayscale + high-pass (hp1, hp3) + stroke anisotropy + 200x280 reprint features for One Piece.
 */
export function extractOnePieceFeatures(img) {
    const w600 = toWarp600(img);
    const W = 600, H = 840, N = W * H;
    const gray = new Float32Array(N);
    const d = w600.data;

    for (let i = 0; i < N; i++) {
        gray[i] = 0.299 * d[i * 3] + 0.587 * d[i * 3 + 1] + 0.114 * d[i * 3 + 2];
    }

    const hp1 = boxHighPass(gray, W, H, 2);
    const hp3 = boxHighPass(gray, W, H, 5);

    const strokeR6a = computeTextStrokeStats(hp1, W, H, ONEPIECE_ROIS.R6A_TEXTBOX);
    const strokeR6b = computeTextStrokeStats(hp1, W, H, ONEPIECE_ROIS.R6B_NAME_BAR);

    const rgba = new Uint8Array(img.width * img.height * 4);
    const ch = img.channels || (img.data.length === img.width * img.height * 4 ? 4 : 3);
    if (ch === 4) {
        rgba.set(img.data);
    } else {
        for (let i = 0, j = 0; i < img.data.length; i += 3, j += 4) {
            rgba[j] = img.data[i];
            rgba[j + 1] = img.data[i + 1];
            rgba[j + 2] = img.data[i + 2];
            rgba[j + 3] = 255;
        }
    }
    const f200 = extractReprintFeatures(resizeArea200(rgba, img.width, img.height));

    return { w600, gray, hp1, hp3, strokeR6a, strokeR6b, f200, W, H };
}

function computeTextStrokeStats(hp1, W, H, roiNorm) {
    const [x0, y0, x1, y1] = roiToPx(roiNorm, W, H);
    let gxSum = 0, gySum = 0, highEdgeCount = 0, n = 0;
    for (let y = y0 + 1; y < y1 - 1; y += 2) {
        const row = y * W;
        for (let x = x0 + 1; x < x1 - 1; x += 2) {
            const gx = Math.abs(hp1[row + x + 1] - hp1[row + x - 1]);
            const gy = Math.abs(hp1[row + W + x] - hp1[row - W + x]);
            gxSum += gx;
            gySum += gy;
            if (gx + gy > 24) highEdgeCount++;
            n++;
        }
    }
    return {
        density: n > 0 ? highEdgeCount / n : 0,
        anisotropy: gySum > 0 ? gxSum / gySum : 1,
        meanGrad: n > 0 ? (gxSum + gySum) / n : 0,
    };
}

function boxHighPass(gray, W, H, r) {
    const tmp = new Float32Array(W * H);
    const out = new Float32Array(W * H);
    const invW = 1 / (2 * r + 1);
    for (let y = 0; y < H; y++) {
        const row = y * W;
        let sum = 0;
        for (let k = -r; k <= r; k++) sum += gray[row + Math.max(0, Math.min(W - 1, k))];
        tmp[row] = sum * invW;
        for (let x = 1; x < W; x++) {
            sum += gray[row + Math.min(W - 1, x + r)] - gray[row + Math.max(0, x - r - 1)];
            tmp[row + x] = sum * invW;
        }
    }
    for (let x = 0; x < W; x++) {
        let sum = 0;
        for (let k = -r; k <= r; k++) sum += tmp[Math.max(0, Math.min(H - 1, k)) * W + x];
        out[x] = gray[x] - sum * invW;
        for (let y = 1; y < H; y++) {
            sum += tmp[Math.min(H - 1, y + r) * W + x] - tmp[Math.max(0, y - r - 1) * W + x];
            out[y * W + x] = gray[y * W + x] - sum * invW;
        }
    }
    return out;
}

function roiToPx([rx, ry, rw, rh], W = 600, H = 840) {
    const x0 = Math.max(0, Math.round(rx * W));
    const y0 = Math.max(0, Math.round(ry * H));
    const x1 = Math.min(W, Math.round((rx + rw) * W));
    const y1 = Math.min(H, Math.round((ry + rh) * H));
    return [x0, y0, x1, y1];
}

function extractNormPatch(plane, W, H, [x0, y0, x1, y1], dy = 0, dx = 0) {
    const bw = x1 - x0, bh = y1 - y0;
    const stride = (bw * bh > 9000) ? 2 : 1;
    const w = Math.ceil(bw / stride), h = Math.ceil(bh / stride), n = w * h;
    const out = new Float32Array(n);
    let sum = 0, k = 0;
    for (let y = y0; y < y1; y += stride) {
        const yy = Math.max(0, Math.min(H - 1, y + dy)) * W;
        for (let x = x0; x < x1; x += stride) {
            const xx = Math.max(0, Math.min(W - 1, x + dx));
            const v = plane[yy + xx];
            out[k++] = v;
            sum += v;
        }
    }
    const mean = sum / n;
    let sq = 0;
    for (let i = 0; i < n; i++) {
        out[i] -= mean;
        sq += out[i] * out[i];
    }
    const std = Math.sqrt(sq / n) || 1;
    for (let i = 0; i < n; i++) out[i] /= std;
    return { out, mean, std };
}

function alignRegion600(qFeat, rFeat, pxBox, dyMax = 9, dxMax = 6, step = 3) {
    const [x0, y0, x1, y1] = pxBox;
    const W = 600, H = 840;
    const bw = x1 - x0, bh = y1 - y0;
    const stride = (bw * bh > 8000) ? 3 : ((bw * bh > 2500) ? 2 : 1);

    function fastCorr(dy, dx) {
        let sQ = 0, sR = 0, n = 0;
        for (let y = y0; y < y1; y += stride) {
            const qy = Math.max(0, Math.min(H - 1, y + dy)) * W;
            const ry = y * W;
            for (let x = x0; x < x1; x += stride) {
                const qx = Math.max(0, Math.min(W - 1, x + dx));
                sQ += qFeat.hp1[qy + qx];
                sR += rFeat.hp1[ry + x];
                n++;
            }
        }
        const mQ = sQ / n, mR = sR / n;
        let dot = 0, nQ = 0, nR = 0;
        for (let y = y0; y < y1; y += stride) {
            const qy = Math.max(0, Math.min(H - 1, y + dy)) * W;
            const ry = y * W;
            for (let x = x0; x < x1; x += stride) {
                const qx = Math.max(0, Math.min(W - 1, x + dx));
                const a = qFeat.hp1[qy + qx] - mQ;
                const b = rFeat.hp1[ry + x] - mR;
                dot += a * b;
                nQ += a * a;
                nR += b * b;
            }
        }
        return dot / (Math.sqrt(nQ * nR) + 1e-6);
    }

    let bestCorr = -1e9, bdy = 0, bdx = 0;
    for (let dy = -dyMax; dy <= dyMax; dy += step) {
        for (let dx = -dxMax; dx <= dxMax; dx += step) {
            const corr = fastCorr(dy, dx);
            if (corr > bestCorr) {
                bestCorr = corr;
                bdy = dy;
                bdx = dx;
            }
        }
    }
    const cdy = bdy, cdx = bdx;
    for (let dy = cdy - 2; dy <= cdy + 2; dy++) {
        for (let dx = cdx - 2; dx <= cdx + 2; dx++) {
            const corr = fastCorr(dy, dx);
            if (corr > bestCorr) {
                bestCorr = corr;
                bdy = dy;
                bdx = dx;
            }
        }
    }
    return { dy: bdy, dx: bdx, corr: bestCorr };
}

/**
 * Difference-guided vote on a specific ROI between two reference candidates A (base) and B (reprint).
 * Positive return value favors B; negative favors A.
 */
export function roiDiffVote600(qFeat, aFeat, bFeat, roiNorm, anchorNorm = null, dyRange = 12, dxRange = 8) {
    const W = 600, H = 840;
    const pxBox = roiToPx(roiNorm, W, H);
    const anchorBox = anchorNorm ? roiToPx(anchorNorm, W, H) : pxBox;

    const alA = alignRegion600(qFeat, aFeat, anchorBox, dyRange, dxRange, 2);
    const alB = alignRegion600(qFeat, bFeat, anchorBox, dyRange, dxRange, 2);
    const alBA = alignRegion600(bFeat, aFeat, anchorBox, 8, 6, 2);

    let voteSum = 0, weightSum = 0;
    let fitASum = 0, fitBSum = 0;
    let diffSum = 0;

    for (const planeName of ['hp1', 'hp3', 'gray']) {
        const pA = extractNormPatch(aFeat[planeName], W, H, pxBox, 0, 0);
        const pB_aligned = extractNormPatch(bFeat[planeName], W, H, pxBox, alBA.dy, alBA.dx);
        const pB_raw = extractNormPatch(bFeat[planeName], W, H, pxBox, 0, 0);
        const qA = extractNormPatch(qFeat[planeName], W, H, pxBox, alA.dy, alA.dx);
        const qB = extractNormPatch(qFeat[planeName], W, H, pxBox, alB.dy, alB.dx);

        const n = pA.out.length;
        let cA = 0, cB = 0, abDiffAligned = 0, abDiffRaw = 0;
        let sa = 0, sb = 0, dab = 0;
        for (let i = 0; i < n; i++) {
            const va = pA.out[i];
            const vbAl = pB_aligned.out[i];
            const vbRaw = pB_raw.out[i];
            const qa = qA.out[i], qb = qB.out[i];
            cA += qa * va;
            cB += qb * vbRaw;
            const dAl = Math.abs(va - vbAl);
            const dRaw = Math.abs(va - vbRaw);
            abDiffAligned += dAl;
            abDiffRaw += dRaw;
            const dUse = Math.min(dAl, dRaw);
            if (dUse > 0.38) {
                const w = dUse * dUse;
                sa += Math.abs(qa - va) * dUse;
                sb += Math.abs(qb - vbRaw) * dUse;
                dab += w;
            }
        }
        fitASum += cA / n;
        fitBSum += cB / n;
        diffSum += Math.min(abDiffAligned, abDiffRaw) / n;

        const v = dab > 0 ? (sa - sb) / dab : 0;
        const pw = planeName === 'hp1' ? 0.45 : (planeName === 'hp3' ? 0.35 : 0.20);
        voteSum += v * pw;
        weightSum += pw;
    }

    const rawA = extractNormPatch(aFeat.gray, W, H, pxBox, 0, 0);
    const rawB = extractNormPatch(bFeat.gray, W, H, pxBox, alBA.dy, alBA.dx);
    const rawQ = extractNormPatch(qFeat.gray, W, H, pxBox, Math.round((alA.dy + alB.dy) / 2), Math.round((alA.dx + alB.dx) / 2));
    const stdDiffAB = Math.abs(rawA.std - rawB.std);
    let inkVote = 0;
    if (stdDiffAB > 4.0) {
        const dStdA = Math.abs(rawQ.std - rawA.std);
        const dStdB = Math.abs(rawQ.std - rawB.std);
        inkVote = (dStdA - dStdB) / (stdDiffAB + 4.0);
    }

    const fitA = fitASum / 3;
    const fitB = fitBSum / 3;
    const fitDiff = fitB - fitA;
    const diffStrength = diffSum / 3 + stdDiffAB / 40;
    const combinedVote = 0.50 * (voteSum / weightSum) + 0.35 * fitDiff + 0.15 * Math.max(-1, Math.min(1, inkVote));

    return {
        vote: combinedVote,
        fitDiff,
        fitA,
        fitB,
        inkVote,
        diffStrength,
        alA,
        alB,
        alBA,
    };
}

/**
 * Score a pair of One Piece candidates (A = base/c0, B = reprint candidate) across all 5 specialized regions.
 */
export function compareOnePiecePair(qFeat, aFeat, bFeat) {
    const anchorTopRight = [0.910, 0.060, 0.082, 0.200];
    const anchorBotRight = [0.850, 0.620, 0.142, 0.350];
    const anchorCardId   = [0.720, 0.905, 0.250, 0.070];
    const anchorStamp    = [0.720, 0.700, 0.230, 0.160];
    const anchorText     = [0.060, 0.580, 0.880, 0.240];

    const r1 = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R1_ARTIST, anchorTopRight, 12, 8);
    const r1Brush = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R1_PAINTBRUSH, anchorTopRight, 12, 8);
    const r2a = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R2A_EN_ICON, anchorBotRight, 12, 8);
    const r2Cpy = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R2_COPYRIGHT, anchorBotRight, 12, 8);
    const r3b = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R3B_BLOCK_NUM, anchorCardId, 10, 8);
    const r4Deck = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R4A_DECK_STAMP, anchorStamp, 12, 8);
    const r4Pre = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R4B_PRE_STAMP, [0.56, 0.58, 0.38, 0.18], 12, 8);
    const r6a = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R6A_TEXTBOX, anchorText, 10, 8);
    const r6b = roiDiffVote600(qFeat, aFeat, bFeat, ONEPIECE_ROIS.R6B_NAME_BAR, [0.18, 0.80, 0.64, 0.17], 10, 8);

    const dg200 = dgVote(qFeat.f200.dg, aFeat.f200.dg, bFeat.f200.dg, 30);
    const bhtDiff = subhashDist(qFeat.f200.bht, aFeat.f200.bht) - subhashDist(qFeat.f200.bht, bFeat.f200.bht);

    const regions = [
        { name: 'R1_artist',     res: r1,      gain: 1.35, minDiff: 0.20 },
        { name: 'R1_paintbrush', res: r1Brush, gain: 1.15, minDiff: 0.28 },
        { name: 'R2a_en_icon',   res: r2a,     gain: 1.50, minDiff: 0.22 },
        { name: 'R2_copyright',  res: r2Cpy,   gain: 1.10, minDiff: 0.20 },
        { name: 'R3b_block_num', res: r3b,     gain: 1.40, minDiff: 0.24 },
        { name: 'R4a_deck_stamp',res: r4Deck,  gain: 1.80, minDiff: 0.28 },
        { name: 'R4b_pre_stamp', res: r4Pre,   gain: 1.70, minDiff: 0.28 },
        { name: 'R6a_textbox',   res: r6a,     gain: 1.45, minDiff: 0.14 },
        { name: 'R6b_name_bar',  res: r6b,     gain: 1.20, minDiff: 0.16 },
    ];

    let totalScore = 0;
    let totalWeight = 0;
    const activeSignals = [];

    for (const reg of regions) {
        const ds = reg.res.diffStrength;
        if (ds >= reg.minDiff) {
            const w = (ds - reg.minDiff * 0.5) * reg.gain;
            totalScore += reg.res.vote * w;
            totalWeight += w;
            activeSignals.push(`${reg.name}:${reg.res.vote >= 0 ? '+' : ''}${reg.res.vote.toFixed(2)}(ds=${ds.toFixed(2)})`);
        }
    }

    if (dg200.d > 3.5 || dg200.meanDiff > 3.5) {
        const md = dg200.meanDiff ?? dg200.d ?? 0;
        if (md > 3.5) {
            const wDg = Math.min(1.5, (md - 2.0) * 0.12);
            totalScore += dg200.v3 * wDg;
            totalWeight += wDg;
            activeSignals.push(`dg200:${dg200.v3 >= 0 ? '+' : ''}${dg200.v3.toFixed(2)}(md=${md.toFixed(1)})`);
        }
    }
    if (aFeat.strokeR6a && bFeat.strokeR6a && qFeat.strokeR6a) {
        const abAnisoDiff = Math.abs(aFeat.strokeR6a.anisotropy - bFeat.strokeR6a.anisotropy);
        const abDensDiff = Math.abs(aFeat.strokeR6a.density - bFeat.strokeR6a.density);
        if (abDensDiff > 0.08 && abAnisoDiff > 0.08) {
            const dQA = Math.abs(qFeat.strokeR6a.anisotropy - aFeat.strokeR6a.anisotropy);
            const dQB = Math.abs(qFeat.strokeR6a.anisotropy - bFeat.strokeR6a.anisotropy);
            const sVote = (dQA - dQB) / (abAnisoDiff + 0.02);
            const wStroke = Math.min(0.6, abDensDiff * 4);
            totalScore += Math.max(-1, Math.min(1, sVote)) * wStroke;
            totalWeight += wStroke;
            activeSignals.push(`R6_stroke:${sVote >= 0 ? '+' : ''}${sVote.toFixed(2)}`);
        }
    }
    if (Math.abs(bhtDiff) > 0.03) {
        totalScore += bhtDiff * 0.8;
        totalWeight += 0.3;
    }

    const finalVote = totalWeight > 0 ? totalScore / totalWeight : 0;

    return {
        vote: finalVote,
        rawScore: totalScore,
        totalWeight,
        activeSignals,
        regions: { r1, r1Brush, r2a, r2Cpy, r3b, r4Deck, r4Pre, r6a, r6b, dg200, bhtDiff },
    };
}

/**
 * Rerank a candidate pool of same-card-number One Piece printings for query `qFeat`.
 * Returns the chosen candidate and diagnostic trace.
 */
export function resolveOnePieceReprint(qFeat, c0Ref, candidateRefs, getRefFeatFn, options = {}) {
    const threshold = options.threshold ?? 0.14;
    const c0Feat = getRefFeatFn(c0Ref);
    if (!c0Feat || !candidateRefs || candidateRefs.length <= 1) {
        return { chosen: c0Ref, switched: false, score: 0, signals: [] };
    }

    let bestRef = c0Ref;
    let bestVote = 0;
    let bestComp = null;

    for (const candRef of candidateRefs) {
        if (candRef === c0Ref) continue;
        const candFeat = getRefFeatFn(candRef);
        if (!candFeat) continue;
        const comp = compareOnePiecePair(qFeat, c0Feat, candFeat);
        if (comp.vote > bestVote && comp.totalWeight >= 0.10) {
            if (bestRef !== c0Ref) {
                const leaderFeat = getRefFeatFn(bestRef);
                const headToHead = compareOnePiecePair(qFeat, leaderFeat, candFeat);
                if (headToHead.vote > 0.05) {
                    bestRef = candRef;
                    bestVote = comp.vote;
                    bestComp = comp;
                }
            } else if (comp.vote >= threshold) {
                bestRef = candRef;
                bestVote = comp.vote;
                bestComp = comp;
            }
        }
    }

    return {
        chosen: bestRef,
        switched: bestRef !== c0Ref,
        score: bestVote,
        signals: bestComp ? bestComp.activeSignals : [],
        comp: bestComp,
    };
}

/**
 * Unified `resolveOnePieceVariant` entry point for `variants/index.js`.
 */
export function resolveOnePieceVariant({
    scanRgba,
    scanW = 200,
    scanH = 280,
    candidates = [],
    refImages = null,
    threshold = 0.18,
}) {
    if (!candidates.length || !scanRgba) return null;
    const top = candidates[0];
    const topBase = baseCardName(top.name);
    const samePool = candidates.filter((c) => baseCardName(c.name) === topBase);
    if (samePool.length < 2 || !refImages) return null;

    const getImg = (refKey) => {
        if (!refImages || !refKey) return null;
        const entry = refImages instanceof Map ? refImages.get(refKey) : refImages[refKey];
        if (!entry || !entry.rgba) return null;
        return { data: entry.rgba, width: entry.w || 200, height: entry.h || 280, channels: 4 };
    };

    const qFeat = extractOnePieceFeatures({ data: scanRgba, width: scanW, height: scanH, channels: 4 });
    const featMap = new Map();
    for (const c of samePool) {
        const img = getImg(c.ref);
        if (img) featMap.set(c.ref, extractOnePieceFeatures(img));
    }
    if (featMap.size < 2 || !featMap.has(top.ref)) return null;

    const res = resolveOnePieceReprint(
        qFeat,
        top.ref,
        samePool.map((c) => c.ref),
        (r) => featMap.get(r),
        { threshold },
    );
    if (!res.switched) return null;

    const target = samePool.find((c) => c.ref === res.chosen) || top;
    const targetVars = target.variants || [];
    const chosenVar = targetVars.find((v) => v.primary) || findVariant(targetVars, 'Normal') || targetVars[0] || null;
    return {
        game: GAME_KEY,
        ref: target.ref,
        variantId: chosenVar?.id ?? null,
        printing: chosenVar?.label ?? null,
        changedRef: target.ref !== top.ref,
        reason: `onepiece_reprint:${res.signals.slice(0, 2).join(',')}`,
        confidence: Math.min(0.95, 0.75 + Math.max(0, res.score)),
        metrics: { score: res.score, signals: res.signals },
    };
}
