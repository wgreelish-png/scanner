/**
 * desk-results.js - turns on-device image-scan results into desktop picker rows (no DOM).
 *
 * Pack refs: refs[i] = [ref, name, number, group_abbr, group_name, rarity, image, variants]; variants =
 * [{id, label, nm, primary?}] (NM price per printing). cl[0..n) = same-art cluster (-1 none).
 *
 * refImage(tuple) -> url                       pack image, else the tcgp CDN 200w image for p:ID refs
 * cardFaces(tuple, detail?) -> {face, src, zoom}[]
 *   One image, unless detail.image_count > 1 on a p:ID. The hash and the primary CDN file are the front
 *   ({id}_200w.jpg). The back is {id}_1_200w.jpg. zoom is the 400w file.
 * siblingsOf(pack, i, limit=6) -> i[]          same art cluster, other refs (normal/foil SKUs, same-art reprints)
 * candidatesFrom(pack, result, k=5) -> Cand[]  Cand: {ref, tuple, d, match_pct, confidence, printingState, siblings: tuple[]}
 *   The winner's same-art printings, and printing-group refs whose distance is within TIE_D of the winner, come
 *   first (a printing with a clearly worse distance stays in distance order). The collector number read by
 *   OCR (result.ocr, app/image-ocr.js) decides first: decided_ref leads (printingState 'likely'; on an unaccepted
 *   scan even when it is a different-art rival; any printing of the winner's card name even outside the hash
 *   top), else printings
 *   whose number matches the read one. Otherwise core/setrank.js orders them so regular sets beat promos / misc /
 *   reprint-list printings, and a 'likely' printing rank keeps its winner first. Cand.ocr = the read number
 *   when it matches that candidate. Then different-art rivals by distance. Accepted scans may fill all k slots with tied printings;
 *   unaccepted ones keep at most 3 so rivals stay visible. Same-art candidates share the winner's confidence;
 *   rivals are scaled down by their distance (localmatch.rivalConfidence).
 *   Tuples are copied out of the pack so rows stay valid after the user switches game.
 * detailRefs(cands, limit=40) -> string[]      refs to ask catalogDetail for (candidates + their siblings)
 * printingOptions(cand, details) -> Option[]   Option: {ref, tuple, printing, sibling: false, label}
 *   printings (finishes) of the matched product only, Normal first. Live catalog printings when details has the
 *   ref (primary = the pack's primary variant, else Normal), else the pack's variants, else one 'Default'.
 * preselect(options, details) -> index          catalog preselect_sku, else the pack's primary variant, else 0
 * defaultPrinting(options, details, prefer, detected?) -> index   the preferred printing (e.g. 'Foil') when offered,
 *   else (prefer Any) the image-detected printing label when offered, else preselect
 * printingKey(label) -> string                  normalised printing name ('' for Any)
 * candidatesFrom(..., k, {allow, prefer}): allow = Uint8Array(n) set lock / exclusions (refs outside are dropped);
 *   prefer = default printing: tied printings that offer it rank before those that do not (after OCR).
 * describe(tuple, detail?) -> {name, number, set, abbr, rarity, image}
 * isCloseMatch(row) -> bool   a different card, or an ambiguous printing, is near enough to toggle
 * walkQueue(rows, scope) -> row[]   table order; 'all' or 'close'; completed and sent rows stay out
 * toCsv(picked) -> string
 * exportFieldList(game) -> {key, label}[]   column picker. tcgt games (not TCGPlayer) get SKU
 *   instead of TCGPlayer ID, Manapool ID, and Manapool Price.
 * exportTable(records, keys) / exportJson(records, keys)
 * tcgplayerCsv(records, gameName) -> {csv, skipped, count}   TCGPlayer inventory file (SKU id, add-to-quantity)
 * routeBucket({accepted, printingState, cands}) -> 'ready' | 'pending'
 *   Accepted and a printing that is not ambiguous goes to Ready. Low confidence (!accepted) or
 *   printingState 'ambiguous' stays Pending until the user picks a candidate or a printing.
 */
import { rivalConfidence, refDistance, GAP_MIN } from '../core/localmatch.js';
import { rankTies, setPenalty } from '../core/setrank.js';
import { numbersMatch } from '../core/ocr/layouts.js';
import { detectReprintRef, detectGameVariant, isPlainReprintName } from './reprint-rerank.js';
import { detectPokemonVariantRef, detectCosmosRef } from './pokemon-watermark.js';
import { isPokemonFalsePosPromoGroup } from './variants/pokemon.js';
import { listOrCollectorNumbersMatch } from './variants/mtg.js';

// bh1 distance within which printing-group refs (distinct art) still count as a tie with the winner.
const TIE_D = 0.35;

export function refImage(tuple, detail = null) {
    if (detail?.thumb) return detail.thumb;
    if (detail?.image && Number(detail?.image_count) === 0) return detail.image;
    if (tuple?.[6]) return tuple[6];
    const m = /^p:(\d+)$/.exec(tuple?.[0] || '');
    return m ? `https://cdn.tcgtracking.com/product/${m[1]}_200w.jpg` : '';
}

/** Front + back when the matched tcgp product is double-faced. Otherwise the single catalog image. */
export function cardFaces(tuple, detail = null) {
    const src = refImage(tuple, detail) || detail?.image || '';
    const overlay = detail?.overlay_label || '';
    const id = /^p:(\d+)$/.exec(String(tuple?.[0] || ''))?.[1];
    if (id && Number(detail?.image_count) > 1) {
        const base = `https://cdn.tcgtracking.com/product/${id}`;
        return [
            { face: 'front', src: `${base}_200w.jpg`, zoom: `${base}_400w.jpg`, overlay },
            { face: 'back', src: `${base}_1_200w.jpg`, zoom: `${base}_1_400w.jpg`, overlay },
        ];
    }
    return src ? [{ face: '', src, zoom: detail?.image || src, overlay }] : [];
}

/** Card name without printing marks: "Sol Ring (0286)" and "Sol Ring" are one card. Same rule as the v2 printing group. */
export function baseName(name) {
    return String(name || '')
        .replace(/\s+-\s+\d+\/\d+\b/g, '')
        .replace(/\s*\[[^\]]*\]/g, '')
        .replace(/\s*\([^)]*\)/g, '')
        .replace(/\s+-\s+(?:\d+\/\d+|"[^"]*")$/, '')
        .trim()
        .toLowerCase();
}

const packIndexCache = new WeakMap();

function getPackIndex(pack) {
    if (!pack?.refs) return null;
    let idx = packIndexCache.get(pack);
    if (idx) return idx;
    const byRef = new Map();
    const byCl = new Map();
    const byPg = new Map();
    const n = pack.n || pack.refs.length;
    const cl = pack.cl;
    const hasPg = cl && cl.length >= 2 * n;
    for (let i = 0; i < n; i++) {
        const ref = pack.refs[i]?.[0];
        if (ref) byRef.set(ref, i);
        if (cl) {
            const c = cl[i];
            if (c != null && c >= 0) {
                let list = byCl.get(c);
                if (!list) {
                    list = [];
                    byCl.set(c, list);
                }
                list.push(i);
            }
            if (hasPg) {
                const p = cl[n + i];
                if (p != null && p >= 0) {
                    let list = byPg.get(p);
                    if (!list) {
                        list = [];
                        byPg.set(p, list);
                    }
                    list.push(i);
                }
            }
        }
    }
    idx = { byRef, byCl, byPg };
    packIndexCache.set(pack, idx);
    return idx;
}

export function siblingsOf(pack, i, limit = 6) {
    const c = pack?.cl?.[i];
    if (c == null || c < 0) return [];
    const list = getPackIndex(pack)?.byCl.get(c);
    if (!list) return [];
    const out = [];
    for (let k = 0; k < list.length && out.length < limit; k++) {
        const j = list[k];
        if (j !== i) out.push(j);
    }
    return out;
}

export function candidatesFrom(pack, result, k = 5, { allow = null, prefer = '' } = {}) {
    if (!result?.top?.length) return [];
    const ok = (i) => !allow || !!allow[i];
    const bestI = result.best?.i ?? result.top[0].i;
    const cluster = pack.cl[bestI];
    const sameArt = (i) => i === bestI || (cluster != null && cluster >= 0 && pack.cl[i] === cluster);
    const top = new Map(result.top.map((t) => [t.i, t]));
    const bestD = top.get(bestI)?.d ?? result.best?.d ?? result.top[0].d;
    const bestConf = result.best?.confidence ?? result.confidence ?? top.get(bestI)?.confidence;

    const seen = new Set();
    const uniq = (ids) => ids.filter((i) => ok(i) && !seen.has(i) && seen.add(i));
    // Printing-group refs (same name, own art/hash) are only a tie when their distance is as good as the winner's,
    // except when the hash winner is a high-penalty promo/reprint (setPenalty >= 4) and a regular-set printing
    // with the exact same collector number is within 0.65 bits.
    const bestPen = setPenalty(pack.refs[bestI]);
    const bestNum = pack.refs[bestI]?.[2] || '';
    const bestHolo = /\((?:cosmos?|mirage|cracked ice|line|water web|confetti)\s+holo\)/i.test(pack.refs[bestI]?.[1] || '');
    const bestTuple = pack.refs[bestI];
    const falsePosPromo = isPokemonFalsePosPromoGroup(bestTuple)
        || (String(pack.game || '') === 'tcgp:1' && /\b(?:promo pack|prerelease cards)\b/i.test(bestTuple?.[4] || ''));
    let sameNumRegPg = [];
    if (falsePosPromo && bestNum && pack.cl && pack.cl.length >= 2 * pack.n) {
        const pg = pack.cl[pack.n + bestI];
        const pIdx = getPackIndex(pack);
        const bestBase = baseName(bestTuple?.[1] || '');
        if (pg >= 0 && pIdx?.byPg) {
            sameNumRegPg = (pIdx.byPg.get(pg) || []).filter((j) =>
                setPenalty(pack.refs[j]) === 0
                && !/trick or trade/i.test(pack.refs[j]?.[4] || '')
                && pack.refs[j]?.[3] !== bestTuple?.[3]
                && baseName(pack.refs[j]?.[1] || '') === bestBase
                && numbersMatch(pack.refs[j]?.[2], bestNum)
                && isPlainReprintName(pack.refs[j]?.[1] || ''),
            );
        }
    }
    const closeEnough = (i) => sameArt(i) || sameNumRegPg.includes(i) || (top.has(i) && (
        top.get(i).d - bestD <= TIE_D ||
        (bestPen >= 4 && setPenalty(pack.refs[i]) === 0 && bestNum && numbersMatch(pack.refs[i]?.[2], bestNum)
            && top.get(i).d - bestD <= (bestHolo ? 1.85 : 0.65))
    ));
    const tied = uniq([bestI, ...(result.best?.siblings || []).filter(closeEnough), ...sameNumRegPg, ...siblingsOf(pack, bestI, 12)]);
    if (!tied.length) return [];
    const ocr = result.ocr?.number ? result.ocr : null;
    const read = (i) => !!ocr && numbersMatch(pack.refs[i][2], ocr.number);
    let decided = result.ocr?.decided_ref ? tied.find((i) => pack.refs[i][0] === result.ocr.decided_ref) : undefined;
    if (decided == null && result.ocr?.decided_ref && !result.accepted) {
        const rival = result.top.find((t) => ok(t.i) && pack.refs[t.i][0] === result.ocr.decided_ref);
        if (rival) {
            tied.unshift(rival.i);
            seen.add(rival.i);
            decided = rival.i;
        }
    }
    if (decided == null && result.ocr?.decided_ref) {
        const j = getPackIndex(pack)?.byRef.get(result.ocr.decided_ref) ?? -1;
        const allowCrossClusterOcr = !result.accepted || cluster == null || cluster < 0 || sameArt(j) || top.has(j);
        if (j >= 0 && ok(j) && !seen.has(j) && allowCrossClusterOcr && baseName(pack.refs[j][1]) === baseName(pack.refs[bestI][1])) {
            tied.unshift(j);
            seen.add(j);
            decided = j;
        }
    }
    const wantKey = printingKey(prefer);
    const offers = (i) => (pack.refs[i][7] || []).some((v) => printingKey(v.label) === wantKey);
    const rank = (ids) => (wantKey ? [...rankTies(pack, ids.filter(offers)), ...rankTies(pack, ids.filter((i) => !offers(i)))] : rankTies(pack, ids));
    let ordered;
    if (decided != null) ordered = [decided, ...rank(tied.filter((i) => i !== decided))];
    else if (ocr && tied.some(read)) ordered = [...rank(tied.filter(read)), ...rank(tied.filter((i) => !read(i)))];
    else ordered = result.best?.printing?.state === 'likely' && tied[0] === bestI ? [bestI, ...rank(tied.slice(1))] : rank(tied);
    const regSibs = bestPen >= 4 && bestNum
        ? (result.best?.siblings || []).filter((i) => setPenalty(pack.refs[i]) === 0 && numbersMatch(pack.refs[i]?.[2], bestNum))
        : [];
    const rivals = uniq([...regSibs, ...result.top.map((t) => t.i)]);
    ordered = ordered.filter(ok);
    const ids = [...ordered.slice(0, result.accepted ? k : Math.min(3, k)), ...rivals].slice(0, k);

    const lead = ids[0];
    return ids.map((i) => {
        const t = top.get(i);
        const d = t?.d ?? bestD;
        return {
            ref: pack.refs[i][0],
            tuple: pack.refs[i],
            d,
            match_pct: t?.match_pct ?? result.best?.match_pct,
            confidence: sameArt(i) ? bestConf : (t?.confidence ?? rivalConfidence(bestConf ?? 0, bestD, d)),
            printingState: i === lead ? (i === decided ? 'likely' : (result.best?.printing?.state || null)) : null,
            ocr: read(i) ? ocr.number : '',
            siblings: siblingsOf(pack, i).map((j) => pack.refs[j]),
        };
    });
}

export function detailRefs(cands, limit = 40) {
    return [...new Set(cands.map((c) => c.ref))].slice(0, limit);
}

// Normal first, then the rest in catalog order. Catalog printings arrive alphabetically (Foil before Normal) with
// no primary flag, so the pack's primary variant (else Normal) marks the default.
function printingsFor(tuple, detail) {
    const variants = tuple[7] || [];
    let list;
    if (detail?.printings?.length) {
        const packPrimary = printingKey(variants.find((v) => v.primary)?.label);
        list = detail.printings.map((p) => ({ ...p, primary: !!packPrimary && printingKey(p.label) === packPrimary }));
    } else if (variants.length) {
        list = variants.map((v) => ({ key: v.label, label: v.label || 'Default', market_price: v.nm ?? null, sku_id: v.id || null, primary: !!v.primary }));
    } else {
        return [{ key: 'default', label: 'Default', market_price: detail?.market_price ?? null }];
    }
    const isNormal = (p) => printingKey(p.label) === 'normal';
    list = [...list.filter(isNormal), ...list.filter((p) => !isNormal(p))];
    if (!list.some((p) => p.primary) && isNormal(list[0])) list[0] = { ...list[0], primary: true };
    return list;
}

export function printingOptions(cand, details = {}) {
    const detail = details[cand.tuple[0]];
    return printingsFor(cand.tuple, detail).map((p) => ({ ref: cand.tuple[0], tuple: cand.tuple, printing: p, sibling: false, label: p.label }));
}

/** Comparable printing name: 'Holofoil' and 'Holo Foil' match; 'Any' / '' = no preference. */
export function printingKey(label) {
    const k = String(label || '').toLowerCase().replace(/[^a-z0-9]/g, '');
    if (!k || k === 'any') return '';
    if (k === 'holofoil') return 'holo';
    if (k === 'reverseholofoil') return 'reverseholo';
    return k;
}

/**
 * Index of the default printing: the preferred printing when this product has it; with no preference (Any), the
 * printing detected from the image (service /v1/printing, desktop.js autoPick) when offered; else preselect().
 */
export function defaultPrinting(options, details = {}, prefer = '', detected = '') {
    const want = printingKey(prefer) || printingKey(detected);
    if (want) {
        const i = options.findIndex((o) => printingKey(o.printing?.label || o.label) === want);
        if (i >= 0) return i;
    }
    return preselect(options, details);
}

export function preselect(options, details = {}) {
    const own = options.filter((o) => !o.sibling);
    const sku = details[own[0]?.ref]?.preselect_sku;
    if (sku) {
        const i = options.findIndex((o) => o.printing.sku_id === sku);
        if (i >= 0) return i;
    }
    const primary = options.findIndex((o) => !o.sibling && o.printing.primary);
    return primary >= 0 ? primary : 0;
}

export function describe(tuple, detail = null) {
    return {
        name: detail?.name || tuple[1] || tuple[0],
        number: detail?.number || tuple[2] || '',
        set: detail?.group_name || tuple[4] || '',
        abbr: detail?.group_abbr || tuple[3] || '',
        rarity: detail?.rarity || tuple[5] || '',
        image: refImage(tuple, detail) || detail?.image || '',
        overlay: detail?.overlay_label || '',
    };
}

/**
 * Pass-through Pokemon (%Ball%) / (Energy Symbol Pattern) / (Team Rocket) siblings from `details`
 * into `row.cands` right after the matched family lead, keeping up to `maxCands` (default 5: 1st result + remaining up to 4).
 * When `preferRef` is provided (e.g. from watermark detection), promotes that sibling to index 0.
 */
/** Allow mask is only meaningful with its pack (mirrors localmatch / image-scan guards). */
export function validAllow(pack, allow) {
    return allow && pack && allow.length >= pack.n ? allow : null;
}

function candAllowed(pack, allow, ref) {
    const a = validAllow(pack, allow);
    if (!a) return true;
    const i = getPackIndex(pack)?.byRef.get(ref) ?? -1;
    return i >= 0 ? !!a[i] : false;
}

export function expandVariantCandidates(cands, details = {}, maxCands = 5, preferRef = '', pack = null, allow = null) {
    if (!Array.isArray(cands) || !cands.length) return cands;
    details = details || {};
    if (preferRef && !candAllowed(pack, allow, preferRef)) preferRef = '';
    const out = [];
    const seen = new Set();
    const pushCand = (c) => {
        if (!c?.ref || seen.has(c.ref)) return;
        if (!candAllowed(pack, allow, c.ref)) return;
        seen.add(c.ref);
        out.push(c);
    };
    const lead0 = cands[0];
    const base0 = baseName(lead0?.tuple?.[1] || details[lead0?.ref]?.name || '');
    for (const c of cands) {
        pushCand(c);
        const d = details[c?.ref];
        const sibs = d?.variant_siblings;
        if (!Array.isArray(sibs) || sibs.length < 2) continue;
        if (c !== lead0) {
            const bc = baseName(c?.tuple?.[1] || d?.name || '');
            const closeD = !(Number.isFinite(lead0?.d) && Number.isFinite(c?.d) && c.d - lead0.d > 2.5);
            if ((base0 && bc && bc !== base0) || !closeD) continue;
        }
        // Include any existing candidates from this same sibling family right after `c`, then any missing siblings
        for (const existing of cands) {
            if (existing?.ref && sibs.includes(existing.ref)) pushCand(existing);
        }
        for (const sRef of sibs) {
            if (seen.has(sRef)) continue;
            const sd = details[sRef];
            if (!sd) continue;
            const variants = (sd.printings || []).map((p, idx) => ({
                id: null,
                label: p.label || p.key || 'Default',
                nm: p.market_price ?? null,
                primary: idx === 0,
            }));
            const tuple = [
                sRef,
                sd.name || sRef,
                sd.number || '',
                sd.group_abbr || c.tuple?.[3] || '',
                sd.group_name || c.tuple?.[4] || '',
                sd.rarity || c.tuple?.[5] || '',
                sd.thumb || sd.image || '',
                variants,
            ];
            pushCand({
                ref: sRef,
                tuple,
                d: c.d,
                match_pct: c.match_pct,
                confidence: c.confidence,
                printingState: null,
                ocr: c.ocr || '',
                siblings: c.siblings || [],
            });
        }
    }
    if (preferRef) {
        const idx = out.findIndex((c) => c?.ref === preferRef);
        if (idx > 0) {
            const [picked] = out.splice(idx, 1);
            if (picked.printingState == null && out[0]?.printingState) {
                picked.printingState = out[0].printingState;
            }
            out.unshift(picked);
        } else if (idx < 0) {
            const pi = pack?.refs ? (getPackIndex(pack)?.byRef.get(preferRef) ?? -1) : -1;
            const sd = details[preferRef];
            if (pi >= 0 || sd) {
                const c0 = out[0] || cands[0];
                const packTuple = pi >= 0 ? [...pack.refs[pi]] : null;
                const variants = packTuple?.[7]?.length
                    ? packTuple[7]
                    : (sd?.printings || []).map((p, i) => ({
                        id: null,
                        label: p.label || p.key || 'Default',
                        nm: p.market_price ?? null,
                        primary: i === 0,
                    }));
                const tuple = packTuple || [
                    preferRef,
                    sd.name || c0?.tuple?.[1] || preferRef,
                    sd.number || '',
                    sd.group_abbr || '',
                    sd.group_name || '',
                    sd.rarity || c0?.tuple?.[5] || '',
                    sd.thumb || sd.image || '',
                    variants,
                ];
                out.unshift({
                    ref: preferRef,
                    tuple,
                    d: c0?.d,
                    match_pct: c0?.match_pct,
                    confidence: c0?.confidence,
                    printingState: c0?.printingState ?? null,
                    ocr: '',
                    siblings: pi >= 0 ? siblingsOf(pack, pi).map((j) => pack.refs[j]) : [],
                });
            }
        }
    }
    return out.slice(0, maxCands);
}

const candNumber = (c, details = {}) => details?.[c?.ref]?.number || c?.tuple?.[2] || '';
const candBase = (c, details = {}) => baseName(c?.tuple?.[1] || details?.[c?.ref]?.name || '');

function candOffersPrefer(c, details, want) {
    if (!want || !c) return false;
    return printingOptions(c, details || {}).some((o) => printingKey(o.printing?.label || o.label) === want);
}

function lowestNmOf(tuple) {
    let lo = Infinity;
    for (const v of tuple?.[7] || []) if (Number.isFinite(v?.nm) && v.nm < lo) lo = v.nm;
    return lo;
}

/**
 * Refs that may take the lead under a non-Any printing preference: same card (base name) and same
 * collector number as the lead, and offering the preferred printing. Search order: the row's
 * candidates, then catalog variant siblings, then (unless restrictToCands) the lead's pack
 * printing group ordered by rankTies; abstains when distinct-set group rivals still tie.
 */
export function preferTargetRef(row, pack, prefer, { restrictToCands = false } = {}) {
    const want = printingKey(prefer);
    const cands = row?.cands || [];
    if (!want || !cands.length) return null;
    const details = row.details || {};
    const lead = cands[row.choice || 0] || cands[0];
    if (!lead || candOffersPrefer(lead, details, want)) return null;
    const base = candBase(lead, details);
    const num = candNumber(lead, details);
    if (!base) return null;
    const sameCard = (name, number) => candBase({ tuple: [null, name] }, {}) === base && (!num || !number || numbersMatch(number, num));
    for (const c of cands) {
        if (c !== lead && sameCard(c.tuple?.[1] || details[c.ref]?.name || '', candNumber(c, details)) && candOffersPrefer(c, details, want)) return c.ref;
    }
    const sibRefs = details[lead.ref]?.variant_siblings || [];
    for (const ref of sibRefs) {
        if (ref === lead.ref) continue;
        const d = details[ref];
        const i = pack?.refs ? (getPackIndex(pack)?.byRef.get(ref) ?? -1) : -1;
        const tuple = i >= 0 ? pack.refs[i] : null;
        if (!sameCard(d?.name || tuple?.[1] || '', d?.number || tuple?.[2] || '')) continue;
        const cand = { ref, tuple: tuple || [ref, d?.name || ref, d?.number || '', d?.group_abbr || '', d?.group_name || '', d?.rarity || '', d?.thumb || d?.image || '', []] };
        if (candOffersPrefer(cand, details, want)) return ref;
    }
    if (restrictToCands || !pack?.refs || !pack?.cl || pack.cl.length < 2 * pack.n) return null;
    const leadI = getPackIndex(pack)?.byRef.get(lead.ref) ?? -1;
    if (leadI < 0) return null;
    const pg = pack.cl[pack.n + leadI];
    if (pg == null || pg < 0) return null;
    // The group spans every same-name print (843 "Plains"): a numbered lead needs a numbered match, not a blank one.
    const groupIdx = (getPackIndex(pack)?.byPg.get(pg) || []).filter((j) => j !== leadI
        && (!num || pack.refs[j]?.[2])
        && sameCard(pack.refs[j]?.[1] || '', pack.refs[j]?.[2] || '')
        && candOffersPrefer({ ref: pack.refs[j][0], tuple: pack.refs[j] }, {}, want));
    if (!groupIdx.length) return null;
    const ordered = rankTies(pack, groupIdx);
    if (ordered.length > 1) {
        const [a, b] = ordered;
        const tie = setPenalty(pack.refs[a]) === setPenalty(pack.refs[b]) && lowestNmOf(pack.refs[a]) === lowestNmOf(pack.refs[b])
            && (pack.refs[a]?.[3] || pack.refs[a]?.[4]) !== (pack.refs[b]?.[3] || pack.refs[b]?.[4]);
        if (tie) return null;
    }
    return pack.refs[ordered[0]][0];
}

/**
 * Product-level printing preference: when the lead does not offer the preferred printing but a
 * same-card, same-number candidate does, that candidate takes the lead. A user preference is an
 * override of visual finish/pattern evidence, never of an OCR-decided different card.
 * Returns the new lead ref, or null when it abstains.
 */
export function switchToPrefer(row, pack, prefer, { allow = null, restrictToCands = false } = {}) {
    const want = printingKey(prefer);
    if (!want || !row?.cands?.length) return null;
    const lead = row.cands[row.choice || 0] || row.cands[0];
    if (candOffersPrefer(lead, row.details || {}, want)) return null;
    const targetRef = preferTargetRef(row, pack, prefer, { restrictToCands });
    if (!targetRef || targetRef === lead?.ref || farFromScan(row, pack, targetRef)) return null;
    if (row.ocrState === 'decided') {
        // An OCR-decided lead may still switch to its same-set plain/pattern sibling with the
        // same collector number when the lead product lacks the preferred finish (e.g. ME: Ascended Heroes
        // Reverse-Holo-only pattern product -> Holofoil base product under prefer="Holofoil").
        const details = row.details || {};
        const targetCand = row.cands.find((c) => c.ref === targetRef);
        const leadSet = details[lead.ref]?.group_name || lead.tuple?.[4] || '';
        const targetSet = details[targetRef]?.group_name || targetCand?.tuple?.[4] || '';
        const sibs = details[lead.ref]?.variant_siblings || [];
        if (!(leadSet && leadSet === targetSet && sibs.includes(targetRef))) return null;
    }
    row.cands = expandVariantCandidates(row.cands, row.details || {}, 5, targetRef, pack, allow);
    const idx = row.cands.findIndex((c) => c.ref === targetRef);
    if (idx < 0) return null;
    if ('choice' in row) row.choice = idx;
    if (row.autoPrinting && printingKey(row.autoPrinting.label) !== want) delete row.autoPrinting;
    return targetRef;
}

/**
 * True when the hash-ranked top (result.top, anchored on the printing re-rank lead result.best)
 * holds a same-printing-group family: at least two distinct sets within 2.0 bits of the lead.
 * Such a scan (e.g. Battlefield Promotion across WAR/JMP/2X2/J25) is a reviewable printing
 * question, not noise, even when the collector-number OCR did not decide it.
 */
export function printingFamilyTop(pack, result) {
    if (!pack?.refs || !result?.top?.length) return false;
    const leadI = result.best?.i ?? result.top[0].i;
    const lead = pack.refs[leadI];
    if (!lead) return false;
    const leadD = result.top.find((t) => t.i === leadI)?.d ?? result.best?.d;
    if (!Number.isFinite(leadD)) return false;
    const n = pack.n;
    const pg = pack.cl && pack.cl.length >= 2 * n ? pack.cl[n + leadI] : -1;
    const base = baseName(lead[1]);
    const sets = new Set();
    let count = 0;
    for (const t of result.top) {
        const tuple = pack.refs[t.i];
        if (!tuple || !Number.isFinite(t.d) || Math.abs(t.d - leadD) > 2.0) continue;
        const same = (pg >= 0 && pack.cl[n + t.i] === pg) || baseName(tuple[1]) === base;
        if (!same) continue;
        count++;
        sets.add(tuple[3] || tuple[4] || '');
    }
    return count >= 2 && sets.size >= 2;
}

/** Same family test over stored candidates (tuples rebuilt from the pack), for the restore path. */
export function printingFamilyCands(cands) {
    if (!Array.isArray(cands) || cands.length < 2) return false;
    const lead = cands[0];
    const base = baseName(lead?.tuple?.[1] || '');
    if (!base) return false;
    const leadD = Number(lead.d);
    const sets = new Set();
    let count = 0;
    for (const c of cands) {
        if (baseName(c?.tuple?.[1] || '') !== base) continue;
        if (Number.isFinite(leadD) && Number.isFinite(Number(c.d)) && Math.abs(Number(c.d) - leadD) > 2.0) continue;
        count++;
        sets.add(c.tuple?.[3] || c.tuple?.[4] || '');
    }
    return count >= 2 && sets.size >= 2;
}

/**
 * Single pre-display resolution pass shared by desktop and mobile:
 * expands catalog variant siblings and runs visual reprint + Pokemon watermark disambiguation
 * before the resolved card is displayed or persisted.
 * allow (with pack) is a hard constraint: excluded refs are purged on entry and no resolver may
 * introduce or promote one. prefer is a printing override (see switchToPrefer).
 * row.query (image-scan result.query) gates promotions: a ref whose own hash is more than FAR_D worse than
 * the scan's best d is a different picture (e.g. The List's greyscale DBL image) and may not take the lead.
 */
const FAR_D = 3.0;

function farFromScan(row, pack, ref) {
    const q = row?.query;
    if (!q?.lo || !pack?.lo || !Number.isFinite(row.d)) return false;
    const i = getPackIndex(pack)?.byRef.get(ref) ?? -1;
    return i >= 0 && refDistance(pack, q, i) - row.d > FAR_D;
}

export async function resolveScanCands(row, { thumb = null, pack = null, fetchDetails = null, maxCands = 5, allow = null, prefer = '', framePhoto = false } = {}) {
    if (!row?.cands?.length) return row?.cands || [];
    const mask = validAllow(pack, allow);
    if (mask) {
        const chosenRef = row.cands[row.choice || 0]?.ref || '';
        const decidedRef = row.cands.find((c) => c.printingState === 'likely')?.ref || '';
        row.cands = row.cands.filter((c) => candAllowed(pack, mask, c.ref));
        if (!row.cands.length) return row.cands;
        const ci = chosenRef ? row.cands.findIndex((c) => c.ref === chosenRef) : -1;
        row.choice = ci >= 0 ? ci : 0;
        if (decidedRef && !row.cands.some((c) => c.ref === decidedRef) && row.ocrState === 'decided') row.ocrState = undefined;
        if (row.autoPrinting && !row.cands.some((c) => c.ref === row.autoPrinting.ref)) delete row.autoPrinting;
    }
    if (fetchDetails) {
        const need = detailRefs(row.cands, maxCands > 5 ? maxCands : 40).filter((ref) => !row.details?.[ref]);
        if (need.length) {
            const fetched = await fetchDetails(need).catch(() => ({}));
            row.details = { ...(row.details || {}), ...fetched };
        }
    }
    row.cands = expandVariantCandidates(row.cands, row.details || {}, maxCands, '', pack, mask);
    if (!row.touched && row.cands.length) {
        const repRef = await detectReprintRef(row, thumb, pack, { restricted: row?.source === 'phone', allow: mask }).catch(() => null);
        if (repRef && !row.touched && row.cands[0]?.ref !== repRef && !farFromScan(row, pack, repRef)) {
            if (fetchDetails && !row.details?.[repRef]) {
                const more = await fetchDetails([repRef]).catch(() => ({}));
                row.details = { ...(row.details || {}), ...more };
            }
            row.cands = expandVariantCandidates(row.cands, row.details || {}, maxCands, repRef, pack, mask);
            if ('choice' in row) row.choice = 0;
        }
        const wmRef = await detectPokemonVariantRef(row, thumb).catch(() => null);
        if (wmRef && !row.touched && row.cands[0]?.ref !== wmRef && !farFromScan(row, pack, wmRef)) {
            if (fetchDetails && !row.details?.[wmRef]) {
                const more = await fetchDetails([wmRef]).catch(() => ({}));
                row.details = { ...(row.details || {}), ...more };
            }
            row.cands = expandVariantCandidates(row.cands, row.details || {}, maxCands, wmRef, pack, mask);
            if ('choice' in row) row.choice = 0;
        }
        const cosRef = repRef ? null : await detectCosmosRef(row, pack).catch(() => null);
        if (cosRef && !row.touched && row.cands[0]?.ref !== cosRef && !farFromScan(row, pack, cosRef)) {
            if (fetchDetails && !row.details?.[cosRef]) {
                const more = await fetchDetails([cosRef]).catch(() => ({}));
                row.details = { ...(row.details || {}), ...more };
            }
            row.cands = expandVariantCandidates(row.cands, row.details || {}, maxCands, cosRef, pack, mask);
            if ('choice' in row) row.choice = 0;
        }
        const varRes = await detectGameVariant(row, thumb, pack, { framePhoto }).catch(() => null);
        if (varRes && !row.touched) {
            const leadOcr = row.cands[0]?.ocr || '';
            const targetCand = row.cands.find((c) => c.ref === varRes.ref);
            const targetNum = row.details?.[varRes.ref]?.number || targetCand?.tuple?.[2] || '';
            const phoneBlocksPrereleasePromote = row?.source === 'phone' && varRes.reason === 'prerelease_foil_sibling';
            const ocrAllowsSwitch = !phoneBlocksPrereleasePromote && (!leadOcr || !targetNum || listOrCollectorNumbersMatch(leadOcr, targetNum) || varRes.reason === 'retro_frame_chroma');
            if (varRes.changedRef && varRes.ref && !wmRef && ocrAllowsSwitch && row.cands[0]?.ref !== varRes.ref && !farFromScan(row, pack, varRes.ref)) {
                if (fetchDetails && !row.details?.[varRes.ref]) {
                    const more = await fetchDetails([varRes.ref]).catch(() => ({}));
                    row.details = { ...(row.details || {}), ...more };
                }
                row.cands = expandVariantCandidates(row.cands, row.details || {}, maxCands, varRes.ref, pack, mask);
                if ('choice' in row) row.choice = 0;
            }
            if (varRes.printing && !row.autoPrinting) {
                const targetRef = (ocrAllowsSwitch && !farFromScan(row, pack, varRes.ref) ? varRes.ref : '') || row.cands[0]?.ref || '';
                if (targetRef) {
                    row.autoPrinting = {
                        ref: targetRef,
                        label: varRes.printing,
                        conf: varRes.confidence ?? 0.9,
                        reason: varRes.reason || '',
                    };
                }
            }
        }
    }
    if (!row.touched && row.cands.length && printingKey(prefer)) {
        if (row.autoPrinting && printingKey(row.autoPrinting.label) !== printingKey(prefer)) delete row.autoPrinting;
        const switched = switchToPrefer(row, pack, prefer, { allow: mask });
        if (switched && fetchDetails && !row.details?.[switched]) {
            const more = await fetchDetails([switched]).catch(() => ({}));
            row.details = { ...(row.details || {}), ...more };
        }
    }
    return row.cands;
}

/**
 * Applies resolved candidates (`resolveScanCands`) onto a mobile quick-scan view before display/push.
 */
export function applyResolvedToView(view, cands) {
    if (!view || !Array.isArray(cands) || !cands.length) return view;
    const lead = cands[0];
    const winTuple = lead?.tuple;
    const winRef = winTuple?.[0] || lead?.ref || '';
    if (winTuple && winRef && view.ref?.[0] !== winRef) {
        const prevPool = [view.ref, ...(view.siblings || [])].filter((t) => Array.isArray(t) && t[0]);
        const seen = new Set([winRef]);
        const siblings = [];
        for (const t of prevPool) {
            if (!seen.has(t[0])) {
                seen.add(t[0]);
                siblings.push(t);
            }
        }
        for (const s of lead.siblings || []) {
            if (Array.isArray(s) && s[0] && !seen.has(s[0])) {
                seen.add(s[0]);
                siblings.push(s);
            }
        }
        view.ref = winTuple;
        view.siblings = siblings;
        if (view.printing?.cands) {
            const pSeen = new Set([winRef]);
            const pCands = [winTuple];
            for (const t of [...view.printing.cands, ...prevPool]) {
                if (Array.isArray(t) && t[0] && !pSeen.has(t[0]) && view.printing.cands.some((p) => p[0] === t[0])) {
                    pSeen.add(t[0]);
                    pCands.push(t);
                }
            }
            view.printing = { ...view.printing, cands: pCands };
        }
    }
    view.matches = cands.slice(0, 5).map((c) => ({
        ref: c.ref,
        confidence: Math.max(0, Math.min(100, Math.round(Number(c.confidence) || 0))),
        d: Number.isFinite(c.d) ? Math.round(c.d * 1000) / 1000 : null,
    }));
    view.cands = cands;
    return view;
}

const CLOSE_CONF = 15;

function confOf(cand) {
    const n = Number(cand?.confidence ?? cand?.match_pct);
    return Number.isFinite(n) ? n : 0;
}

function artRefs(cand) {
    const refs = new Set();
    if (cand?.ref) refs.add(cand.ref);
    for (const sib of cand?.siblings || []) {
        const ref = Array.isArray(sib) ? sib[0] : sib?.ref;
        if (ref) refs.add(ref);
    }
    return refs;
}

function sharesArt(a, b) {
    const left = artRefs(a);
    for (const ref of artRefs(b)) if (left.has(ref)) return true;
    return false;
}

/** True when this scan still has a near alternative: a small hash gap, an ambiguous printing, or a different card within CLOSE_CONF / TIE_D. */
export function isCloseMatch(row) {
    const cands = row?.cands;
    if (!Array.isArray(cands) || cands.length < 2) return false;
    const lead = cands[0];
    if (row?.printingState === 'ambiguous' || lead?.printingState === 'ambiguous') return true;
    const gap = Number(row?.gap);
    if (Number.isFinite(gap) && gap < GAP_MIN) return true;
    const bestC = confOf(lead);
    const bestD = Number(lead?.d);
    for (let i = 1; i < cands.length; i++) {
        const cand = cands[i];
        if (!cand || sharesArt(lead, cand)) continue;
        if (bestC - confOf(cand) <= CLOSE_CONF) return true;
        const d = Number(cand.d);
        if (Number.isFinite(bestD) && Number.isFinite(d) && d - bestD <= TIE_D) return true;
    }
    return false;
}

/** Walk order is the given row order. Completed and already-sent rows are left in the table and left out of the walk. */
export function walkQueue(rows, scope = 'all') {
    const close = scope === 'close';
    const out = [];
    for (const row of rows || []) {
        if (!row?.cands?.length || row.bucket === 'completed' || row.sent) continue;
        if (close && !isCloseMatch(row)) continue;
        out.push(row);
    }
    return out;
}

/** Where a finished scan belongs before the user has touched it. */
export function routeBucket(scan) {
    const state = scan?.printingState || scan?.cands?.[0]?.printingState || 'single';
    if (scan?.accepted && scan?.cands?.length && state !== 'ambiguous') return 'ready';
    return 'pending';
}

export function toCsv(picked) {
    const rows = [['qty', 'name', 'number', 'set', 'printing', 'sku', 'ref', 'market_price', 'match_pct', 'source']]
        .concat(picked.map((p) => [p.qty, p.name, p.number, p.set, p.printing, p.sku, p.ref, p.price ?? '', p.match_pct ?? '', p.source ?? '']));
    return rows.map((r) => r.map((v) => `"${String(v).replaceAll('"', '""')}"`).join(',')).join('\n');
}

const csvCell = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;

/** A tcgt: game is our catalog, not TCGPlayer, so the TCGPlayer and Manapool columns do not apply. */
export function isTcgtGame(game) {
    return String(game || '').startsWith('tcgt:');
}

export function exportFieldList(game) {
    const tcgt = isTcgtGame(game);
    const fields = [
        ['game', 'Game'], ['set', 'Set'], ['card_name', 'Card Name'], ['card_number', 'Card Number'],
        ['rarity', 'Rarity'], ['variant', 'Variant'], ['condition', 'Condition'], ['language', 'Language'],
        ['quantity', 'Quantity'],
    ];
    if (tcgt) fields.push(['sku', 'SKU']);
    else fields.push(['tcgplayer_id', 'TCGPlayer ID'], ['manapool_id', 'Manapool ID']);
    fields.push(['market_price', 'Market Price']);
    if (!tcgt) fields.push(['manapool_price', 'Manapool Price']);
    fields.push(['device_id', 'Device ID'], ['timestamp', 'Timestamp']);
    return fields.map(([key, label]) => ({ key, label }));
}

export function exportTable(records, keys) {
    const lines = [keys.map(csvCell).join(',')];
    for (const r of records) lines.push(keys.map((k) => csvCell(r[k])).join(','));
    return lines.join('\n');
}

export function exportJson(records, keys) {
    return JSON.stringify(records.map((r) => Object.fromEntries(keys.map((k) => [k, r[k] ?? '']))), null, 2);
}

/**
 * TCGPlayer inventory import. One row per SKU; quantity is summed. The marketplace price is the
 * desk price (My $). Records without a TCGPlayer SKU (including tcgt products) are counted in
 * skipped and left out.
 */
export function tcgplayerCsv(records, gameName) {
    const headers = ['TCGplayer Id', 'Product Line', 'Set Name', 'Product Name', 'Title', 'Number', 'Rarity', 'Condition', 'TCG Market Price', 'TCG Direct Low', 'TCG Low Price With Shipping', 'TCG Low Price', 'Total Quantity', 'Add to Quantity', 'TCG Marketplace Price', 'Photo URL'];
    const groups = new Map();
    let skipped = 0;
    for (const r of records) {
        const id = Number(r.sku_id);
        if (!id || !/^p:/.test(String(r.ref || ''))) { skipped++; continue; }
        const g = groups.get(id) || { qty: 0, price: '' };
        g.qty += Math.max(1, Number(r.quantity) || 1);
        if (g.price === '' && r.price !== '' && r.price != null) g.price = r.price;
        groups.set(id, g);
    }
    const esc = (v) => {
        const s = String(v ?? '');
        return /[",\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
    };
    const lines = [headers.join(',')];
    for (const [id, g] of groups) {
        lines.push([id, esc(gameName), '', '', '', '', '', '', '', '', '', '', '', g.qty, g.price === '' ? '' : String(g.price), ''].join(','));
    }
    return { csv: lines.join('\n'), skipped, count: groups.size };
}
