/**
 * static.js - where packs, ORT/OCR vendor files, and game-variants.json load from.
 *
 *   staticUrl(path) -> string   path on Cloudways ('/newscanplus/packs/...', '/newscanplus/assets/vendor/...',
 *                               '/scan/game-variants.json') rewritten to the static host when one is set, else path
 *
 * The host is globalThis.NSP_STATIC: core/view.php sets it on the page (empty until R2 holds the files), and
 * quickscan-worker.js copies it from its init message. OpenCV builds go through the import map instead.
 */
const PREFIXES = [
    ['/newscanplus/packs/', '/packs/'],
    ['/newscanplus/assets/vendor/', '/vendor/'],
    ['/scan/game-variants.json', '/scan/game-variants.json'],
];

export function staticUrl(path) {
    const base = globalThis.NSP_STATIC;
    if (!base) return path;
    for (const [from, to] of PREFIXES) {
        if (path.startsWith(from)) return base + to + path.slice(from.length);
    }
    return path;
}
