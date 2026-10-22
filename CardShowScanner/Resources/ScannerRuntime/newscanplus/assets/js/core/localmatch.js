/**
 * localmatch.js - on-device bh1 matching against a loaded pack (same scoring as the service matcher).
 *
 * Exports
 *   GAP_MIN = 1.5, PRINT_WIN = 1.5, PRINT_MARGIN = 1.0
 *   queryFromHex(bh1hex) -> {lo: Uint32Array(36), hi: Uint8Array(36)}
 *   confidence(d, gap) -> 0..97   calibrated P(card identity correct) in % (see CONF_W)
 *   refDistance(pack, query, i) -> d of one pack ref against one query (no prefilter)
 *   matchFrames(pack, frames, {k=5, prefilter=400, glare=0, allow=null}) -> Result
 *     allow: optional Uint8Array(n); refs with allow[i] = 0 (set lock / exclusions) never enter the pool, so they
 *     can neither win nor count as the gap rival. Same-art siblings outside it are left out of the printing rank.
 *     frames: Array<Array<query>> (candidates per frame). Per frame each ref takes its best candidate;
 *     frames are fused by mean. Gray-only prefilter per candidate, then full d on the union.
 *     Result: {accepted, gap, hint, confidence, best: {i, d, cand, frame, match_pct, confidence, siblings: i[], printing},
 *              top: [{i, d, match_pct, confidence}]}
 *     top[].confidence: the winner's confidence for its own art cluster, else scaled by exp(-(d - d1) / RIVAL_TAU)
 *     so a candidate 1.5 bits worse (the accept gap) shows ~8% of the winner's value.
 *     The prefilter pool is cached on each query object (per pack), so re-matching a query in later fused
 *     frames or a wider candidate stage costs only the full-d pass. Queries must not be mutated.
 * d = (g + 0.5a + 0.5b) / 2 in mean bits per block (0..36). Siblings (same art cluster) and refs of the
 * winner's printing group (same base name) never count against the gap: the gap accepts the card, and which
 * printing it is goes to the printing rank below (ambiguous -> the picker).
 * match_pct = 100(1 - d/18) is the raw distance on a 0..100 scale (real correct photos sit at 40-70%); show
 * confidence to users, keep match_pct for diagnostics.
 *
 * Printing re-rank. Candidates = the bh1 winner, its art-cluster siblings, and refs of its printing group
 * (same base name; pack.cl[n + i], see pack.js) whose fused d is within PRINT_WIN of the winner. They are ranked
 * by fused gray-channel bh1 (mean bits per gray block). best.printing = {state, margin, cands: i[]}:
 *   'single'    no other printing in play
 *   'likely'    runner-up is >= PRINT_MARGIN worse: best.i = the ranked winner. A result accepted only through
 *               same-name refs (the art gap alone is under GAP_MIN) is 'ambiguous' instead.
 *   'ambiguous' best.i stays the bh1 winner; the UI should offer cands as "printing: pick"
 * cands is best-first and includes best.i; siblings = cands without best.i (max 6). The gap rule is unchanged.
 */

// bh1-only equivalent of the service's fused gap 2.0 (phase-3 calibration: <= 0.6% wrong accepts in-set, 1.3% category-wide)
export const GAP_MIN = 1.5;
// Real MTG pack captures (lab reports/sibrank.md): gray-bh1 margin >= 1.0 names the right printing 85-91% of the
// time on 4-13% of scans; below it the printings are a coin toss (54% vs 38% chance), so they are left to the user.
export const PRINT_WIN = 1.5;
export const PRINT_MARGIN = 1.0;
const PRINT_MAX = 16;
const RANDOM_D = 18;
// Logistic P(correct | gap, d), g = min(gap, 6): fit on 12,037 real phase-3 captures (pack warps, raw photos,
// glare singles/bursts, corpus) re-scored bh1-only against the whole game pack; same-art siblings count as
// correct (lab scripts/quickconf, reports/quickconf.md). A frames term was left out: its only evidence is one
// glare-burst set with no fused failures, and it would push 3-frame guesses with tiny gaps above 95%.
// CONF_MAX: raw phone-like captures (MTG + Pokemon) top out at 96-97% observed even at large gaps.
const CONF_W = [-2.1722, -0.9135, 5.1298, -0.0537];
const CONF_GAP_CAP = 6;
const CONF_MAX = 97;
const RIVAL_TAU = 0.6;

export function rivalConfidence(bestConf, dBest, d) {
    return Math.max(0, Math.round(bestConf * Math.exp(-Math.max(0, d - dBest) / RIVAL_TAU)));
}

export function confidence(d, gap) {
    const g = Math.min(Math.max(gap, 0), CONF_GAP_CAP);
    const z = CONF_W[0] + CONF_W[1] * g + CONF_W[2] * Math.sqrt(g) + CONF_W[3] * d;
    return Math.min(CONF_MAX, Math.round(100 / (1 + Math.exp(-z))));
}

function popcnt(x) {
    x -= (x >>> 1) & 0x55555555;
    x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
    return (((x + (x >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24;
}

const NIB = new Uint8Array([0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4]);
const POP16 = new Uint8Array(65536);
for (let i = 1; i < 65536; i++) POP16[i] = POP16[i >> 1] + (i & 1);
const GW = 14;
const GRAY_MAX = 12 * 36;

// Gray blocks of every ref packed contiguously for the prefilter scan: 12 low words, then the 12 high nibbles
// in two words (6 each). Built once per pack (keyed on pack.lo).
const grayCache = new WeakMap();

function grayWords(lo, hi, o, out, at) {
    for (let b = 0; b < 12; b++) out[at + b] = lo[o + b];
    let w0 = 0, w1 = 0;
    for (let b = 0; b < 6; b++) {
        w0 |= hi[o + b] << (4 * b);
        w1 |= hi[o + 6 + b] << (4 * b);
    }
    out[at + 12] = w0 >>> 0;
    out[at + 13] = w1 >>> 0;
}

function grayPack(pack) {
    let g = grayCache.get(pack.lo);
    if (!g) {
        g = new Uint32Array(pack.n * GW);
        for (let i = 0; i < pack.n; i++) grayWords(pack.lo, pack.hi, i * 36, g, i * GW);
        grayCache.set(pack.lo, g);
    }
    return g;
}

let scratchDist = new Uint16Array(0);
let scratchMark = new Uint8Array(0);
const hist = new Uint32Array(GRAY_MAX + 1);

export function queryFromHex(hex) {
    const lo = new Uint32Array(36);
    const hi = new Uint8Array(36);
    for (let b = 0; b < 36; b++) {
        const s = hex.slice(b * 9, b * 9 + 9);
        hi[b] = parseInt(s[0], 16);
        lo[b] = parseInt(s.slice(1), 16) >>> 0;
    }
    return { lo, hi };
}

function grayDist(pack, q, i) {
    const o = i * 36;
    let s = 0;
    for (let b = 0; b < 12; b++) s += popcnt(pack.lo[o + b] ^ q.lo[b]) + NIB[pack.hi[o + b] ^ q.hi[b]];
    return s;
}

/** Full bh1 distance d of pack ref i to query q, as matchFrames scores it (one frame, one candidate). */
export function refDistance(pack, q, i) {
    return fullDist(pack, q, i);
}

function fullDist(pack, q, i) {
    const lo = pack.lo, hi = pack.hi, ql = q.lo, qh = q.hi;
    const o = i * 36;
    let g = 0, a = 0, c = 0;
    for (let b = 0; b < 12; b++) {
        const x = lo[o + b] ^ ql[b], y = lo[o + b + 12] ^ ql[b + 12], z = lo[o + b + 24] ^ ql[b + 24];
        g += POP16[x & 0xffff] + POP16[x >>> 16] + NIB[hi[o + b] ^ qh[b]];
        a += POP16[y & 0xffff] + POP16[y >>> 16] + NIB[hi[o + b + 12] ^ qh[b + 12]];
        c += POP16[z & 0xffff] + POP16[z >>> 16] + NIB[hi[o + b + 24] ^ qh[b + 24]];
    }
    return (g / 12 + 0.5 * (a / 12) + 0.5 * (c / 12)) / 2;
}

// The m refs with the lowest gray distance (ties at the cut-off: lowest index first). One linear pass with a
// distance histogram instead of a running top-m list.
function topByGray(pack, q, m, allow = null) {
    const n = pack.n;
    if (allow) {
        let allowed = 0;
        for (let i = 0; i < n; i++) if (allow[i]) allowed++;
        if (allowed <= m) {
            const out = new Int32Array(allowed);
            for (let i = 0, k = 0; i < n; i++) if (allow[i]) out[k++] = i;
            return out;
        }
    } else if (n <= m) return Int32Array.from({ length: n }, (_, i) => i);
    const G = grayPack(pack);
    const qw = new Uint32Array(GW);
    grayWords(q.lo, q.hi, 0, qw, 0);
    if (scratchDist.length < n) scratchDist = new Uint16Array(n);
    const dist = scratchDist;
    hist.fill(0);
    const q0 = qw[0], q1 = qw[1], q2 = qw[2], q3 = qw[3], q4 = qw[4], q5 = qw[5], q6 = qw[6];
    const q7 = qw[7], q8 = qw[8], q9 = qw[9], q10 = qw[10], q11 = qw[11], q12 = qw[12], q13 = qw[13];
    const P = POP16;
    for (let i = 0, o = 0; i < n; i++, o += GW) {
        let x, s;
        x = G[o] ^ q0; s = P[x & 0xffff] + P[x >>> 16];
        x = G[o + 1] ^ q1; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 2] ^ q2; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 3] ^ q3; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 4] ^ q4; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 5] ^ q5; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 6] ^ q6; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 7] ^ q7; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 8] ^ q8; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 9] ^ q9; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 10] ^ q10; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 11] ^ q11; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 12] ^ q12; s += P[x & 0xffff] + P[x >>> 16];
        x = G[o + 13] ^ q13; s += P[x & 0xffff] + P[x >>> 16];
        if (allow && !allow[i]) {
            dist[i] = 0xffff;
            continue;
        }
        dist[i] = s;
        hist[s]++;
    }
    let cut = 0, below = 0;
    while (below + hist[cut] < m) below += hist[cut++];
    let atCut = m - below;
    const out = new Int32Array(m);
    for (let i = 0, k = 0; k < m; i++) {
        const d = dist[i];
        if (d < cut) out[k++] = i;
        else if (d === cut && atCut > 0) { out[k++] = i; atCut--; }
    }
    return out;
}

function poolOf(pack, q, m, allow) {
    const c = q.pool;
    if (c && c.lo === pack.lo && c.m === m && c.allow === allow) return c.ids;
    const ids = topByGray(pack, q, m, allow);
    Object.defineProperty(q, 'pool', { value: { lo: pack.lo, m, allow, ids }, writable: true, configurable: true, enumerable: false });
    return ids;
}

const pct = (d) => Math.max(0, Math.min(100, 100 * (1 - d / RANDOM_D)));

function printingCands(pack, order, top1, allow) {
    const { n, cl } = pack;
    const cluster = cl[top1.i];
    const group = cl.length >= 2 * n ? cl[n + top1.i] : -1;
    const out = [top1.i];
    const seen = new Set(out);
    for (const o of order) {
        if (o.d - top1.d > PRINT_WIN || out.length >= PRINT_MAX) break;
        if (seen.has(o.i)) continue;
        if ((cluster >= 0 && cl[o.i] === cluster) || (group >= 0 && cl[n + o.i] === group)) {
            out.push(o.i);
            seen.add(o.i);
        }
    }
    if (cluster >= 0) {
        for (let i = 0; i < n && out.length < PRINT_MAX; i++) {
            if (cl[i] === cluster && !seen.has(i) && (!allow || allow[i])) {
                out.push(i);
                seen.add(i);
            }
        }
    }
    return out;
}

function rankPrintings(pack, frames, cands) {
    if (cands.length < 2) return { state: 'single', margin: 0, cands };
    const score = cands.map((i) => {
        let s = 0;
        for (const qs of frames) {
            let b = Infinity;
            for (const q of qs) b = Math.min(b, grayDist(pack, q, i));
            s += b;
        }
        return { i, g: s / frames.length / 12 };
    }).sort((x, y) => x.g - y.g);
    const margin = score[1].g - score[0].g;
    return { state: margin >= PRINT_MARGIN ? 'likely' : 'ambiguous', margin, cands: score.map((s) => s.i) };
}

function fusedD(pack, frames, i) {
    let s = 0;
    for (const qs of frames) {
        let b = Infinity;
        for (const q of qs) b = Math.min(b, fullDist(pack, q, i));
        s += b;
    }
    return s / frames.length;
}

export function matchFrames(pack, frames, { k = 5, prefilter = 400, glare = 0, allow = null } = {}) {
    if (allow && allow.length < pack.n) allow = null;
    if (scratchMark.length < pack.n) scratchMark = new Uint8Array(pack.n);
    const mark = scratchMark;
    const ids = [];
    for (const cands of frames) {
        for (const q of cands) {
            for (const i of poolOf(pack, q, prefilter, allow)) {
                if (!mark[i]) { mark[i] = 1; ids.push(i); }
            }
        }
    }
    for (const i of ids) mark[i] = 0;

    const sum = new Float64Array(ids.length);
    const whereD = new Float64Array(ids.length).fill(Infinity);
    const whereC = new Int32Array(ids.length);
    const whereF = new Int32Array(ids.length);
    frames.forEach((cands, f) => {
        for (let j = 0; j < ids.length; j++) {
            const i = ids[j];
            let bestD = Infinity, bestC = 0;
            for (let c = 0; c < cands.length; c++) {
                const d = fullDist(pack, cands[c], i);
                if (d < bestD) { bestD = d; bestC = c; }
            }
            sum[j] += bestD;
            if (bestD < whereD[j]) { whereD[j] = bestD; whereC[j] = bestC; whereF[j] = f; }
        }
    });

    const order = ids.map((i, j) => ({ i, d: sum[j] / frames.length, j })).sort((x, y) => x.d - y.d);
    if (!order.length) return { accepted: false, gap: 0, hint: 'retry', confidence: 0, best: null, top: [] };

    const top1 = order[0];
    const cluster = pack.cl[top1.i];
    const group = pack.cl.length >= 2 * pack.n ? pack.cl[pack.n + top1.i] : -1;
    const isArt = (i) => cluster >= 0 && pack.cl[i] === cluster;
    const isSib = (i) => isArt(i) || (group >= 0 && pack.cl[pack.n + i] === group);
    const rival = order.find((o) => o.i !== top1.i && !isSib(o.i));
    const gap = rival ? rival.d - top1.d : RANDOM_D;
    const accepted = gap >= GAP_MIN;
    const artRival = order.find((o) => o.i !== top1.i && !isArt(o.i));
    const artGap = artRival ? artRival.d - top1.d : RANDOM_D;

    const ranked = rankPrintings(pack, frames, printingCands(pack, order, top1, allow));
    // Accepted only because the near rivals share the card's name: the gray margin names the wrong printing
    // ~12% of the time on real MTG warps (vs ~3% when the art gap also clears), so leave it to the picker.
    if (ranked.state === 'likely' && accepted && artGap < GAP_MIN) ranked.state = 'ambiguous';
    if (ranked.state !== 'likely' && ranked.cands[0] !== top1.i) {
        ranked.cands = [top1.i, ...ranked.cands.filter((i) => i !== top1.i)];
    }
    const bestI = ranked.cands[0];
    const bestD = bestI === top1.i ? top1.d : fusedD(pack, frames, bestI);
    const at = order.find((o) => o.i === bestI) || top1;
    const conf = confidence(top1.d, gap);

    return {
        accepted,
        gap,
        hint: accepted ? null : (glare > 0.2 ? 'tilt' : 'retry'),
        confidence: conf,
        best: {
            i: bestI,
            d: bestD,
            match_pct: pct(bestD),
            confidence: conf,
            cand: whereC[at.j],
            frame: whereF[at.j],
            siblings: ranked.cands.slice(1, 7),
            printing: ranked,
        },
        top: order.slice(0, k).map((o) => ({
            i: o.i, d: o.d, match_pct: pct(o.d), confidence: isSib(o.i) || o.i === top1.i ? conf : rivalConfidence(conf, top1.d, o.d),
        })),
    };
}
