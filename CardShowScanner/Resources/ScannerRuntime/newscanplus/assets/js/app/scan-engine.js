/**
 * scan-engine.js - one quick-scan frame: detect -> warpCard(Pair) -> bh1 -> matchFrames, fused over up to
 * maxFuse frames of the same still card. Runs inside quickscan-worker.js and in the main-thread fallback.
 *
 * createScanEngine({maxFuse=3, maxCands=8, stillDrift=0.04, lsd='auto', track=true, stages=true}) -> Engine
 *   lsd/track/stages switch the speed paths below (tests compare against the plain pipeline with
 *   {lsd: true, track: false, stages: false}).
 *   setPack({n, lo, hi, cl})           refs are not needed here: results carry pack indices; cl may be 2n long
 *                                      (second half = printing groups, see pack.js)
 *   reset()                            drop fused frames and the tracking seed
 *   scanMat(mat, {reset, retainAcceptedBorder=false}) -> Scan
 *                                      an opt-in motion reset may retry accepted geometry for <=650ms;
 *                                      fusion is always cleared and a fresh same-reference match is required
 *                                      mat: CV_8UC4/CV_8UC3 frame (~1280 long side); not freed here
 *   scanRGBA({data, width, height}, {reset}) -> Scan    copied into one reused Mat
 *   quadRGBA({data, width, height}) -> {quad|null, w, h}  fastQuad on a small (~320 px) frame (gated + solid only)
 *   dispose()                          frees the reused Mats
 * Scan: {result: null | {accepted, gap, hint, glare, confidence, base,
 *          best: {i, d, match_pct, confidence, siblings: i[], printing}, top: [{i, d, match_pct}]},
 *        quad: card-order quad in frame px | null, solid, w, h, frames, tracked, stage: 'one'|'quick'|'full'|'',
 *        ms: {detect, lsd, warp, hash, match, total}}
 *   confidence: calibrated P(correct card) in % (localmatch.confidence); match_pct stays the raw bh1 distance.
 *   printing: {state: 'single'|'likely'|'ambiguous', margin, cands: i[]} (localmatch.js printing re-rank)
 *   base: rank of the detected quad whose warp won the vote (1 = the extrapolated outer edge when present)
 *   solid: a gated quad with edge support >= SOLID was found. Without it nothing is warped, hashed or matched
 *   (result and quad stay null), so no card can ever be reported off a non-card quad.
 * Detection escalates on the same frame only while nothing is accepted: after an accepted frame (no reset since)
 * the winning quad is re-fitted alone (trackCandidates, no frame-wide search); then detectCandidates with the
 * contour sources (lsd:'auto'); then the same detection plus LSD quads (det.withLSD()). Warps/hashes are shared
 * across these passes by quad, so an escalation only pays for new quads. Once a still card needed LSD, later
 * frames of the burst run the LSD-inclusive detection in one pass (a card that never matches costs no more
 * than the plain pipeline after its first frame).
 * Matching, current frame first, warping/hashing candidates lazily: the best candidate alone (accept only with
 * gap >= ONE_GAP), then the QUICK top candidates (best quad and the extrapolated outer edge / nested partner, both
 * orientations; normal accept rule). Accepted there = the result (frames = 1). Otherwise all fused frames are
 * matched: the current frame with every candidate (the first frame of a burst with at most maxCands, dropping
 * the weakest quad), older frames with their QUICK top candidates plus the quad that won their own vote.
 * Prefilter pools are cached per query (localmatch.js), so the later stages and fused frames reuse them.
 * Fusion restarts on reset, on a frame without a solid quad, and when no candidate quad of the new frame is
 * within stillDrift of the quad that produced the previous best.
 */
import { cv } from '../core/cv.js';
import { detectCandidates, fastQuad, trackCandidates } from '../core/detect.js';
import { warpCard, warpCardPair } from '../core/warp.js';
import { bh1 } from '../core/hash.js';
import { glareScore } from '../core/quality.js';
import { cornerDrift, polyArea, quadAspect } from '../core/geom.js';
import { GAP_MIN, queryFromHex, matchFrames } from '../core/localmatch.js';

const now = () => performance.now();
const QUICK = 4;
const ONE_GAP = GAP_MIN + 1.0;
const BORDER_RETRY_MS = 650;

const quadKey = (q) => q.map((p) => `${p[0].toFixed(2)},${p[1].toFixed(2)}`).join(';');

// Warps and hashes det.cands on demand, in order. The two orientation hypotheses of a quad are 180 deg apart
// (corners rolled by 2), so one perspective warp serves both; the twin waits unhashed until a stage needs it.
// seen: quadKey -> {query, glare} shared by every detection pass over the same frame (a re-run after adding LSD
// quads re-hashes nothing it already has, and the cached queries keep their prefilter pools).
function lazyHasher(mat, cands, ms, seen) {
    const queries = [];
    const spare = new Map();
    let glare = 0;
    return {
        queries,
        get glare() { return glare; },
        upTo(k) {
            k = Math.min(k, cands.length);
            while (queries.length < k) {
                const idx = queries.length;
                const c = cands[idx];
                const key = quadKey(c.quad);
                const hit = seen.get(key);
                if (hit && (idx !== 0 || hit.glare !== null)) {
                    queries.push(hit.query);
                    if (idx === 0) glare = hit.glare;
                    continue;
                }
                const a = now();
                let card = spare.get(idx);
                if (card) {
                    spare.delete(idx);
                } else {
                    const next = cands[idx + 1];
                    if (next && next.base === c.base) {
                        const [w0, w1] = warpCardPair(mat, c.quad);
                        card = w0;
                        spare.set(idx + 1, w1);
                    } else {
                        card = warpCard(mat, c.quad);
                    }
                }
                const b = now();
                try {
                    const query = queryFromHex(bh1(card));
                    const g = idx === 0 ? glareScore(card) : null;
                    queries.push(query);
                    if (idx === 0) glare = g;
                    seen.set(key, { query, glare: g });
                } finally {
                    card.delete();
                }
                ms.warp += b - a;
                ms.hash += now() - b;
            }
            return queries.slice(0, k);
        },
        dispose() {
            for (const m of spare.values()) m.delete();
            spare.clear();
        },
    };
}

export function createScanEngine({ maxFuse = 3, maxCands = 8, stillDrift = 0.04, lsd = 'auto', track = true, stages = true } = {}) {
    let pack = null;
    let allow = null;
    let history = [];
    let anchor = null;
    let seeds = null;
    let acceptedBorder = null;
    let lsdFirst = false;
    const mats = new Map();

    function reset() {
        history = [];
        anchor = null;
        seeds = null;
        acceptedBorder = null;
        lsdFirst = false;
    }

    // an older fused frame keeps its QUICK top candidates and the quad that won its own vote
    function trim(h) {
        const keep = h.cands.map((_, k) => k).filter((k) => k < QUICK || h.cands[k].base === h.won);
        if (keep.length === h.cands.length) return;
        h.queries = keep.map((k) => h.queries[k]);
        h.cands = keep.map((k) => h.cands[k]);
    }

    function rgbaMat(slot, img) {
        let m = mats.get(slot);
        if (!m || m.cols !== img.width || m.rows !== img.height) {
            if (m) m.delete();
            m = new cv.Mat(img.height, img.width, cv.CV_8UC4);
            mats.set(slot, m);
        }
        m.data.set(img.data);
        return m;
    }

    // Matches one detected frame (stages, then fusion with history) without committing it.
    function runFrame(mat, det, ms, seen) {
        const hasher = lazyHasher(mat, det.cands, ms, seen);
        try {
            const moved = anchor && !det.quads.some((q) => cornerDrift(anchor, q) <= stillDrift);
            const past = moved ? [] : history;
            const match = (frames) => {
                const a = now();
                const r = matchFrames(pack, frames, { glare: hasher.glare, allow });
                ms.match += now() - a;
                return r;
            };
            let res = null;
            let stage = '';
            if (stages) {
                for (const [k, gapMin] of [[1, ONE_GAP], [QUICK, GAP_MIN]]) {
                    if (det.cands.length <= k || stage) continue;
                    const qs = hasher.upTo(k);
                    if (!qs.length) break;
                    const r = match([qs]);
                    if (r.best && r.gap >= gapMin) {
                        res = r;
                        stage = k === 1 ? 'one' : 'quick';
                    }
                }
            }
            let cur;
            let used = null;
            let frames = 1;
            if (!stage) {
                const n = past.length ? det.cands.length : Math.min(det.cands.length, maxCands);
                const qs = hasher.upTo(n);
                if (!qs.length) return null;
                if (past.length) trim(past[past.length - 1]);
                cur = { queries: qs, cands: det.cands.slice(0, qs.length), quads: det.quads, won: -1 };
                const all = [...past, cur];
                res = match(all.map((h) => h.queries));
                used = res.best ? all[res.best.frame] : null;
                frames = all.length;
                stage = 'full';
            } else {
                const qs = hasher.queries.slice();
                cur = { queries: qs, cands: det.cands.slice(0, qs.length), quads: det.quads, won: -1 };
                used = cur;
            }
            return { res, cur, used, frames, stage, moved, glare: hasher.glare };
        } finally {
            hasher.dispose();
        }
    }

    function scanMat(mat, { reset: fresh = false, retainAcceptedBorder = false } = {}) {
        const t0 = now();
        // Carry coordinates only. The old frame hashes, fused votes, and match
        // result must never survive a motion reset or validate the new frame.
        let retry = null;
        if (fresh && retainAcceptedBorder === true && track && acceptedBorder) {
            const age = t0 - acceptedBorder.at;
            if (age >= 0 && age <= BORDER_RETRY_MS && acceptedBorder.w === mat.cols && acceptedBorder.h === mat.rows) retry = acceptedBorder;
        }
        if (fresh) reset();
        let borderRetry = false, borderRetained = false;
        const ms = { detect: 0, lsd: 0, warp: 0, hash: 0, match: 0, total: 0 };
        const out = { result: null, quad: null, solid: false, w: mat.cols, h: mat.rows, frames: 0, tracked: false, stage: '', ms };
        let selectedSupport = null;
        let selectedBase = null;
        // App adaptation: describe existing detections without changing candidate
        // generation, pixels, gates, hashes, ordering or acceptance decisions.
        const finish = () => {
            const q = out.quad || det?.quads?.[0];
            const diagnostics = {
                solid: out.solid, tracked: out.tracked, scanStage: out.stage || 'none',
                rawQuads: det?.raw || 0, rejectedQuads: det?.rejected || 0,
                candidateQuads: det?.quads?.length || 0,
                quadSource: out.quad ? 'selected' : q ? 'detected' : 'none',
            };
            if (borderRetry) { diagnostics.borderRetry = true; diagnostics.borderRetained = borderRetained; }
            if (selectedBase !== null) diagnostics.selectedBase = selectedBase;
            if (q) {
                diagnostics.quadAspect = quadAspect(q);
                diagnostics.quadArea = polyArea(q) / (mat.cols * mat.rows);
                const support = out.quad ? selectedSupport : det?.support?.[0];
                if (Number.isFinite(support)) diagnostics.quadSupport = support;
            }
            if (out.result) {
                diagnostics.matchDistance = out.result.best.d;
                diagnostics.matchGap = out.result.gap;
            }
            out.diagnostics = diagnostics;
            return out;
        };
        const seen = new Map();
        const accepted = (r) => !!(r && r.res.accepted);
        const detect = (fn) => {
            const a = now();
            const d = fn();
            ms.detect += now() - a;
            ms.lsd += (d && d.ms.lsd) || 0;
            return d;
        };
        // tracked seed -> full detection (contours) -> + LSD, each step only while there is no accepted match
        let det = null;
        let run = null;
        if (retry && pack) {
            borderRetry = true;
            det = detect(() => trackCandidates(mat, [retry.quad], { drift: stillDrift }));
            if (det?.present) run = runFrame(mat, det, ms, seen);
            borderRetained = !!(accepted(run) && run.used === run.cur && run.res.best?.i === retry.index);
            if (!borderRetained) { det = null; run = null; }
        } else {
            det = track && seeds && history.length ? detect(() => trackCandidates(mat, seeds, { drift: stillDrift })) : null;
            if (det && pack) run = runFrame(mat, det, ms, seen);
        }
        if (!accepted(run)) {
            det = detect(() => detectCandidates(mat, { maxCands, lsd: lsd === 'auto' && lsdFirst ? true : lsd }));
            run = det.present && pack ? runFrame(mat, det, ms, seen) : null;
            if (!accepted(run) && det.withLSD) {
                const more = detect(() => det.withLSD());
                if (more.present && pack) {
                    det = more;
                    run = runFrame(mat, det, ms, seen);
                }
            }
        }
        if (!det.present || !pack) {
            reset();
            ms.total = now() - t0;
            return finish();
        }
        out.solid = true;
        out.tracked = !!det.tracked;
        lsdFirst = !!det.lsd;
        if (!run) {
            reset();
            ms.total = now() - t0;
            return finish();
        }
        const { res, cur, used, frames, stage, moved, glare } = run;
        if (moved) history = [];
        if (history.length) trim(history[history.length - 1]);
        history.push(cur);
        if (history.length > maxFuse) history.shift();
        if (res.best) cur.won = used === cur ? cur.cands[res.best.cand].base : -1;
        seeds = null;
        acceptedBorder = null;
        if (res.best) {
            const cand = used.cands[res.best.cand];
            selectedBase = cand.base;
            selectedSupport = cand.support;
            anchor = used.quads[cand.base];
            if (res.accepted && used === cur) {
                seeds = [cand.quad];
                acceptedBorder = { quad: cand.quad.map((p) => [p[0], p[1]]), index: res.best.i, at: t0, w: mat.cols, h: mat.rows };
            }
            out.quad = cand.quad;
            out.result = {
                accepted: res.accepted,
                gap: res.gap,
                hint: res.hint,
                glare,
                confidence: res.confidence,
                base: cand.base,
                best: {
                    i: res.best.i, d: res.best.d, match_pct: res.best.match_pct, confidence: res.best.confidence,
                    siblings: res.best.siblings, printing: res.best.printing,
                },
                top: res.top,
            };
        }
        out.frames = frames;
        out.stage = stage;
        ms.total = now() - t0;
        return finish();
    }

    return {
        setPack(p) {
            pack = { n: p.n, lo: p.lo, hi: p.hi, cl: p.cl };
            allow = null;
            reset();
        },
        setAllow(mask) {
            allow = mask && pack && mask.length >= pack.n ? mask : null;
            acceptedBorder = null;
        },
        reset,
        scanMat,
        scanRGBA: (img, opts) => scanMat(rgbaMat('frame', img), opts),
        quadRGBA(img) {
            const quad = fastQuad(rgbaMat('small', img));
            return { quad, w: img.width, h: img.height };
        },
        dispose() {
            for (const m of mats.values()) m.delete();
            mats.clear();
            reset();
        },
    };
}
