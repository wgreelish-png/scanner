/**
 * module-graph.js - imports an ES module graph inside a worker through the page's versioned URLs.
 * Workers do not inherit the page import map, so relative imports in core/*.js would resolve to unversioned
 * URLs (cached for a year by Cloudways nginx) and to a second cv.js instance that never sees setCv().
 * Each module is fetched through its versioned URL, its relative import specifiers are rewritten to the
 * object URLs of their (recursively loaded) targets, and every path maps to exactly one module instance.
 *
 * createModuleLoader(map, {origin, fetch, toUrl}) -> load(path) -> Promise<module namespace>
 *   map: page import map `imports` ({'/newscanplus/assets/js/core/cv.js': '...cv.js?v=123', ...})
 *   toUrl(source) -> url   default Blob object URL (tests pass data: URLs)
 * relativeSpecifiers(source) -> string[]
 * Only static `import`/`export ... from './x.js'` and `import './x.js'` statements are rewritten; dynamic
 * import() and import cycles are not supported (core/*.js has neither).
 */
const SPEC = /^(\s*(?:import|export)\b[^'"`;]*?)(['"])(\.{1,2}\/[^'"]+)\2/gm;

export function relativeSpecifiers(source) {
    return [...new Set([...source.matchAll(SPEC)].map((m) => m[3]))];
}

const blobUrl = (source) => URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));

export function createModuleLoader(map, { origin = self.location.origin, fetch: get = fetch, toUrl = blobUrl } = {}) {
    const urls = new Map();

    function urlFor(path) {
        if (!urls.has(path)) urls.set(path, build(path));
        return urls.get(path);
    }

    async function build(path) {
        const res = await get(new URL(map[path] || path, origin).href);
        if (!res.ok) throw new Error(`module ${path}: HTTP ${res.status}`);
        const source = await res.text();
        const deps = new Map(await Promise.all(relativeSpecifiers(source).map(async (spec) => [spec, await urlFor(new URL(spec, origin + path).pathname)])));
        return toUrl(source.replace(SPEC, (all, head, q, spec) => head + q + deps.get(spec) + q));
    }

    return async (path) => import(await urlFor(path));
}
