/**
 * setrank.js - order printings the hash cannot tell apart (same art, or an ambiguous printing group) so the
 * everyday printing comes first and promos, misc versions, Summer Magic, The List, Secret Lair and similar rank
 * down. Pack tuple: [ref, name, number, group_abbr, group_name, rarity, image, variants].
 *
 * setPenalty(tuple) -> 0..6     0 = regular set; 4 = rare/promo-style set; +2 variant set; +1 variant name
 * rankTies(pack, ids) -> ids    stable sort by (penalty, lowest NM price, input order)
 */
const RARE_SET = new RegExp([
    'promos?', 'misc', 'miscellaneous', 'summer magic', 'edgar', 'pre-?release', 'judge', 'arena', 'the list',
    'list reprints', 'mystery booster', 'secret lair', 'world championship', 'collector\'?s edition',
    'international edition', 'art series', 'oversized', 'gift', 'playtest', 'test print', 'heroes of the realm',
    'celebrations?', 'anniversary', 'unique', 'jumbo', 'black star', 'championship', 'launch party', 'league',
    'friday night', 'fnm', 'buy-?a-?box', 'game day', 'media insert', 'store', 'staff', 'convention', 'sample',
    'prize pack', 'battle academy', 'deck exclusives?', 'blister exclusives?', 'trading card game classic',
    'trainer kit', 'starter commander',
].map((w) => `\\b${w}\\b`).join('|'), 'i');

const VARIANT_SET = new RegExp([
    'foreign', 'black border', 'universes beyond', 'jumpstart', 'duel decks?', 'from the vault', 'masterpiece',
    'expeditions', 'inventions', 'invocations', 'special guests', 'premium deck', 'spellbook', 'box topper',
    'showcase', 'extended art', 'borderless', 'full art', 'alt(ernate)? art', 'etched', 'retro', 'textured',
    'serialized', 'galaxy', 'shattered glass', 'japanese', 'chinese', 'korean',
].map((w) => `\\b${w}\\b`).join('|'), 'i');

export function setPenalty(tuple) {
    if (!tuple) return 0;
    const set = `${tuple[4] || ''} ${tuple[3] || ''}`;
    const name = String(tuple[1] || '');
    let p = 0;
    if (RARE_SET.test(set)) p += 4;
    else if (VARIANT_SET.test(set)) p += 2;
    const hasNonNumParen = /\((?!\d+\))[^)]*\)/.test(name);
    if (hasNonNumParen && !/\btrick or trade\b/i.test(set)) p += 1;
    else if (VARIANT_SET.test(name)) p += 1;
    return p;
}

function lowestNm(tuple) {
    let lo = Infinity;
    for (const v of tuple?.[7] || []) if (Number.isFinite(v?.nm) && v.nm < lo) lo = v.nm;
    return lo;
}

export function rankTies(pack, ids) {
    return ids
        .map((i, n) => ({ i, n, p: setPenalty(pack.refs[i]), nm: lowestNm(pack.refs[i]) }))
        .sort((a, b) => a.p - b.p || a.nm - b.nm || a.n - b.n)
        .map((x) => x.i);
}
