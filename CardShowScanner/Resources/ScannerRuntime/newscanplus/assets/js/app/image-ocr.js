/**
 * image-ocr.js - desktop-only collector-corner tie-break on still-image scans (worker or main thread).
 *
 * refineWithOcr(out, image, meta) -> Promise<out>   mutates out.cards[].result in place
 *   out:   image-scan.js scanImagePasses result; card.quad must be in `image` pixels.
 *   image: {data RGBA, width, height} - the same image the quads refer to.
 *   meta:  {game, refs: string[], numbers: string[], abbr: string[], names: Int32Array} indexed like the pack.
 *          names = card-name id (desk-results baseName), so every printing of the card shares one id.
 * Candidates: hash top + same-art siblings + every printing of the winner's card name. A printing outside the
 * hash top (e.g. no catalog image, so its hash is poor) can still be decided by its number and set code.
 * Runs only for cards whose candidates carry different printed numbers.
 * OCR re-orders candidates and may move best.i among same-art siblings; it never sets `accepted`
 * (tiebreak.js applyBoosts keeps accepted/gap from the hash). Failures leave the card unchanged.
 * MTG cards where that OCR read nothing at all get one additive attempt: the pre-M15
 * copyright-line strip (legacyStripTarget), gated by gatedOcrTarget exactly like phone ingest.
 *
 * refinePhoneRowWithOcr(row, pack, meta) -> Promise<void>   desktop phone-ingest only (never the
 *   live phone loop, never uploads): collector-number preselect on the phone's warped photo, gated
 *   by phoneOcrTarget so it can only reorder toward a globally-unique printed number.
 * phoneOcrTarget(row, number, meta) -> ref|null   pure decision core of the above.
 */
import { cv, cvReady, pickSrc } from '../core/cv.js';
import { tieBreak, applyBoosts, shouldTieBreak, warpOcrCard, OCR_W, OCR_H, OCR_DELTA } from '../core/ocr/tiebreak.js';
import { numbersMatch, canonNumber, normNumber, parseNumber, cropPixels } from '../core/ocr/layouts.js';
import { recognizeCorner } from '../core/ocr/engine.js';
import { setPenalty } from '../core/setrank.js';
import { refDistance, queryFromHex, matchFrames } from '../core/localmatch.js';
import { IMAGE_GATES } from '../core/image-rules.js';
import { warpCard } from '../core/warp.js';
import { bh1 } from '../core/hash.js';

function baseName(name) {
    return String(name || '')
        .replace(/\s+-\s+\d+\/\d+\b/g, '')
        .replace(/\s*\[[^\]]*\]/g, '')
        .replace(/\s*\([^)]*\)/g, '')
        .replace(/\s+-\s+(?:\d+\/\d+|"[^"]*")$/, '')
        .trim()
        .toLowerCase();
}

export async function refineWithOcr(out, image, meta, pack = null) {
    if (!out || !meta?.refs?.length || !image?.data) return out;
    let rescuedEmpty = false;
    if (!out.cards?.length && pack?.lo && image.width > 1 && image.height > 1) {
        const aspect = Math.min(image.width, image.height) / Math.max(image.width, image.height);
        const [lo, hi] = IMAGE_GATES.fullAspect;
        if (aspect >= lo && aspect <= hi) {
            const m0 = cv.matFromImageData(image);
            try {
                const fullQ = [[0, 0], [image.width - 1, 0], [image.width - 1, image.height - 1], [0, image.height - 1]];
                const w0 = warpCard(m0, fullQ);
                let q0 = null;
                try { q0 = queryFromHex(bh1(w0)); } finally { w0.delete(); }
                const res0 = matchFrames(pack, [[q0]], {});
                if (res0?.best) {
                    rescuedEmpty = true;
                    out.cards = [{
                        quad: fullQ,
                        full: true,
                        result: {
                            accepted: false,
                            gap: res0.gap,
                            confidence: res0.confidence,
                            query: q0,
                            best: { i: res0.best.i, d: res0.best.d, match_pct: res0.best.match_pct, confidence: res0.best.confidence, siblings: res0.best.siblings, printing: { state: 'single' } },
                            top: res0.top,
                        },
                    }];
                }
            } catch { /* ignore */ } finally {
                m0.delete();
            }
        }
    }
    if (!out.cards?.length) return out;
    const jobs = out.cards
        .map((card) => ({ card, cands: candidatesOf(card.result, meta) }))
        .filter((j) => j.card.quad && shouldTieBreak(j.cands));
    if (!jobs.length) {
        if (rescuedEmpty) out.cards = [];
        return out;
    }

    const mat = cv.matFromImageData(image);
    try {
        for (const { card, cands } of jobs) {
            let warp = null;
            try {
                warp = warpOcrCard(mat, card.quad);
                let tb = await tieBreak({ card: warp, game: meta.game, cands });
                // Additive only, MTG still-image scans where the corner OCR read nothing at all:
                // the pre-M15 copyright-line number (legacy strip) may still decide, under the
                // same improvement-only gate as phone ingest (gatedOcrTarget). Existing reads,
                // decided or not, are never re-litigated here.
                if (!tb.number && meta.game === 'tcgp:1') {
                    const legacy = await legacyStripTarget(card.result, warp, meta);
                    if (legacy) tb = legacy;
                }
                // Retro-frame collector numbers sit mid copyright line ("20/38"), outside the
                // bottom-left corner and the pre-M15 right-hand strip. Only a real fraction
                // may decide, and only onto a retro / old-border printing.
                if (!tb.number && meta.game === 'tcgp:1' && meta.retro) {
                    const retro = await retroFractionStripTarget(card.result, warp, meta);
                    if (retro) tb = retro;
                }
                if (!tb.decided_ref && !card.result.accepted) {
                    const cross = await crossCardOcrTarget(card.result, warp, tb, meta, pack);
                    if (cross) tb = cross;
                }
                card.result = applyBoosts(card.result, tb, (i) => meta.refs[i]);
                card.result.ocr = { number: tb.number, decided_ref: tb.decided_ref, via: tb.via, ms: Math.round(tb.ms), ...(tb.legacy ? { legacy: 1 } : {}) };
            } catch (err) {
                card.ocrError = String((err && err.message) || err);
            } finally {
                warp?.delete();
            }
        }
    } finally {
        mat.delete();
    }
    if (rescuedEmpty && !out.cards[0]?.result?.ocr?.decided_ref) {
        out.cards = [];
    }
    return out;
}

const LEGACY_REGION = [0.50, 0.94, 0.48, 0.055];
// Brothers' War-style retro frames print "20/38" in the middle of the copyright line.
const RETRO_FRACTION_REGION = [0.15, 0.88, 0.70, 0.08];
// Tight 2-line MTG collector strip (bottom-left only, excluding rules text above).
const MTG_TIGHT_COLLECTOR_REGION = [0.02, 0.94, 0.48, 0.06];
const CROSS_CARD_MIN_D = 10;
const MTG_CROSS_MAX_DD = 2.75;
const MTG_CROSS_MAX_D = 16.6;
const MTG_OCR_SET_FIX = { DNE: 'ONE', DNJE: 'ONE', KLN: 'XLN', FON: 'FDN', CHR: 'CMR', OU: 'HOU' };

const metaLookupCache = new WeakMap();

function getMetaLookup(meta) {
    if (!meta?.refs?.length) return null;
    let lk = metaLookupCache.get(meta);
    if (lk) return lk;
    const setAbbrs = new Set();
    const bySetNum = new Map();
    const n = meta.refs.length;
    for (let i = 0; i < n; i++) {
        const a = String(meta.abbr?.[i] || '').toUpperCase();
        if (a.length >= 2) setAbbrs.add(a);
        const rawNum = String(meta.numbers?.[i] || '');
        if (!rawNum) continue;
        const numPart = rawNum.includes('/') ? rawNum.split('/')[0] : rawNum;
        const cn = String(parseInt(numPart, 10));
        if (!/^\d+$/.test(cn)) continue;
        const k = `${a}|${cn}`;
        let list = bySetNum.get(k);
        if (!list) {
            list = [];
            bySetNum.set(k, list);
        }
        list.push(i);
    }
    lk = { setAbbrs, bySetNum };
    metaLookupCache.set(meta, lk);
    return lk;
}

/**
 * Unambiguous pack-wide OCR lookup for One Piece and Pokemon when the hash match is
 * unaccepted and weak (d >= 10). Never overrides an accepted hash or a strong hash.
 */
export function unambiguousPackTarget(meta, number, leadI, { accepted = false, d = NaN, text = '', pack = null, query = null } = {}) {
    if (accepted || leadI == null || !number || !meta?.numbers) return -1;
    if (!(Number.isFinite(d) && d >= CROSS_CARD_MIN_D)) return -1;
    const frac = number.includes('/');
    const pokemon = meta.game === 'tcgp:3';
    const onepiece = meta.game === 'tcgp:68';
    const lorcana = meta.game === 'tcgp:71';
    const riftbound = meta.game === 'tcgp:89';
    if (pokemon || lorcana || riftbound) { if (!frac) return -1; }
    else if (onepiece) { if (!/[A-Z]/.test(number)) return -1; }
    else return -1;

    const key = canonNumber(number);
    const same = (n) => frac
        ? (String(n || '').includes('/') && canonNumber(n) === key)
        : numbersMatch(n || '', number);
    if (same(meta.numbers[leadI])) return -1;

    let ids = [];
    for (let i = 0; i < meta.numbers.length; i++) if (same(meta.numbers[i])) ids.push(i);
    if (!ids.length) return -1;

    // Lorcana & Riftbound print the set code in the collector line ("39/204 · EN · 6" or "RAD · 065/167 · EN")
    if ((lorcana || riftbound) && text && meta.abbr) {
        const raw = String(text).toUpperCase();
        const setTokens = new Set();
        if (lorcana) {
            for (const m of raw.matchAll(/(?:EN|DE|FR|IT)\s*[·•*.,:;-]?\s*([0-9]{1,2}|Q[1-9]|D23|D100|DLPC)(?![A-Z0-9])/g)) {
                setTokens.add(m[1]);
            }
        } else {
            for (const tok of raw.split(/[^A-Z0-9]+/)) {
                if (tok.length >= 3) setTokens.add(tok);
            }
        }
        if (setTokens.size) {
            const bySet = ids.filter((i) => setTokens.has(String(meta.abbr[i] || '').toUpperCase()));
            if (bySet.length) ids = bySet;
        }
        if (pack?.lo && query?.lo) {
            ids = ids.filter((i) => {
                const di = refDistance(pack, query, i);
                return di <= d + MTG_CROSS_MAX_DD && di <= MTG_CROSS_MAX_D;
            });
        }
    }

    const names = new Set(ids.map((i) => meta.names[i]));
    if (names.size !== 1 || names.has(meta.names[leadI])) return -1;
    const pen = meta.pen;
    ids.sort((a, b) => ((pen ? pen[a] - pen[b] : 0) || (a - b)));
    return ids[0];
}

/**
 * Unambiguous MTG set-code + collector-fraction / zero-padded rarity-number lookup when the
 * hash match is unaccepted and weak (d >= 10). Requires a language-anchored set code (or a
 * standalone 3-letter set code on the collector bottom line) AND a 3-digit / >=10 fraction or
 * zero-padded rarity number, and the target's pack hash distance must sit within 2.5 bits of
 * the lead (and <= 16.5).
 */
export function mtgSetNumberTarget(text, result, meta, pack = null) {
    if (!text || !result || result.accepted || meta?.game !== 'tcgp:1') return null;
    const bestI = result.best?.i ?? result.top?.[0]?.i;
    const bestD = Number(result.best?.d ?? result.top?.[0]?.d ?? NaN);
    if (bestI == null || !(Number.isFinite(bestD) && bestD >= CROSS_CARD_MIN_D)) return null;
    const lk = getMetaLookup(meta);
    if (!lk) return null;

    const raw = String(text || '');
    const cleaned = raw
        .replace(/(?<![A-Za-z0-9])([MRULC])[\s.,:;-]+(?=[0O][0-9OolIti|BbSs]{2,3})/gi, '$1')
        .replace(/(?<=[0-9OolIti])[Bb](?=[0-9OolIti])/g, '8')
        .replace(/(?<=[0-9OolIti])[sS](?=[0-9OolItiA-Za-z])/g, '5');
    const n = normNumber(cleaned);
    const fracs = [...n.matchAll(/(?<![0-9])([0-9]{3,4}|[1-9][0-9]{1,2})\/([0-9]{2,4})(?![0-9])/g)];
    const rars = [...n.matchAll(/(?<![A-Z0-9])[MRULC]0+([0-9]{2,4})(?![0-9])/g)].filter((m) => !/^(?:19|20)\d\d$/.test(m[1]));
    if (!fracs.length && !rars.length) return null;
    const num = fracs.length
        ? String(parseInt(fracs[fracs.length - 1][1], 10))
        : String(parseInt(rars[rars.length - 1][1], 10));
    if (!num || numbersMatch(meta.numbers[bestI] || '', num)) return null;

    const rawCodes = new Set();
    for (const m of raw.toUpperCase().matchAll(/(?<![A-Z0-9])([A-Z0-9]{2,5})(?:\s+[·•*.,:;+→>0-9-]?|\s*[·•*.,:;+→>0-9-])\s*(?:EN|DE|FR|IT|ES|SP|PT|JA|JP|KO|KR|RU|CS|CT|PH|ZHS|ZHT)(?![A-Z])/g)) {
        const c = m[1].replace(/[0-9]+$/, '');
        if (c.length >= 2) rawCodes.add(c);
        rawCodes.add(m[1]);
    }
    const lines = raw.toUpperCase().trim().split(/\n+/);
    const lastLine = lines[lines.length - 1] || '';
    for (const tok of lastLine.split(/[^A-Z0-9]+/)) {
        if (tok.length === 3 && (lk.setAbbrs.has(tok) || MTG_OCR_SET_FIX[tok])) rawCodes.add(tok);
    }
    for (const c of [...rawCodes]) {
        if (MTG_OCR_SET_FIX[c]) rawCodes.add(MTG_OCR_SET_FIX[c]);
    }
    const codes = [...rawCodes].filter((c) => lk.setAbbrs.has(c));
    if (!codes.length) return null;

    let pool = [];
    const q = result.query;
    for (const code of codes) {
        for (const idx of lk.bySetNum.get(`${code}|${num}`) || []) {
            if (meta.nonMain && meta.nonMain[idx] === 2) continue;
            if (pack?.lo && q?.lo) {
                const d = refDistance(pack, q, idx);
                if (!(d <= bestD + MTG_CROSS_MAX_DD && d <= MTG_CROSS_MAX_D)) continue;
            }
            pool.push(idx);
        }
    }
    if (!pool.length) return null;
    if (meta.nonMain) {
        const mainPool = pool.filter((i) => !meta.nonMain[i]);
        if (mainPool.length) pool = mainPool;
    }
    const names = new Set(pool.map((i) => meta.names[i]));
    if (names.size !== 1 || names.has(meta.names[bestI])) return null;
    const pen = meta.pen;
    pool.sort((a, b) => ((pen ? pen[a] - pen[b] : 0) || (a - b)));
    return { idx: pool[0], ref: meta.refs[pool[0]], number: num };
}

async function crossCardOcrTarget(result, warp, tb, meta, pack) {
    try {
        const bestI = result.best?.i ?? result.top?.[0]?.i;
        const bestD = Number(result.best?.d ?? result.top?.[0]?.d ?? NaN);
        if (bestI == null) return null;
        if (meta.game === 'tcgp:3' || meta.game === 'tcgp:68' || meta.game === 'tcgp:71' || meta.game === 'tcgp:89') {
            const idx = unambiguousPackTarget(meta, tb.number || '', bestI, { accepted: !!result.accepted, d: bestD, text: tb.text || '', pack, query: result.query });
            if (idx < 0) return null;
            const ref = meta.refs[idx];
            if (!result.top?.some((t) => t.i === idx)) {
                result.top = [{ i: idx, d: bestD, match_pct: result.best?.match_pct ?? 50, confidence: result.confidence ?? 50 }, ...(result.top || [])];
            }
            return { ...tb, boosts: { ...(tb.boosts || {}), [ref]: OCR_DELTA }, decided_ref: ref, via: 'ocr' };
        }
        if (meta.game === 'tcgp:1') {
            let hit = mtgSetNumberTarget(tb.text || '', result, meta, pack);
            let extraMs = 0;
            if (!hit && Number.isFinite(bestD) && bestD >= CROSS_CARD_MIN_D) {
                const pixels = { data: warp.data, width: warp.cols, height: warp.rows, channels: warp.channels() };
                const rWide = await recognizeCorner(cropPixels(pixels, [0.00, 0.90, 0.70, 0.10]), 'tcgp:1');
                extraMs += rWide.ms || 0;
                const combinedWide = `${tb.text || ''}\n${rWide?.text || ''}`;
                if (rWide?.text) {
                    hit = mtgSetNumberTarget(rWide.text, result, meta, pack)
                        || mtgSetNumberTarget(combinedWide, result, meta, pack);
                }
                if (!hit) {
                    const strip = cropPixels(pixels, MTG_TIGHT_COLLECTOR_REGION);
                    const src = new cv.Mat(strip.height, strip.width, strip.channels === 4 ? cv.CV_8UC4 : cv.CV_8UC3);
                    const dst = new cv.Mat();
                    try {
                        src.data.set(strip.data);
                        cv.resize(src, dst, new cv.Size(strip.width * 3, strip.height * 3), 0, 0, cv.INTER_LINEAR);
                        const r2 = await recognizeCorner({ data: new Uint8Array(dst.data), width: dst.cols, height: dst.rows, channels: strip.channels }, 'tcgp:1');
                        extraMs += r2.ms || 0;
                    if (r2?.text) {
                        hit = mtgSetNumberTarget(r2.text, result, meta, pack)
                            || mtgSetNumberTarget(`${r2.text}\n${combinedWide}`, result, meta, pack);
                    }
                    } finally {
                        src.delete();
                        dst.delete();
                    }
                }
            }
            if (!hit) return null;
            if (!result.top?.some((t) => t.i === hit.idx)) {
                const d = (pack?.lo && result.query?.lo) ? refDistance(pack, result.query, hit.idx) : bestD;
                result.top = [{ i: hit.idx, d, match_pct: result.best?.match_pct ?? 50, confidence: result.confidence ?? 50 }, ...(result.top || [])];
            }
            return {
                ...tb,
                number: hit.number || tb.number || '',
                boosts: { ...(tb.boosts || {}), [hit.ref]: OCR_DELTA },
                decided_ref: hit.ref,
                via: 'ocr',
                ms: (tb.ms || 0) + extraMs,
            };
        }
        return null;
    } catch { return null; }
}

/** OCR the pre-M15 strip (see readLegacyStrip) off a 600x840 cv warp; upscaled x4 first. */
async function readLegacyStripFromWarp(warp, game, region = LEGACY_REGION) {
    const pixels = { data: warp.data, width: warp.cols, height: warp.rows, channels: warp.channels() };
    const strip = cropPixels(pixels, region);
    const src = new cv.Mat(strip.height, strip.width, strip.channels === 4 ? cv.CV_8UC4 : cv.CV_8UC3);
    const dst = new cv.Mat();
    try {
        src.data.set(strip.data);
        cv.resize(src, dst, new cv.Size(strip.width * 4, strip.height * 4), 0, 0, cv.INTER_LINEAR);
        return await recognizeCorner({ data: new Uint8Array(dst.data), width: dst.cols, height: dst.rows, channels: strip.channels }, game);
    } finally {
        src.delete();
        dst.delete();
    }
}

/**
 * Legacy-strip read for one still-image card, as a tieBreak-shaped result, or null when the
 * number it reads may not decide (gatedOcrTarget over every printing of the winner's name,
 * hash distance taken from result.top; a target outside the top has no distance and fails).
 */
async function legacyStripTarget(result, warp, meta) {
    try {
        const bestI = result.best?.i ?? result.top?.[0]?.i;
        if (bestI == null || !meta.names) return null;
        const nameId = meta.names[bestI];
        if (nameId == null || nameId < 0) return null;
        const strip = await readLegacyStripFromWarp(warp, meta.game);
        if (!strip?.number) return null;
        const dByI = new Map((result.top || []).map((t) => [t.i, t.d]));
        const pool = [{ ref: meta.refs[bestI], number: meta.numbers[bestI] || '', set_abbr: meta.abbr[bestI] || '', d: result.best?.d ?? dByI.get(bestI) }];
        for (let i = 0; i < meta.names.length; i++) {
            if (i === bestI || meta.names[i] !== nameId) continue;
            pool.push({ ref: meta.refs[i], number: meta.numbers[i] || '', set_abbr: meta.abbr[i] || '', d: dByI.get(i) });
        }
        const targetRef = gatedOcrTarget(pool, strip.number, meta);
        if (!targetRef) return null;
        return { number: strip.number, conf: strip.conf || 0, boosts: {}, decided_ref: targetRef, via: 'ocr', ms: strip.ms || 0, legacy: true };
    } catch { return null; }
}

/**
 * A fraction read from the retro copyright band may preselect only a retro / old-border
 * printing. A bare year or a non-retro number is not a decision.
 */
export function retroFractionTarget(pool, text, meta) {
    const raw = String(text || '');
    if (!/\d\s*\/\s*\d/.test(raw) || !meta?.retro) return null;
    const number = parseNumber(raw, 'tcgp:1');
    if (!number) return null;
    const ref = gatedOcrTarget(pool, number, meta);
    if (!ref) return null;
    const i = meta.refs.indexOf(ref);
    return i >= 0 && meta.retro[i] ? { ref, number } : null;
}

async function retroFractionStripTarget(result, warp, meta) {
    try {
        const bestI = result.best?.i ?? result.top?.[0]?.i;
        if (bestI == null || !meta.names || !meta.retro) return null;
        const nameId = meta.names[bestI];
        if (nameId == null || nameId < 0) return null;
        const read = await readLegacyStripFromWarp(warp, meta.game, RETRO_FRACTION_REGION);
        if (!read?.text) return null;
        const dByI = new Map((result.top || []).map((t) => [t.i, t.d]));
        const pool = [{ ref: meta.refs[bestI], number: meta.numbers[bestI] || '', set_abbr: meta.abbr[bestI] || '', d: result.best?.d ?? dByI.get(bestI) }];
        for (let i = 0; i < meta.names.length; i++) {
            if (i === bestI || meta.names[i] !== nameId) continue;
            pool.push({ ref: meta.refs[i], number: meta.numbers[i] || '', set_abbr: meta.abbr[i] || '', d: dByI.get(i) });
        }
        const hit = retroFractionTarget(pool, read.text, meta);
        if (!hit) return null;
        return { number: hit.number, conf: read.conf || 0, boosts: {}, decided_ref: hit.ref, via: 'ocr', ms: read.ms || 0, legacy: true };
    } catch { return null; }
}

function candidatesOf(result, meta) {
    if (!result) return [];
    const idx = new Set((result.top || []).map((t) => t.i));
    for (const i of result.best?.siblings || []) idx.add(i);
    const bestI = result.best?.i ?? result.top?.[0]?.i;
    const name = meta.names && bestI != null ? meta.names[bestI] : -1;
    if (name >= 0) {
        for (let i = 0; i < meta.names.length; i++) if (meta.names[i] === name) idx.add(i);
    }
    return [...idx]
        .filter((i) => meta.refs[i] != null)
        .map((i) => ({ ref: meta.refs[i], number: meta.numbers[i] || '', set_abbr: meta.abbr[i] || '', name_id: meta.names ? meta.names[i] : undefined }));
}

export const PHONE_OCR_MAX_DD = 1.5;

function phonePool(row) {
    const lead = row?.cands?.[0];
    if (!lead) return { lead: null, pool: [] };
    const leadBase = baseName(lead.tuple?.[1] || row.details?.[lead.ref]?.name || '');
    if (!leadBase) return { lead, pool: [] };
    const pool = row.cands
        .filter((c) => baseName(c.tuple?.[1] || row.details?.[c.ref]?.name || '') === leadBase)
        .map((c) => ({
            ref: c.ref,
            number: row.details?.[c.ref]?.number || c.tuple?.[2] || '',
            set_abbr: row.details?.[c.ref]?.group_abbr || c.tuple?.[3] || '',
            d: c.d ?? null,
        }));
    return { lead, pool };
}

/**
 * Improvement-only gate shared by phone ingest and the still-image legacy strip.
 * pool[0] is the lead; every entry is a same-name candidate {ref, number, d}. Returns the
 * ref the read number may preselect, or null: the number must single out exactly one pool
 * candidate by number alone (a set-code-filtered decision is deliberately not trusted:
 * Prerelease / Promo Pack printings print the base set's number and set code, so a shared
 * number can never decide among them), it must be unique across every printing of that name
 * in the pack, and the target must sit within PHONE_OCR_MAX_DD hash bits of the lead.
 */
export function gatedOcrTarget(pool, number, meta) {
    if (!number || !meta?.refs?.length || !Array.isArray(pool) || pool.length < 2) return null;
    if (!shouldTieBreak(pool)) return null;
    const lead = pool[0];
    const hits = pool.filter((c) => numbersMatch(c.number, number));
    if (hits.length !== 1 || hits[0].ref === lead.ref) return null;
    const nameId = meta.names[meta.refs.indexOf(lead.ref)];
    if (nameId == null || nameId < 0) return null;
    let global = 0;
    for (let i = 0; i < meta.names.length; i++) {
        if (meta.names[i] === nameId && numbersMatch(meta.numbers[i] || '', number)) global++;
    }
    if (global !== 1) return null;
    const target = hits[0];
    if (!Number.isFinite(target.d) || !Number.isFinite(lead.d) || target.d - lead.d > PHONE_OCR_MAX_DD) return null;
    return target.ref;
}

/** Pure decision core of refinePhoneRowWithOcr (Node-tested): gatedOcrTarget over the row's candidates. */
export function phoneOcrTarget(row, number, meta) {
    if (!Array.isArray(row?.cands) || row.cands.length < 2) return null;
    const { lead, pool } = phonePool(row);
    if (!lead) return null;
    // gatedOcrTarget treats pool[0] as the lead; phonePool preserves the row's candidate order.
    return gatedOcrTarget(pool, number, meta);
}

/**
 * Phone-ingest only, improvement-only: run the collector-number tie-break on the phone's
 * already-warped photo and preselect the printing phoneOcrTarget allows. Preselect only:
 * d, confidence, accepted and gap are never touched, so the row buckets exactly as it did.
 * Any doubt or error leaves the row exactly as it was (no lead change, no OCR label).
 */
export async function refinePhoneRowWithOcr(row, pack, meta, allow = null) {
    try {
        if (!row || row.touched || row.source !== 'phone' || !row.photo) return;
        if (pack?.game !== 'tcgp:1' || !meta?.refs?.length) return;
        if (!Array.isArray(row.cands) || row.cands.length < 2) return;
        const { pool } = phonePool(row);
        if (!shouldTieBreak(pool)) return;

        if (!cv) await cvReady(pickSrc());
        const drawn = await drawPhotoOcr(row.photo);
        if (!drawn) return;
        const tb = await tieBreak({ card: drawn.pixels, game: pack.game, cands: pool });
        let number = tb.number || '';
        if (!number) number = (await readLegacyStrip(drawn.canvas)) || '';
        if (!number) return;

        const targetRef = phoneOcrTarget(row, number, meta);
        if (!targetRef) return;
        // An excluded printing must never become the OCR-decided lead.
        if (allow && pack?.refs && allow.length >= pack.n) {
            const ti = pack.refs.findIndex((t) => t[0] === targetRef);
            if (ti >= 0 && !allow[ti]) return;
        }
        const target = row.cands.find((c) => c.ref === targetRef);
        if (!target) return;
        target.printingState = 'likely';
        target.ocr = number;
        row.cands = [target, ...row.cands.filter((c) => c !== target)];
        if ('choice' in row) row.choice = 0;
        row.ocrState = 'decided';
    } catch { /* fail closed: row keeps the hash order, no label */ }
}

function drawPhotoOcr(src) {
    return new Promise((resolve) => {
        const img = new Image();
        img.onload = () => {
            try {
                const canvas = document.createElement('canvas');
                canvas.width = OCR_W; canvas.height = OCR_H;
                const ctx = canvas.getContext('2d', { willReadFrequently: true });
                ctx.imageSmoothingEnabled = true;
                ctx.imageSmoothingQuality = 'high';
                ctx.drawImage(img, 0, 0, OCR_W, OCR_H);
                const d = ctx.getImageData(0, 0, OCR_W, OCR_H);
                resolve({ canvas, pixels: { data: d.data, width: d.width, height: d.height, channels: 4 } });
            } catch { resolve(null); }
        };
        img.onerror = () => resolve(null);
        img.src = src;
    });
}

// Pre-M15 MTG prints the collector number at the end of the copyright line, bottom-right
// ("...LLC 24/264"), outside both tieBreak regions. The glyphs are ~12px on a 600x840 warp,
// so the strip is OCR'd upscaled x4 (drawImage smoothing; recognizeCorner upsamples further).
async function readLegacyStrip(canvas600) {
    try {
        const strip = document.createElement('canvas');
        strip.width = 1152; strip.height = 184;
        const ctx = strip.getContext('2d', { willReadFrequently: true });
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(canvas600, OCR_W * 0.50, OCR_H * 0.94, OCR_W * 0.48, OCR_H * 0.055, 0, 0, strip.width, strip.height);
        const d = ctx.getImageData(0, 0, strip.width, strip.height);
        const r = await recognizeCorner({ data: d.data, width: d.width, height: d.height, channels: 4 }, 'tcgp:1');
        return r.number || '';
    } catch { return ''; }
}

/** Compact per-index catalog facts the worker needs; built once per pack on the page. */
export function packMeta(pack) {
    const n = pack?.refs?.length || 0;
    const refs = new Array(n);
    const numbers = new Array(n);
    const abbr = new Array(n);
    const names = new Int32Array(n);
    const retro = new Uint8Array(n);
    const pen = new Uint8Array(n);
    // nonMain: 2 = Art Card, 1 = Token / Emblem / Theme Card / Minigame, 0 = normal card
    const nonMain = new Uint8Array(n);
    const ids = new Map();
    for (let i = 0; i < n; i++) {
        const r = pack.refs[i];
        refs[i] = r[0];
        numbers[i] = r[2] || '';
        abbr[i] = r[3] || '';
        const nm = r[1] || '';
        if (/\((?:retro\s+frame|old\s+border)\)/i.test(nm)) retro[i] = 1;
        if (/\bart card\b/i.test(nm)) nonMain[i] = 2;
        else if (/\b(?:token|emblem|theme card|minigame)\b/i.test(nm)) nonMain[i] = 1;
        pen[i] = Math.min(255, Math.max(0, setPenalty(r) | 0));
        const key = baseName(nm);
        if (!ids.has(key)) ids.set(key, ids.size);
        names[i] = key ? ids.get(key) : -1;
    }
    return { game: pack?.game, refs, numbers, abbr, names, retro, pen, nonMain };
}
