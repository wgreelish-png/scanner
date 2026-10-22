/**
 * layouts.js - collector-corner crops and number parsers (lab reports/ocr.md round 2).
 *
 * Fractions are of the straightened card. The fit is `newscanplus-lab/data/ocr/corners.json`
 * (PP-OCRv4 det on clean 1000w scans, boxes whose recognition contained the catalog number).
 * Generic and Yu-Gi-Oh do not OCR: Yu-Gi-Oh's gold code was 0% (the detector locks the ATK line).
 * Its region is kept for corner NCC only.
 *
 * Game keys: layout names (pokemon, mtg, lorcana, onepiece, yugioh, generic) and the registry
 * keys from core/games.php (`tcgp:1`, `tcgp:3`, `tcgp:68`, `tcgp:71`, `tcgp:2`, `tcgp:85`, `tcgt:6`, `tcgt:7`).
 * `magic` is accepted as `mtg`.
 *
 * Exports
 *   OCR_W, OCR_H                         600x840 warp the corner is cropped from. Never the 200x280 hash warp.
 *   LAYOUTS, layoutFor(game) -> Layout|null
 *   cropPixels(img, region) -> {data, width, height, channels}
 *   normNumber, canonNumber, numberExact, numbersMatch, parseNumber, fractionsIn
 * Layout: { key, region:[x,y,w,h], ocr, numberRe }
 *   ocr false -> do not run the recogniser (yugioh). region null -> nothing (generic).
 */
export const OCR_W = 600;
export const OCR_H = 840;

const FRACTION_RE = String.raw`[0-9]{1,3}/[0-9]{2,3}`;
const COLLECTOR_RE = String.raw`(?<![0-9])[0-9]{2,4}(?![0-9])`;
const ONEPIECE_RE = String.raw`(?:PRB|OP|EB|ST)[0-9]{1,3}-[0-9]{1,3}|P-[0-9]{1,3}|(?<![A-Z])P[0-9]{1,3}-[0-9]{1,3}`;
const YUGIOH_RE = String.raw`[A-Z0-9]{2,10}-[A-Z0-9]{2,12}`;

export const LAYOUTS = {
    pokemon: {
        key: 'pokemon',
        region: [0.0461, 0.9134, 0.282, 0.0815],
        altRegions: [[0.672, 0.9134, 0.282, 0.0815]], // pre-Sun & Moon (BW / XY and older): number at the bottom right
        ocr: true,
        kind: 'fraction',
        numberRe: FRACTION_RE,
    },
    mtg: {
        key: 'mtg',
        region: [0.02, 0.88, 0.55, 0.11],
        altRegions: [[0.02, 0.90, 0.72, 0.09]],
        ocr: true,
        kind: 'collector',
        numberRe: COLLECTOR_RE,
    },
    lorcana: { key: 'lorcana', region: [0.0104, 0.9159, 0.239, 0.0841], altRegions: [[0.01, 0.90, 0.36, 0.095]], ocr: true, kind: 'fraction', numberRe: FRACTION_RE },
    riftbound: { key: 'riftbound', region: [0.02, 0.91, 0.45, 0.08], ocr: true, kind: 'fraction', numberRe: FRACTION_RE },
    onepiece: { key: 'onepiece', region: [0.73, 0.92, 0.24, 0.07], ocr: true, kind: 'onepiece', numberRe: ONEPIECE_RE },
    yugioh: {
        key: 'yugioh',
        region: [0.65, 0.696, 0.26, 0.032],
        altRegions: [
            [0.66, 0.704, 0.25, 0.032], // Standard modern set-code line
            [0.65, 0.715, 0.26, 0.034], // Classic / Series 1-8 under-art set-code line
            [0.65, 0.726, 0.26, 0.034], // Slightly lower classic set-code line
            [0.52, 0.703, 0.28, 0.032], // Link monster under-art set-code line (left of Link-Rating arrow)
            [0.52, 0.714, 0.28, 0.032], // Link monster lower set-code line
            [0.05, 0.612, 0.27, 0.034], // Pendulum monster under-scale left set-code line
            [0.05, 0.626, 0.27, 0.034], // Pendulum monster lower set-code line
        ],
        nccRegion: [0.76, 0.915, 0.24, 0.085],
        ocr: true,
        kind: 'yugioh',
        numberRe: YUGIOH_RE,
    },
};

const ALIAS = {
    pokemon: 'pokemon', 'tcgp:3': 'pokemon', 'tcgp:85': 'pokemon', 'tcgt:6': 'pokemon', 'tcgt:7': 'pokemon',
    mtg: 'mtg', magic: 'mtg', 'tcgp:1': 'mtg',
    lorcana: 'lorcana', 'tcgp:71': 'lorcana',
    riftbound: 'riftbound', 'tcgp:89': 'riftbound',
    onepiece: 'onepiece', 'one-piece': 'onepiece', 'tcgp:68': 'onepiece',
    yugioh: 'yugioh', 'yu-gi-oh': 'yugioh', ygo: 'yugioh', 'tcgp:2': 'yugioh',
};

export function layoutFor(game) {
    const key = ALIAS[String(game || '').trim().toLowerCase()];
    return key ? LAYOUTS[key] : null;
}

export function cropPixels(img, region) {
    const width = img.width, height = img.height;
    const ch = img.channels || (img.data.length / (width * height)) | 0;
    const [x, y, rw, rh] = region;
    const x0 = Math.max(0, Math.min(width - 1, Math.round(width * x)));
    const y0 = Math.max(0, Math.min(height - 1, Math.round(height * y)));
    const x1 = Math.max(x0 + 1, Math.min(width, Math.round(width * (x + rw))));
    const y1 = Math.max(y0 + 1, Math.min(height, Math.round(height * (y + rh))));
    const w = x1 - x0, h = y1 - y0;
    const out = new Uint8Array(w * h * ch);
    const src = img.data;
    for (let row = 0; row < h; row++) {
        const s = ((y0 + row) * width + x0) * ch;
        out.set(src.subarray(s, s + w * ch), row * w * ch);
    }
    return { data: out, width: w, height: h, channels: ch };
}

// Lowercase t / i only: the recogniser reads the pre-M15 copyright-line "107/249" as "t07/249".
const CONFUSABLE = { O: '0', o: '0', I: '1', l: '1', '|': '1', t: '1', i: '1' };

function touchesDigit(ch) {
    return !!ch && (ch === '/' || ch === '-' || (ch >= '0' && ch <= '9'));
}

/** O/0 and l/I/|/t/i -> 1 only when the character touches a digit, slash, or hyphen. Set-code letters stay letters. */
export function normNumber(text) {
    // Replace newlines with '#' only when two digit/confusable runs would otherwise merge across lines ("so1\n045/199", "tendril\n160/271").
    const spaced = String(text || '').replace(/([0-9OolIti|])\s*\n+\s*(?=[0-9OolIti|])/g, '$1#');
    const chars = [...spaced.replace(/\s+/g, '')];
    for (let i = 0; i < chars.length; i++) {
        const repl = CONFUSABLE[chars[i]];
        if (!repl) continue;
        // "t07/249" is a misread 107. A letter at the end of a word ("Coast 20", "tendril 160") is not that misread.
        if ((chars[i] === 't' || chars[i] === 'l' || chars[i] === 'i' || chars[i] === 'o') && /[A-Za-z]/.test(chars[i - 1] || '')) continue;
        if (touchesDigit(chars[i - 1]) || touchesDigit(chars[i + 1])) chars[i] = repl;
    }
    return chars.join('').toUpperCase();
}

/** Exact-match key: case, O/0, l/1, and leading zeros on each numeric run. */
export function canonNumber(text) {
    return normNumber(text).split(/([^0-9]+)/).map((part) => (/^[0-9]+$/.test(part) ? String(parseInt(part, 10)) : part)).join('');
}

export function numberExact(ocrText, gt) {
    const got = canonNumber(ocrText);
    const want = canonNumber(gt);
    if (!got || !want) return false;
    if (got === want) return true;
    let start = 0;
    while (start <= got.length) {
        const i = got.indexOf(want, start);
        if (i < 0) return false;
        const before = i > 0 ? got[i - 1] : '';
        const after = i + want.length < got.length ? got[i + want.length] : '';
        const digit = (c) => c >= '0' && c <= '9';
        if ((!before || !digit(before)) && (!after || !digit(after))) return true;
        start = i + 1;
    }
    return false;
}

/** Same collector number. A fraction matches a plain number by its numerator ('017/030' ~ '17'). */
export function numbersMatch(a, b) {
    const x = canonNumber(a), y = canonNumber(b);
    if (!x || !y) return false;
    if (x === y) return true;
    if (x.includes('/') === y.includes('/')) return false;
    const num = (s) => (s.includes('/') ? s.slice(0, s.indexOf('/')) : s);
    return num(x) === num(y);
}

/** Every fraction in the text, canonical ('006/012' -> '6/12'), including ones bestFraction rejects as noise. */
export function fractionsIn(text) {
    return [...new Set((normNumber(text).match(new RegExp(FRACTION_RE, 'g')) || []).map(canonNumber))];
}

function bestFraction(text) {
    const n = normNumber(text);
    const fracs = n.match(new RegExp(FRACTION_RE, 'g')) || [];
    let best = '', score = -999;
    for (const frac of fracs) {
        const [num, den] = frac.split('/');
        const ni = parseInt(num, 10), di = parseInt(den, 10);
        let s = (di >= 20 && di <= 999) ? 25 : -15;
        if (ni >= 1 && ni <= 500) s += 8;
        if (di <= 12 && ni <= 12) s -= 12;
        if (s > score) { best = frac; score = s; }
    }
    return best && score >= 15 ? canonNumber(best) : '';
}

// MTG collector line: modern "M 0375" (rarity letter + number); 2015-2019 "008/016 R" (number / set size: the
// numerator is the collector number); else the last 2-4 digit run that is not a year. The set-code token before
// the language ("J22 · EN", "M21 • EN") is dropped first: normNumber joins lines, and its digits read as a number.
const SET_LANG_RE = /(?<![A-Za-z0-9])[A-Za-z0-9]{2,5}\s*[·•*.,:;-]?\s*(?:EN|DE|FR|IT|ES|SP|PT|JA|JP|KO|KR|RU|CS|CT|PH|ZHS|ZHT)(?![A-Za-z])/g;
// Rarity-led modern line whose set code was not read ("M 0375 EN", or a planeswalker loyalty
// digit merged in: "4 M 0375 EN"). Exactly 4 digits, so a bare set size ("016 EN") still abstains.
const RARITY_LED_LANG_RE = /(?<![A-Za-z0-9])[MRULC]\s*([0-9]{4})\s*[·•*.,:;-]?\s*(?:EN|DE|FR|IT|ES|SP|PT|JA|JP|KO|KR|RU|CS|CT|PH|ZHS|ZHT)(?![A-Za-z])/;

function bestCollector(text) {
    const year = /^(?:19|20)[0-9]{2}$/;
    const led = String(text || '').match(RARITY_LED_LANG_RE);
    if (led && !year.test(led[1])) return canonNumber(led[1]);
    // Normalize punctured/confusable rarity-led runs ("c.0109", "c0oB9", "091/27sU") before stripping set+lang.
    const raw = String(text || '')
        .replace(SET_LANG_RE, '#')
        .replace(/(?<![A-Za-z0-9])([MRULC])[\s.,:;-]+(?=[0O][0-9OolIti|BbSs]{2,3})/gi, '$1')
        .replace(/(?<=[0-9OolIti])[Bb](?=[0-9OolIti])/g, '8')
        .replace(/(?<=[0-9OolIti])[sS](?=[0-9OolItiA-Za-z])/g, '5');
    const n = normNumber(raw);
    // A rarity letter glued to a 4-digit year ("c 2022" from the copyright line) is not a collector number.
    const rarity = [...n.matchAll(/(?<![A-Z0-9])[MRULC]0*([0-9]{2,4})(?![0-9])/g)].filter((m) => !year.test(m[1]));
    if (rarity.length) return canonNumber(rarity[rarity.length - 1][1]);
    const frac = [...n.matchAll(/(?<![0-9])([0-9]{1,4})\/([0-9]{1,4})(?![0-9])/g)];
    if (frac.length) return canonNumber(frac[frac.length - 1][1]);
    const nums = [...n.matchAll(new RegExp(COLLECTOR_RE, 'g'))].map((m) => m[0]).filter((m) => !year.test(m));
    return nums.length ? canonNumber(nums[nums.length - 1]) : '';
}

function bestOnePiece(text) {
    const n = normNumber(text);
    const hits = [];
    for (const m of n.matchAll(new RegExp(ONEPIECE_RE, 'g'))) {
        let code = m[0];
        if (/^P[0-9]/.test(code)) code = 'O' + code;
        hits.push(code);
    }
    if (!hits.length) return '';
    hits.sort((a, b) => b.length - a.length);
    return canonNumber(hits[0]);
}

function bestCode(text, source) {
    const all = normNumber(text).match(new RegExp(source, 'g')) || [];
    if (!all.length) return '';
    all.sort((a, b) => b.length - a.length);
    return canonNumber(all[0]);
}

/** Catalog-comparable collector number, or '' when the text has none. */
export function parseNumber(text, game) {
    const layout = typeof game === 'string' || game == null ? layoutFor(game) : game;
    if (!layout) return '';
    if (layout.kind === 'fraction') return bestFraction(text);
    if (layout.kind === 'collector') return bestCollector(text);
    if (layout.kind === 'onepiece') return bestOnePiece(text);
    if (layout.kind === 'yugioh') return bestCode(text, YUGIOH_RE);
    return '';
}
