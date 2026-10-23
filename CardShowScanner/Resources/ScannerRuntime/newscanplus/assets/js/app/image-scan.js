/**
 * image-scan.js - on-device identification of a still image (desktop uploads / watch folder). Same building
 * blocks as the live engine (detectCandidates -> warpCard -> bh1 -> matchFrames) but each detected quad is
 * matched on its own, so one scanner/flatbed image can yield several cards.
 *
 * createImageScanner({maxQuads=16}) -> Scanner
 *   setPack({n, lo, hi, cl})   clears the allow mask
 *   setAllow(Uint8Array(n) | null)   set lock / exclusions for matchFrames (null = whole pack)
 *   scan({data, width, height}, {maxCards=9}) -> ImageScan     RGBA image at any size (~1280 long side)
 *   dispose()
 * scanImagePasses(scanner, img, {first=1280, second=2048, maxCards}) -> ImageScan & {pass: 1|2, src: [w, h]}
 *   img: RGBA at its decoded size (the caller caps it at `second`). Pass 1 runs on an INTER_AREA copy at
 *   `first`; pass 2 runs on img itself, only when pass 1 accepted nothing and img is notably larger.
 * ImageScan: {w, h, quads (matched), rounds, cards: [Card], ms: {detect, hash, match, total}}
 *   Card: {quad (card order, image px), full (true = the whole image was the card), thumb: {data, width, height}
 *          (200x280 RGBA warp), result: {accepted, gap, hint, glare, query, best: {i, d, match_pct, siblings}, top}}
 *   query: the bh1 query ({lo, hi}) of the winning orientation, so later stages can score refs outside top.
 *   Quads are ranked accepted-first, then by bh1 d. Unaccepted quads below IMAGE_GATES.noisePct are dropped
 *   (blank scans, backgrounds: d near random). The top remaining quad is always reported (even when not
 *   accepted); further cards only when not overlapping an already reported card and either accepted, or - once
 *   >= 2 cards were accepted - a solid quad (edge support >= SOLID) with match_pct >= IMAGE_GATES.weakPct.
 *   Output is in reading order.
 * Candidate quads: detectCandidates' refined quads plus the full image ("card fills the scan") when the image
 * has a card-like aspect. Every quad is hashed in both orientation hypotheses (orientVariants). When a card
 * (not the full image) was accepted, accepted cards are painted out with the border colour and detection runs
 * again on the rest (up to IMAGE_GATES.maxRounds), because detectCandidates keeps only the strongest contours
 * per source.
 * One-off (maxCards 1, nothing accepted yet): core/image-rules.js oneOffQuads trims the side with the larger
 * leftover margin; when no trim accepts, padQuads grows the full frame (scan cut inside the card edge). The
 * one-off hash is kept only when it accepts with a better distance. Already-accepted scans are unchanged.
 * Thresholds live in image-rules.js.
 * Recrop (maxCards 1, best card still unaccepted on a detected quad with confidence under IMAGE_GATES.noiseConf,
 * i.e. headed for "No card found"): the quad's bounding box is scanned again as
 * its own image (one level, scan(img, {recrop: false})). Its card replaces the original only with a lower d, and
 * stays unaccepted with confidence and gap capped at the original's: the collector-number OCR decides, not the hash.
 */
import { cv } from '../core/cv.js';
import { detectCandidates, SOLID } from '../core/detect.js';
import { warpCard } from '../core/warp.js';
import { bh1 } from '../core/hash.js';
import { glareScore } from '../core/quality.js';
import { orientVariants, roll, polyArea } from '../core/geom.js';
import { queryFromHex, matchFrames, rivalConfidence } from '../core/localmatch.js';
import { IMAGE_GATES, oneOffQuads, oneOffHorizontalQuads, padQuadsAspectAware } from '../core/image-rules.js';

const now = () => performance.now();
const FULL_ASPECT = IMAGE_GATES.fullAspect;
const MAX_ROUNDS = IMAGE_GATES.maxRounds;
const WEAK_PCT = IMAGE_GATES.weakPct;
const NOISE_PCT = IMAGE_GATES.noisePct;
const NOISE_CONF = IMAGE_GATES.noiseConf;

export function createImageScanner({ maxQuads = 16 } = {}) {
    let pack = null;
    let allow = null;

    function evalVariantSet(mat, variants, ms) {
        const queries = [];
        let glare = 0;
        const a = now();
        variants.forEach((v, k) => {
            const card = warpCard(mat, v);
            try {
                queries.push(queryFromHex(bh1(card)));
                if (k === 0) glare = glareScore(card);
            } finally {
                card.delete();
            }
        });
        const b = now();
        const res = matchFrames(pack, [queries], { glare, allow });
        ms.hash += b - a;
        ms.match += now() - b;
        return { res, glare, variants, queries };
    }

    // Quads inside a card that was already accepted are the same card: skip them before hashing. A quad that
    // encloses an accepted one is still matched (the accepted one may be an inner frame, e.g. a borderless card's
    // art border, which cuts off the collector line); the better distance wins in take().
    function matchQuads(mat, quads, ms) {
        const entries = [];
        const done = [];
        for (const { q, full, support, portraitForce } of quads) {
            const area = polyArea(q);
            const encloses = done.some((d) => area > 1.1 * polyArea(d) && overlaps(d, q));
            if (!encloses && done.length && (done.some((d) => overlaps(d, q)) || !roomForMore(done.map((d) => ({ q: d })), mat.cols, mat.rows))) {
                ms.skipped = (ms.skipped || 0) + 1;
                continue;
            }
            const baseVars = portraitForce ? [q, roll(q, 2)] : orientVariants(q);
            const chosen = evalVariantSet(mat, baseVars, ms);
            if (!chosen.res.best) continue;
            entries.push({ q, full, support, baseVars, quad: chosen.variants[chosen.res.best.cand], query: chosen.queries[chosen.res.best.cand], res: chosen.res, glare: chosen.glare });
            if (chosen.res.accepted) done.push(q);
        }
        entries.sort((x, y) => (y.res.accepted - x.res.accepted) || x.res.best.d - y.res.best.d);

        // Only evaluate 90°/270° sideways fallback if 0°/180° failed to accept OR its best accepted quad is weak (d > 11.5)
        const best0 = entries[0];
        if (!best0 || !best0.res.accepted || best0.res.best.d > 11.5) {
            for (let idx = 0; idx < entries.length; idx++) {
                const e = entries[idx];
                if (idx >= 2 && !e.full) continue;
                const d0 = e.res.best.d;
                const c0 = e.baseVars[0];
                const sideVars = [roll(c0, 1), roll(c0, 3)];
                const side = evalVariantSet(mat, sideVars, ms);
                const d90 = side.res?.best?.d ?? Infinity;
                if (
                    side.res?.best &&
                    ((!e.res.accepted && side.res.accepted) ||
                        (e.res.accepted && d0 > 11.5 && side.res.accepted && d90 < d0 - 2.0) ||
                        (!e.res.accepted && !side.res.accepted && d90 < d0 - 1.0))
                ) {
                    e.quad = side.variants[side.res.best.cand];
                    e.query = side.queries[side.res.best.cand];
                    e.res = side.res;
                    e.glare = side.glare;
                }
            }
            entries.sort((x, y) => (y.res.accepted - x.res.accepted) || x.res.best.d - y.res.best.d);
        }
        return entries;
    }

    function detectQuads(mat, ms) {
        const a = now();
        const det = detectCandidates(mat, { maxCands: 2 * maxQuads });
        ms.detect += now() - a;
        return det.quads.slice(0, maxQuads).map((q, i) => ({ q, full: false, support: det.support?.[i] ?? 0 }));
    }

    function scan(img, { maxCards = 9, recrop = true } = {}) {
        const t0 = now();
        const ms = { detect: 0, hash: 0, match: 0, total: 0 };
        const W = img.width, H = img.height;
        const out = { w: W, h: H, quads: 0, rounds: 0, cards: [], ms };
        if (!pack) return out;
        const mat = new cv.Mat(H, W, cv.CV_8UC4);
        let work = null;
        try {
            mat.data.set(img.data);
            const quads = detectQuads(mat, ms);
            const aspect = Math.min(W, H) / Math.max(W, H);
            if (aspect >= FULL_ASPECT[0] && aspect <= FULL_ASPECT[1]) {
                quads.push({ q: [[0, 0], [W - 1, 0], [W - 1, H - 1], [0, H - 1]], full: true, support: 0 });
            }
            out.quads = quads.length;
            out.rounds = 1;

            const picked = [];
            const pool = [];
            const take = (entries, ok) => {
                let added = 0;
                for (const e of entries) {
                    if (picked.length >= maxCards) break;
                    if (picked.length && !ok(e)) continue;
                    if (e.full && picked.length) continue;
                    if (picked.some((p) => p.full || overlaps(p.q, e.q))) continue;
                    picked.push(e);
                    added++;
                }
                return added;
            };
            const accepted = (e) => e.res.accepted;
            const matched = matchQuads(mat, quads, ms);
            const first = matched.filter((e) => e.res.accepted || e.res.best.match_pct >= NOISE_PCT);
            pool.push(...first);
            take(first, accepted);

            // One card photo, nothing accepted: a scanner that clips one end and leaves the other long
            // misses the frame the hash was built on. Fixed trims on the larger margin side (then the
            // opposite side when an inner art/glare quad misled the margin check), each matched on its
            // own so one accepted trim cannot shadow a closer trim on the other side, kept only when
            // one accepts with a better distance than the quad we already have.
            // Still nothing: the scan may be cut inside the card edge, so grow the full frame instead. Each pad
            // is matched alone so the smaller one cannot shadow the other.
            const weakAccept = first.some(accepted) && (picked[0]?.res?.best?.d ?? Infinity) > 11.5;
            if (maxCards === 1 && (!first.some(accepted) || weakAccept)) {
                const bestOf = (list) => list.map((p) => matchQuads(mat, [p], ms).filter(accepted)[0]).filter(Boolean)
                    .sort((x, y) => x.res.best.d - y.res.best.d)[0];
                const alt = bestOf(oneOffQuads(W, H, matched))
                    || bestOf(oneOffHorizontalQuads(W, H, matched))
                    || (!first.some(accepted) ? bestOf(padQuadsAspectAware(W, H)) : null);
                const cur = picked[0];
                if (alt && (!cur || alt.res.best.d < cur.res.best.d - (cur.res.accepted ? 2.0 : 0.0))) {
                    picked.length = 0;
                    picked.push(alt);
                }
            }

            // Several cards: detection keeps only the strongest contours per source, so on a busy page some cards
            // are missed. Paint the accepted cards out and look again (accepted cards only) until nothing new.
            while (picked.length < maxCards && picked.some((p) => p.res.accepted && !p.full) && out.rounds < MAX_ROUNDS && roomForMore(picked, W, H)) {
                work ||= mat.clone();
                paintOut(work, picked.map((p) => p.q));
                const more = detectQuads(work, ms).filter((c) => !picked.some((p) => overlaps(p.q, c.q)));
                out.rounds++;
                out.quads += more.length;
                if (!more.length) break;
                const found = matchQuads(work, more, ms);
                pool.push(...found);
                if (!take(found, accepted)) break;
            }
            // On a page that clearly holds several cards, a solid card-shaped quad whose match is merely ambiguous
            // (same-art reprints, worn card) is still a card: report it as low confidence rather than drop it.
            if (picked.filter(accepted).length >= 2) {
                take(pool.slice().sort((x, y) => x.res.best.d - y.res.best.d), (e) => e.support >= SOLID && e.res.best.match_pct >= WEAK_PCT);
            }
            out.cards = readingOrder(picked).map((e) => ({
                quad: e.quad,
                full: e.full,
                thumb: thumbOf(mat, e.quad),
                result: {
                    accepted: e.res.accepted,
                    gap: e.res.gap,
                    confidence: e.res.confidence,
                    hint: e.res.hint,
                    glare: e.glare,
                    query: e.query ? { lo: e.query.lo.slice(), hi: e.query.hi.slice() } : null,
                    best: {
                        i: e.res.best.i,
                        d: e.res.best.d,
                        match_pct: e.res.best.match_pct,
                        confidence: e.res.best.confidence,
                        siblings: e.res.best.siblings,
                        printing: { state: e.res.best.printing?.state || 'single' },
                    },
                    top: e.res.top.map((t) => ({
                        ...t,
                        confidence: t.i === e.res.best.i ? e.res.confidence : (t.confidence ?? rivalConfidence(e.res.confidence, e.res.best.d, t.d)),
                    })),
                },
            }));
        } finally {
            mat.delete();
            work?.delete();
        }
        // One card, unaccepted on a detected quad and under the noise confidence, so it would be "No card found"
        // (e.g. the card's inner frame on a mat that matches its black border): rescan the quad's box as its own
        // upload so the full frame, trims and pads apply. A reviewable read is left alone: a lower d on the crop
        // can flip same-art printings (Weakness Unlimited -> Revised). Review only: the crop's card never accepts
        // and never gains confidence, so only the collector-number OCR can lift it.
        const c0 = out.cards[0];
        if (recrop && maxCards === 1 && c0 && !c0.result.accepted && !c0.full && (c0.result.confidence ?? 0) < NOISE_CONF) {
            const box = boxCrop(img, c0.quad);
            const sub = box && scan(box.img, { maxCards: 1, recrop: false });
            const c = sub?.cards[0];
            if (c && c.result.best.d < c0.result.best.d) out.cards[0] = reviewOnly(c, box, c0.result);
            if (sub) for (const k of ['detect', 'hash', 'match']) ms[k] += sub.ms[k];
        }
        ms.total = now() - t0;
        return out;
    }

    return {
        setPack(p) { pack = { n: p.n, lo: p.lo, hi: p.hi, cl: p.cl }; allow = null; },
        setAllow(mask) { allow = mask && pack && mask.length >= pack.n ? mask : null; },
        scan,
        dispose() { pack = null; },
    };
}

export function scanImagePasses(scanner, img, { first = 1280, second = 2048, maxCards = 9 } = {}) {
    const t0 = now();
    const long = Math.max(img.width, img.height);
    const small = long > first * 1.05 ? resizeRGBA(img, first / long) : img;
    let best = { ...scanner.scan(small, { maxCards }), pass: 1 };
    const f = img.width / small.width;
    if (f !== 1) for (const c of best.cards) c.quad = c.quad.map(([x, y]) => [x * f, y * f]);
    if (small !== img && long > first * 1.15 && !best.cards.some((c) => c.result.accepted)) {
        const big = { ...scanner.scan(img, { maxCards }), pass: 2 };
        const acc = (s) => s.cards.filter((c) => c.result.accepted).length;
        const d0 = (s) => (s.cards[0] ? s.cards[0].result.best.d : Infinity);
        if (acc(big) > acc(best) || (acc(big) === acc(best) && d0(big) < d0(best))) best = big;
    }
    best.ms = { ...best.ms, total: now() - t0 };
    return { ...best, w: img.width, h: img.height, src: [img.width, img.height] };
}

function resizeRGBA(img, s) {
    const src = new cv.Mat(img.height, img.width, cv.CV_8UC4);
    const dst = new cv.Mat();
    try {
        src.data.set(img.data);
        cv.resize(src, dst, new cv.Size(Math.round(img.width * s), Math.round(img.height * s)), 0, 0, cv.INTER_AREA);
        return { data: new Uint8ClampedArray(dst.data), width: dst.cols, height: dst.rows };
    } finally {
        src.delete();
        dst.delete();
    }
}

function snapRGBA(card) {
    const n = card.cols * card.rows, s = card.data, data = new Uint8ClampedArray(n * 4);
    for (let i = 0, j = 0; i < n; i++, j += 3) {
        data[i * 4] = s[j];
        data[i * 4 + 1] = s[j + 1];
        data[i * 4 + 2] = s[j + 2];
        data[i * 4 + 3] = 255;
    }
    return { data, width: card.cols, height: card.rows };
}

function thumbOf(mat, quad) {
    const card = warpCard(mat, quad);
    try {
        return snapRGBA(card);
    } finally {
        card.delete();
    }
}

// Fill each quad (grown 4% around its centre) with the median colour of the image border.
function paintOut(mat, quads) {
    const W = mat.cols, H = mat.rows, d = mat.data;
    const samples = [[], [], []];
    const step = Math.max(1, Math.floor((W + H) / 400));
    const add = (x, y) => { const o = (y * W + x) * 4; for (let c = 0; c < 3; c++) samples[c].push(d[o + c]); };
    for (let x = 0; x < W; x += step) { add(x, 2); add(x, H - 3); }
    for (let y = 0; y < H; y += step) { add(2, y); add(W - 3, y); }
    const [b0, b1, b2] = samples.map((s) => s.sort((a, b) => a - b)[s.length >> 1]);
    for (const q0 of quads) {
        const [cx, cy] = centroid(q0);
        const q = q0.map(([x, y]) => [cx + (x - cx) * 1.04, cy + (y - cy) * 1.04]);
        const ys = q.map((p) => p[1]);
        const y0 = Math.max(0, Math.ceil(Math.min(...ys))), y1 = Math.min(H - 1, Math.floor(Math.max(...ys)));
        for (let y = y0; y <= y1; y++) {
            let xl = Infinity, xr = -Infinity;
            for (let i = 0, j = 3; i < 4; j = i++) {
                const [xi, yi] = q[i], [xj, yj] = q[j];
                if ((yi > y) === (yj > y)) continue;
                const x = xi + ((y - yi) * (xj - xi)) / (yj - yi);
                if (x < xl) xl = x;
                if (x > xr) xr = x;
            }
            if (xl > xr) continue;
            const a = Math.max(0, Math.ceil(xl)), b = Math.min(W - 1, Math.floor(xr));
            for (let x = a, o = (y * W + a) * 4; x <= b; x++, o += 4) {
                d[o] = b0; d[o + 1] = b1; d[o + 2] = b2;
            }
        }
    }
}

// Bounding box of a quad as its own RGBA image, with the offset back to the source.
function boxCrop(img, quad) {
    const [bx0, by0, bx1, by1] = bbox(quad);
    const x0 = Math.max(0, Math.floor(bx0)), y0 = Math.max(0, Math.floor(by0));
    const x1 = Math.min(img.width, Math.ceil(bx1)), y1 = Math.min(img.height, Math.ceil(by1));
    const w = x1 - x0, h = y1 - y0;
    if (w < 32 || h < 32 || (w === img.width && h === img.height)) return null;
    const data = new Uint8ClampedArray(w * h * 4);
    for (let y = 0; y < h; y++) data.set(img.data.subarray(((y + y0) * img.width + x0) * 4, ((y + y0) * img.width + x1) * 4), y * w * 4);
    return { img: { data, width: w, height: h }, x: x0, y: y0 };
}

// The crop's card in source pixels, capped at the original card's acceptance, gap and confidence.
function reviewOnly(card, box, was) {
    const cap = Math.min(was.confidence ?? 0, card.result.confidence ?? 0);
    const r = card.result;
    return {
        ...card,
        full: false,
        quad: card.quad.map(([x, y]) => [x + box.x, y + box.y]),
        result: {
            ...r,
            accepted: false,
            gap: Math.min(r.gap, was.gap),
            confidence: cap,
            hint: r.hint || was.hint || 'retry',
            best: { ...r.best, confidence: cap },
            top: r.top.map((t) => ({ ...t, confidence: Math.min(t.confidence ?? 0, cap) })),
        },
    };
}

// Another card fits only if the image area not yet covered could hold one as large as the smallest found.
function roomForMore(picked, W, H) {
    const areas = picked.filter((p) => !p.full).map((p) => polyArea(p.q));
    if (!areas.length) return false;
    const used = areas.reduce((s, a) => s + a, 0);
    return W * H - used >= 0.9 * Math.min(...areas);
}

const centroid = (q) => [(q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4, (q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4];

function inside(q, [x, y]) {
    let hit = false;
    for (let i = 0, j = 3; i < 4; j = i++) {
        const [xi, yi] = q[i], [xj, yj] = q[j];
        if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
    }
    return hit;
}

function bbox(q) {
    const xs = q.map((p) => p[0]), ys = q.map((p) => p[1]);
    return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
}

// Same card (duplicate/inner quad) or containing quad: either centroid lies inside the other, or the boxes mostly coincide.
function overlaps(a, b) {
    if (inside(a, centroid(b)) || inside(b, centroid(a))) return true;
    const A = bbox(a), B = bbox(b);
    const iw = Math.min(A[2], B[2]) - Math.max(A[0], B[0]);
    const ih = Math.min(A[3], B[3]) - Math.max(A[1], B[1]);
    if (iw <= 0 || ih <= 0) return false;
    return (iw * ih) / Math.min(polyArea(a), polyArea(b)) > 0.5;
}

function readingOrder(entries) {
    if (entries.length < 2) return entries;
    const hs = entries.map((e) => bbox(e.q)).map((b) => b[3] - b[1]).sort((x, y) => x - y);
    const band = hs[hs.length >> 1] * 0.5;
    return entries
        .map((e) => ({ e, c: centroid(e.q) }))
        .sort((x, y) => (Math.abs(x.c[1] - y.c[1]) > band ? x.c[1] - y.c[1] : x.c[0] - y.c[0]))
        .map((x) => x.e);
}
