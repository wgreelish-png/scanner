/**
 * quickscan.js - solo price-check live loop (never locks). The main thread only reads a 320 px frame, runs the
 * motion gate on its 160 px thumbnail, smooths and draws the outline and decides what the info panel shows;
 * detection, hashing and matching run in the backend (scan-backends.js: worker, or main-thread fallback).
 *
 * startQuickScan({video, overlay, backend, pack, onShow, onHide, onHint, onStats, reader?, frame?, now?}) -> stop()
 *   onShow(view)  view: {same, ref, siblings, confidence, match_pct, d, accepted, gap, frames, thumb, matches}
 *                 confidence: calibrated P(correct) 0..99 (show this); match_pct/d: raw bh1 distance (diagnostics)
 *                 same=true only refreshes confidence/match_pct/accepted of the card already on the panel
 *                 (ref/siblings unset, no new thumb — the phone keeps the previous view)
 *                 a new view (same=false) includes thumb (JPEG of the card, warped upright to the match) and matches
 *                 (up to 5 candidates, same order as a desktop upload)
 *                 accepted=false is a low-confidence guess: render it as a subtle "?" state, never as a result
 *   onHide()      accepted card not confirmed for HOLD_MS, or the guess lost its solid card
 *   onHint(text)  DOM hint ('' when the overlay or panel already says enough)
 *   onStats({kind, tickMs, scanMs, captureMs, frames, stage, tracked, ms})
 *   reader/frame/now: test seams (frame reader, frame scheduler, clock)
 *
 * The backend only ever returns quads that passed geom.gateQuad with edge support >= detect.SOLID (outline and
 * scan alike), and only matches when such a quad exists (scan.solid). Every quad goes through core/quadtrack.js
 * (one-euro smoothing, switch hysteresis, OUTLINE_HOLD_MS hold on misses) before it is drawn.
 *
 * Per video frame: gate.update(thumb).
 *   moving   -> fusion marked dirty, scan view dropped, a shown guess is hidden, outline requested
 *               (backend.quadEveryMs)
 *   stable   -> scan (one request in flight, scan or outline); the first scan after movement sends reset:true
 *   settling -> keeps scanning only while a solid scan quad is on screen, else outline requests
 *   While the scene is still, the last solid scan quad keeps feeding the tracker (the motion gate vouches that
 *   it has not moved). scan results: no solid card -> NO_CARD_MS backoff; not accepted -> next frame at once
 *   (worker fuses up to 3); accepted -> rescan every ACCEPTED_REPEAT_MS. Results of scans that overlapped
 *   movement are dropped.
 * Panel: an accepted card replaces anything not the same art and is held HOLD_MS after its last confirmation.
 * A non-accepted guess shows only while nothing accepted is held, after GUESS_CONFIRM consecutive scans agree on
 * its art, and only while a solid card is in view: hidden at once on movement or on a no-card scan, and after
 * GUESS_HOLD_MS without confirmation.
 */
import { createMotionGate, thumbFromImageData } from '../core/motion.js';
import { STATES } from '../core/overlay.js';
import { createQuadTracker } from '../core/quadtrack.js';
import { createFrameReader } from './video-frames.js';
import { rankTies } from '../core/setrank.js';
import { candidatesFrom, resolveScanCands, applyResolvedToView } from './desk-results.js';
import { quadJpeg } from './desk-images.js';

const SMALL = 320;
const THUMB = 160;
const NO_CARD_MS = 450;
const ACCEPTED_REPEAT_MS = 400;
const HOLD_MS = 2500;
const GUESS_HOLD_MS = 1200;
const GUESS_CONFIRM = 2;
const OUTLINE_HOLD_MS = 300;
const SCAN_FRESH_MS = 1500;
const GATE = { stableMs: 160, lowDiff: 4, highDiff: 9 };
const HINTS = { tilt: 'Tilt the card - glare', retry: 'Hold steady' };

// App diagnostic only: sample the already-read small frame on demand. This is
// whole-frame luma, not the detector's card-interior contrast. No pixels change.
function frameQuality(image) {
    const { data, width, height } = image || {};
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || !data || data.length < width * height * 4) return {};
    const sx = Math.max(1, Math.floor(width / 32)), sy = Math.max(1, Math.floor(height / 32));
    let sum = 0, square = 0, count = 0;
    for (let y = 0; y < height; y += sy) {
        for (let x = 0; x < width; x += sx) {
            const i = (y * width + x) * 4;
            const luma = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
            sum += luma; square += luma * luma; count++;
        }
    }
    const meanLuma = sum / count;
    return { meanLuma, lumaStd: Math.sqrt(Math.max(0, square / count - meanLuma * meanLuma)) };
}

function defaultFrame(video, fn) {
    if (typeof video.requestVideoFrameCallback === 'function') {
        const id = video.requestVideoFrameCallback(fn);
        return () => video.cancelVideoFrameCallback(id);
    }
    const id = requestAnimationFrame(fn);
    return () => cancelAnimationFrame(id);
}

export function startQuickScan({
    video, overlay, backend, pack, onShow, onHide, onHint, onStats, fetchDetails = null, resolveCandidates = true,
    reader = createFrameReader(), frame = defaultFrame, now = () => performance.now(),
}) {
    const gate = createMotionGate(GATE);
    const tracker = createQuadTracker({ holdMs: OUTLINE_HOLD_MS });
    let running = true;
    let cancel = null;
    let inFlight = false;
    let dirty = true;
    let nextScanAt = 0;
    let lastOutlineAt = -Infinity;
    let scanView = null;
    let shown = null;
    let pending = null;
    let drawKey = '';
    let hintText = null;
    let tickMs = 0;

    backend.reset();

    const sameArt = (a, b) => a === b || (pack.cl[a] >= 0 && pack.cl[a] === pack.cl[b]);

    function hide() {
        shown = null;
        onHide?.();
    }

    function tick() {
        if (!running) return;
        cancel = frame(video, tick);
        const t = now();
        const small = reader.read(video, SMALL);
        if (!small) return;
        const m = gate.update(thumbFromImageData(small, THUMB), undefined, t);
        if (m.state === 'moving') {
            dirty = true;
            scanView = null;
            pending = null;
            if (shown && !shown.accepted) hide();
        }
        if (scanView && t - scanView.at > SCAN_FRESH_MS) scanView = null;
        if (scanView) tracker.update(scanView.quad, t, scanView.w, scanView.h);
        if (!inFlight) {
            if (m.state === 'stable' || (m.state === 'settling' && !dirty && scanView)) {
                if (t >= nextScanAt) requestScan(small);
                else if (!scanView && t - lastOutlineAt >= backend.quadEveryMs) requestOutline(small, t);
            } else if (t - lastOutlineAt >= backend.quadEveryMs) {
                requestOutline(small, t);
            }
        }
        if (shown && t - shown.at > (shown.accepted ? HOLD_MS : GUESS_HOLD_MS)) hide();
        draw(t, m.state);
        tickMs = tickMs * 0.9 + (now() - t) * 0.1;
    }

    async function requestOutline(small, t) {
        inFlight = true;
        lastOutlineAt = t;
        try {
            const r = await backend.quad(small);
            if (running && r?.quad) tracker.update(r.quad, now(), r.w, r.h);
        } finally {
            inFlight = false;
        }
    }

    async function requestScan(small) {
        inFlight = true;
        const reset = dirty;
        dirty = false;
        let s = null;
        try {
            s = await backend.scan(video, { reset });
        } finally {
            inFlight = false;
        }
        if (!running) return;
        const t = now();
        if (!s) {
            nextScanAt = t + NO_CARD_MS;
            return;
        }
        onStats?.({ kind: backend.kind, tickMs, scanMs: s.ms.total, captureMs: s.ms.capture || 0, frames: s.frames, stage: s.stage || '', tracked: !!s.tracked, ms: s.ms,
            diagnostics: s.diagnostics, frameQuality: () => frameQuality(small) });
        if (dirty) return;
        if (!s.result || s.solid === false || !s.quad) {
            scanView = null;
            pending = null;
            if (shown && !shown.accepted) hide();
            nextScanAt = t + NO_CARD_MS;
            return;
        }
        const r = s.result;
        scanView = { quad: s.quad, w: s.w, h: s.h, accepted: r.accepted, hint: r.hint, i: r.best.i, at: t };
        tracker.update(s.quad, t, s.w, s.h);
        nextScanAt = t + (r.accepted ? ACCEPTED_REPEAT_MS : 0);
        const thumb = showsNew(r) ? quadJpeg(video, s.quad, s.w, s.h) : '';
        decide(r, s.frames, t, thumb);
    }

    // True when decide() will open a new card, not refresh one already on the panel.
    function showsNew(r) {
        const i = r.best.i;
        const same = !!shown && sameArt(shown.i, i);
        if (r.accepted) return !(same && shown.accepted);
        if (same || shown?.accepted) return false;
        const n = (pending && sameArt(pending.i, i) ? pending.n : 0) + 1;
        return n >= GUESS_CONFIRM;
    }

    // Printings the hash cannot separate are ordered by core/setrank.js (regular sets before promos / misc /
    // reprint lists); a 'likely' printing rank keeps its winner first.
    function view(r, frames, same, thumb) {
        const base = { confidence: r.confidence ?? r.best.confidence, match_pct: r.best.match_pct, d: r.best.d, accepted: r.accepted, gap: r.gap, frames };
        if (same) return { ...base, same: true };
        const p = r.best.printing;
        const pool = [...new Set([r.best.i, ...(p?.cands || []), ...r.best.siblings])];
        const order = p?.state === 'likely' ? [r.best.i, ...rankTies(pack, pool.slice(1))] : rankTies(pack, pool);
        const printing = p ? { state: p.state, margin: p.margin, cands: order.filter((j) => (p.cands || []).includes(j)).map((j) => pack.refs[j]) } : null;
        const cands = candidatesFrom(pack, r, 5);
        const matches = cands.slice(0, 5).map((c) => ({
            ref: c.ref,
            confidence: Math.max(0, Math.min(100, Math.round(Number(c.confidence) || 0))),
            d: Number.isFinite(c.d) ? Math.round(c.d * 1000) / 1000 : null,
        }));
        return { ...base, same: false, ref: pack.refs[order[0]], siblings: order.slice(1).map((j) => pack.refs[j]), printing, thumb: thumb || '', matches, cands };
    }

    function emitSame(v) {
        if (shown?.resolving && shown.pendingView) {
            Object.assign(shown.pendingView, {
                confidence: v.confidence,
                match_pct: v.match_pct,
                d: v.d,
                accepted: v.accepted,
                gap: v.gap,
                frames: v.frames,
            });
            return;
        }
        onShow?.(v);
    }

    function emitNew(r, frames, thumb, slot) {
        const v = view(r, frames, false, thumb);
        // App adaptation: local hash candidates are enough for manual confirmation.
        // Bypass image/CDN-assisted reranking when recognition must stay on-device.
        if (!resolveCandidates || (!thumb && !fetchDetails)) {
            onShow?.(v);
            return;
        }
        slot.resolving = true;
        slot.pendingView = v;
        const probe = { cands: v.cands || [], details: {}, shot: thumb || '', full: false, source: 'phone' };
        resolveScanCands(probe, { pack, fetchDetails, maxCands: 5 }).then(() => {
            if (!running || shown !== slot) return;
            applyResolvedToView(v, probe.cands);
            const winIdx = pack?.refs ? pack.refs.findIndex((tuple) => tuple[0] === v.ref?.[0]) : -1;
            if (winIdx >= 0) {
                slot.i = winIdx;
                if (scanView && sameArt(scanView.i, winIdx)) scanView.i = winIdx;
            }
            slot.resolving = false;
            slot.pendingView = null;
            onShow?.(v);
        }).catch(() => {
            if (!running || shown !== slot) return;
            slot.resolving = false;
            slot.pendingView = null;
            onShow?.(v);
        });
    }

    function decide(r, frames, t, thumb) {
        const i = r.best.i;
        const same = !!shown && sameArt(shown.i, i);
        if (r.accepted) {
            pending = null;
            if (same && shown.accepted) {
                shown.at = t;
                emitSame(view(r, frames, true));
            } else {
                shown = { i, accepted: true, at: t };
                emitNew(r, frames, thumb, shown);
            }
            return;
        }
        if (same) {
            shown.at = t;
            if (!shown.accepted) emitSame(view(r, frames, true));
            return;
        }
        if (shown?.accepted) return;
        pending = pending && sameArt(pending.i, i) ? { i, n: pending.n + 1 } : { i, n: 1 };
        if (pending.n < GUESS_CONFIRM) return;
        pending = null;
        shown = { i, accepted: false, at: t };
        emitNew(r, frames, thumb, shown);
    }

    // compact on-card chip: the info panel carries number, set, printings and confidence
    function label(i) {
        const [, name, , , , , , variants] = pack.refs[i];
        const primary = variants.find((v) => v.primary) || variants[0];
        return { name, price: primary?.nm };
    }

    function draw(t, motion) {
        const tq = tracker.current(t);
        let opts = null;
        let hint = 'hold a card in frame';
        if (tq) {
            opts = { quad: tq.quad, state: STATES.SEARCHING };
            hint = '';
            if (scanView && motion !== 'moving') {
                if (scanView.accepted && shown?.accepted && !shown.resolving && sameArt(shown.i, scanView.i)) {
                    opts = { quad: tq.quad, state: STATES.MATCHED, label: label(shown.i) };
                } else if (!scanView.accepted && !shown?.resolving) {
                    const text = HINTS[scanView.hint] || HINTS.retry;
                    const guess = !!shown && !shown.accepted && sameArt(shown.i, scanView.i);
                    opts = { quad: tq.quad, state: STATES.LOW, hint: text, badge: guess ? '?' : '' };
                    hint = shown ? text : '';
                }
            }
        }
        if (hint !== hintText) {
            hintText = hint;
            onHint?.(hint);
        }
        const key = opts ? `${tq.w}x${tq.h}|${opts.state}|${opts.hint || ''}|${opts.badge || ''}|${opts.label?.name || ''}|${opts.quad.flat().map(Math.round).join(',')}` : '';
        if (key === drawKey) return;
        drawKey = key;
        if (!opts) {
            overlay.clear();
            return;
        }
        overlay.setSource(tq.w, tq.h);
        overlay.draw(opts);
    }

    cancel = frame(video, tick);

    return () => {
        running = false;
        cancel?.();
        overlay.clear();
    };
}
