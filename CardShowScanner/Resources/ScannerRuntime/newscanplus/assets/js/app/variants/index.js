/**
 * variants/index.js — Per-game single-image variant, finish & reprint resolver registry.
 *
 * Each game has its own dedicated module (`mtg.js`, `pokemon.js`, `yugioh.js`, `lorcana.js`,
 * `riftbound.js`, `gundam.js`, `onepiece.js`) and is invoked when scanning that game.
 */

import { resolveMtgVariant, GAME_KEY as MTG_KEY } from './mtg.js';
import { resolvePokemonVariant, GAME_KEY as POKEMON_KEY } from './pokemon.js';
import { resolveYugiohVariant, GAME_KEY as YUGIOH_KEY } from './yugioh.js';
import { resolveLorcanaVariant, GAME_KEY as LORCANA_KEY } from './lorcana.js';
import { resolveRiftboundVariant, GAME_KEY as RIFTBOUND_KEY } from './riftbound.js';
import { resolveGundamVariant, GAME_KEY as GUNDAM_KEY } from './gundam.js';
import { resolveOnePieceVariant, GAME_KEY as ONEPIECE_KEY } from './onepiece.js';
import { resolveSorceryVariant, GAME_KEY as SORCERY_KEY } from './sorcery.js';

export const GAME_RESOLVERS = {
    [MTG_KEY]: resolveMtgVariant,
    [POKEMON_KEY]: resolvePokemonVariant,
    [YUGIOH_KEY]: resolveYugiohVariant,
    [LORCANA_KEY]: resolveLorcanaVariant,
    [RIFTBOUND_KEY]: resolveRiftboundVariant,
    [GUNDAM_KEY]: resolveGundamVariant,
    [ONEPIECE_KEY]: resolveOnePieceVariant,
    [SORCERY_KEY]: resolveSorceryVariant,
};

/**
 * Dispatch variant/sibling detection to the dedicated per-game module.
 *
 * @param {string} gameKey - e.g. `'tcgp:1'`, `'tcgp:3'`, `'tcgp:2'`, `'tcgp:71'`, `'tcgp:89'`, `'tcgp:86'`, `'tcgp:68'`
 * @param {object} input - `{ scanRgba, scanW, scanH, candidates, refImages }`
 */
export function resolveVariantForGame(gameKey, input) {
    const fn = GAME_RESOLVERS[String(gameKey || '')];
    if (!fn) return null;
    return fn(input);
}

export {
    resolveMtgVariant,
    resolvePokemonVariant,
    resolveYugiohVariant,
    resolveLorcanaVariant,
    resolveRiftboundVariant,
    resolveGundamVariant,
    resolveOnePieceVariant,
    resolveSorceryVariant,
};
