/**
 * pack.js - per-game client hash packs (formats: scripts/build-pack.php; v2 per-set shards, v1 legacy).
 *
 * Exports
 *   loadPackIndex() -> Promise<{games: {key: {name, n, bin_bytes, meta_bytes, v2?: {manifest, shards, ...}, ...}}}>
 *     Network first (no-store). If index.json is unreachable, the last index seen is served from IndexedDB
 *     (result.offline = true); throws only when nothing was ever cached.
 *   loadPack(gameKey, onProgress?(loaded, total, stats?), {groups?: number[]}) -> Promise<Pack>
 *     groups: optional set filter (group_ids); only those sets are downloaded/assembled (v2 packs only).
 *     onProgress counts bytes still to download. The optional stats object is
 *       {downloaded, total, hashBytes, metaBytes, hashShards, metaShards, cachedHashShards, cachedMetaShards,
 *        upToDate, label, cache, storage}
 *     label is "up to date · 0 MB" when this call fetched nothing, otherwise "downloaded N MB · …".
 *     cache is 'ok', 'failed' (IndexedDB rejected a write; this load still finishes), or 'unavailable'.
 *     storage is {persisted, reason} from navigator.storage.persist(); a denial does not fail the load.
 *     When the cache already held the pack, loaded/total are (1, 1) so an older progress bar still completes.
 *   listPackGroups(gameKey) -> Promise<Array<{group_id, name, abbr, n, bytes, meta_bytes}>>   [] for v1 packs
 *   parsePack(game, buf, refs) -> Pack   (v1 NSPK buffer)
 *
 * Pack: {game, ver, n, lo: Uint32Array(n*36), hi: Uint8Array(n*36), cl: Int32Array(2n), pg, refs, groups, format}
 *   hi is unpacked to one 4-bit value per block. refs[i] = [ref, name, number, group_abbr, group_name, rarity,
 *   image, variants]. cl[0..n) = art cluster id (-1 none). v2 shards store each ref's own art_cluster (smallest ref_id
 *   of that cluster, singletons included) so the id compares across sets and does not renumber when another set
 *   changes; assemble() then sets clusters with a single loaded ref to -1, as v1 did. cl[n..2n) = printing group, a stable 31-bit hash of the normalized base name (-1 if the name is
 *   empty; all -1 for v1 packs). pg is a view of that second half. Compare ids for equality only.
 *   The printing groups ride in cl so the existing worker plumbing ({n, lo, hi, cl}) carries them; index cl only
 *   below n for clusters. groups = loaded group_ids (v2) or null (v1). format = 1 | 2.
 *
 * Cache (IndexedDB 'nsp-packs'/'packs'): v2 files are keyed by their content-addressed name ('h:'/'m:'/'M:' +
 * path), so a rebuild that leaves a set unchanged costs nothing; only missing shards are fetched. After a
 * complete load, entries of that game no longer listed by its manifest are dropped, and 'cur:{game}' remembers
 * the manifest so a failed download falls back to the last complete pack. v1 packs are cached per game+version.
 */

import { staticUrl } from './static.js';

const BASE = '/newscanplus/packs/';
const DB_NAME = 'nsp-packs';

function packBase() {
    return staticUrl(BASE);
}
const STORE = 'packs';
const FETCH_PARALLEL = 12;

// Values whose IndexedDB write failed. The load still assembles from here; the next visit downloads again.
const sessionCache = new Map();

function emptyStats() {
    return {
        downloaded: 0, total: 0, hashBytes: 0, metaBytes: 0, hashShards: 0, metaShards: 0,
        cachedHashShards: 0, cachedMetaShards: 0, upToDate: false, label: '', cache: 'ok', storage: null,
    };
}

function formatBytes(n) {
    if (!n) return '0 MB';
    const mb = n / 1048576;
    return mb >= 0.1 ? `${mb.toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`;
}

function finishStats(stats) {
    stats.downloaded = stats.hashBytes + stats.metaBytes;
    stats.upToDate = stats.downloaded === 0;
    if (stats.downloaded === 0) {
        stats.label = 'up to date · 0 MB';
        return;
    }
    const parts = [];
    if (stats.hashShards) parts.push(`${stats.hashShards} hash`);
    if (stats.metaShards) parts.push(`${stats.metaShards} meta`);
    stats.label = parts.length ? `downloaded ${formatBytes(stats.downloaded)} · ${parts.join(', ')}` : `downloaded ${formatBytes(stats.downloaded)}`;
}

async function requestPersistence() {
    const storage = globalThis.navigator?.storage;
    if (!storage?.persist) return { persisted: false, reason: 'unsupported' };
    try {
        if (typeof storage.persisted === 'function' && await storage.persisted()) return { persisted: true, reason: 'already' };
        const ok = await storage.persist();
        return { persisted: !!ok, reason: ok ? 'granted' : 'denied' };
    } catch {
        return { persisted: false, reason: 'error' };
    }
}

async function remember(key, value) {
    try {
        await idbPut(key, value);
        return true;
    } catch {
        sessionCache.set(key, value);
        return false;
    }
}

export async function loadPackIndex() {
    const primary = packBase() + 'index.json';
    try {
        const res = await fetch(primary, { cache: 'no-store' });
        if (!res.ok) throw new Error(`pack index ${res.status}`);
        const index = await res.json();
        idbPut('index', index).catch(() => {});
        return index;
    } catch (err) {
        // The static host can be unreachable while Cloudways is fine (content
        // blocker, R2/edge blip): retry the same file first-party before
        // falling back to the last cached index.
        const sameOrigin = `${BASE}index.json`;
        if (primary !== sameOrigin) {
            try {
                const res = await fetch(sameOrigin, { cache: 'no-store' });
                if (!res.ok) throw new Error(`pack index ${res.status}`);
                const index = await res.json();
                idbPut('index', index).catch(() => {});
                return index;
            } catch { /* fall through to the cached index */ }
        }
        const cached = await idbGet('index').catch(() => null);
        if (!cached) throw err;
        return { ...cached, offline: true };
    }
}

export async function loadPack(gameKey, onProgress, { groups = null } = {}) {
    const index = await loadPackIndex();
    const entry = index.games?.[gameKey];
    if (entry?.v2?.manifest) {
        try {
            return await loadV2(gameKey, entry.v2.manifest, onProgress, groups);
        } catch (err) {
            const last = await idbGet(`cur:${gameKey}`).catch(() => null);
            if (!last || last === entry.v2.manifest) throw err;
            console.warn('[pack] using the last complete pack:', err);
            return loadV2(gameKey, last, onProgress, groups, { cacheOnly: true });
        }
    }
    if (!entry) {
        const last = await idbGet(`cur:${gameKey}`).catch(() => null);
        if (last) return loadV2(gameKey, last, onProgress, groups, { cacheOnly: true });
        throw new Error('no pack for this game yet');
    }
    return loadV1(gameKey, entry, onProgress);
}

export async function listPackGroups(gameKey) {
    const index = await loadPackIndex();
    const path = index.games?.[gameKey]?.v2?.manifest;
    if (!path) return [];
    const manifest = await getManifest(path, false);
    return manifest.shards.map(({ group_id, name, abbr, n, bytes, meta_bytes }) => ({ group_id, name, abbr, n, bytes, meta_bytes }));
}

export function parsePack(game, buf, refs) {
    return parseV1(game, buf, refs);
}

// ---------------------------------------------------------------- v2

async function getManifest(path, cacheOnly) {
    const key = `M:${path}`;
    const cached = await idbGet(key).catch(() => null);
    if (cached) return cached;
    if (cacheOnly) throw new Error('pack not cached');
    const manifest = JSON.parse(new TextDecoder().decode(await gunzipIfNeeded(await fetchBytes(packBase() + path))));
    if (manifest.v !== 2 || !Array.isArray(manifest.shards)) throw new Error('bad pack manifest');
    await idbPut(key, manifest).catch(() => {});
    return manifest;
}

async function loadV2(gameKey, manifestPath, onProgress, groups, { cacheOnly = false } = {}) {
    const persistP = requestPersistence();
    const stats = emptyStats();
    const manifest = await getManifest(manifestPath, cacheOnly);
    const dir = manifestPath.slice(0, manifestPath.lastIndexOf('/') + 1);
    const want = groups ? new Set(groups.map(Number)) : null;
    const shards = manifest.shards.filter((s) => !want || want.has(Number(s.group_id)));
    if (!shards.length) throw new Error('no cards in the chosen sets');

    const hKey = (s) => `h:${dir}${s.hash}`;
    const mKey = (s) => `m:${dir}${s.meta}`;
    let listed = null;
    try {
        listed = await idbKeys();
    } catch {
        stats.cache = 'unavailable';
    }
    const have = new Set(listed ?? []);
    if (listed === null) for (const k of sessionCache.keys()) have.add(k);
    const jobs = [];
    for (const s of shards) {
        if (!have.has(hKey(s))) jobs.push({ key: hKey(s), url: `${packBase()}${dir}${s.hash}.bin`, bytes: s.bytes, kind: 'h' });
        if (!have.has(mKey(s))) jobs.push({ key: mKey(s), url: `${packBase()}${dir}${s.meta}.json.gz`, bytes: s.meta_bytes, kind: 'm' });
    }
    stats.cachedHashShards = shards.length - jobs.filter((j) => j.kind === 'h').length;
    stats.cachedMetaShards = shards.length - jobs.filter((j) => j.kind === 'm').length;
    if (jobs.length && cacheOnly) throw new Error('pack not cached');
    await runJobs(jobs, onProgress, stats);

    let got;
    try {
        got = await idbGetMany(shards.flatMap((s) => [hKey(s), mKey(s)]));
    } catch {
        got = shards.flatMap(() => [null, null]);
        stats.cache = 'unavailable';
    }
    const parts = [];
    for (const [j, s] of shards.entries()) {
        let bin = got[2 * j] ?? sessionCache.get(hKey(s)) ?? null;
        let meta = got[2 * j + 1] ?? sessionCache.get(mKey(s)) ?? null;
        if (!bin || !meta || shardKeysum(bin) !== meta.k) {
            if (cacheOnly) throw new Error('pack cache damaged');
            // Cache evicted or damaged between the key listing and now: refetch this pair once.
            await runJobs([
                { key: hKey(s), url: `${packBase()}${dir}${s.hash}.bin`, bytes: s.bytes, kind: 'h' },
                { key: mKey(s), url: `${packBase()}${dir}${s.meta}.json.gz`, bytes: s.meta_bytes, kind: 'm' },
            ], onProgress, stats);
            bin = sessionCache.get(hKey(s)) ?? await idbGet(hKey(s)).catch(() => null);
            meta = sessionCache.get(mKey(s)) ?? await idbGet(mKey(s)).catch(() => null);
            if (!bin || !meta || shardKeysum(bin) !== meta.k) throw new Error('pack meta mismatch');
        }
        parts.push({ bin, refs: meta.refs, group: Number(s.group_id) });
    }
    stats.storage = await persistP;
    finishStats(stats);
    if (stats.downloaded === 0) onProgress?.(1, 1, stats);
    else onProgress?.(stats.downloaded, Math.max(stats.downloaded, stats.total), stats);
    const pack = assemble(gameKey, manifestPath, parts);

    if (!want) {
        idbPut(`cur:${gameKey}`, manifestPath).catch(() => {});
        idbPruneV2(dir, manifestPath, manifest, gameKey).catch(() => {});
    }
    return pack;
}

async function runJobs(jobs, onProgress, stats) {
    if (!jobs.length) return;
    const total = jobs.reduce((a, j) => a + j.bytes, 0);
    stats.total += total;
    const done = new Map();
    // Set on the first failure so the other workers stop fetching and stop reporting progress after the reject.
    let failed = false;
    const report = () => {
        if (failed) return;
        const loaded = [...done.values()].reduce((a, b) => a + b, 0);
        finishStats(stats);
        if (loaded > 0 && stats.downloaded === 0) {
            stats.upToDate = false;
            stats.label = `downloaded ${formatBytes(loaded)}`;
        }
        onProgress?.(loaded, total, stats);
    };
    let next = 0;
    async function worker() {
        while (!failed && next < jobs.length) {
            const job = jobs[next++];
            const bytes = await fetchBytes(job.url, (n) => { done.set(job.key, n); report(); });
            if (failed) return;
            let value;
            if (job.kind === 'h') {
                value = bytes.buffer.byteLength === bytes.length ? bytes.buffer : bytes.slice().buffer;
                checkShard(value);
                stats.hashBytes += bytes.length;
                stats.hashShards += 1;
            } else {
                const meta = JSON.parse(new TextDecoder().decode(await gunzipIfNeeded(bytes)));
                value = { k: meta.k, refs: meta.refs };
                stats.metaBytes += bytes.length;
                stats.metaShards += 1;
            }
            stats.downloaded = stats.hashBytes + stats.metaBytes;
            if (!(await remember(job.key, value))) stats.cache = 'failed';
        }
    }
    const guarded = () => worker().catch((err) => { failed = true; throw err; });
    await Promise.all(Array.from({ length: Math.min(FETCH_PARALLEL, jobs.length) }, guarded));
}

function checkShard(buf) {
    const magic = String.fromCharCode(...new Uint8Array(buf, 0, 4));
    if (magic !== 'NSPS' || new DataView(buf).getUint32(4, true) !== 2) throw new Error('bad pack shard');
}

function shardKeysum(buf) {
    return new DataView(buf).getUint32(16, true);
}

function shardLayout(buf) {
    const n = new DataView(buf).getUint32(8, true);
    let off = 24 + n * 144 + n * 18;
    off += (4 - (off % 4)) % 4;
    return { n, lo: 24, hi: 24 + n * 144, cl: off, pg: off + n * 4 };
}

const CRC32_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
        t[i] = c >>> 0;
    }
    return t;
})();

function nameGroupId(name) {
    const base = String(name || '')
        .replace(/\s*\([^)]*\)/gu, '')
        .replace(/\s+-\s+(?:[^-]*\d[^-]*|"[^"]*")$/u, '')
        .replace(/\s+/gu, ' ')
        .trim()
        .toLowerCase();
    if (!base) return -1;
    const bytes = new TextEncoder().encode(base);
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC32_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    return ((c ^ 0xffffffff) >>> 0) & 0x7fffffff;
}

function assemble(game, ver, parts) {
    let n = 0;
    for (const p of parts) {
        const sn = new DataView(p.bin).getUint32(8, true);
        if (sn !== p.refs.length) throw new Error('pack meta mismatch');
        n += sn;
    }
    const lo = new Uint32Array(n * 36);
    const hi = new Uint8Array(n * 36);
    const cl = new Int32Array(2 * n);
    const refs = new Array(n);
    let at = 0;
    for (const p of parts) {
        const L = shardLayout(p.bin);
        lo.set(new Uint32Array(p.bin, L.lo, L.n * 36), at * 36);
        const packed = new Uint8Array(p.bin, L.hi, L.n * 18);
        for (let i = 0, o = at * 36; i < L.n * 18; i++) {
            hi[o + 2 * i] = packed[i] & 0xf;
            hi[o + 2 * i + 1] = packed[i] >> 4;
        }
        cl.set(new Int32Array(p.bin, L.cl, L.n), at);
        cl.set(new Int32Array(p.bin, L.pg, L.n), n + at);
        for (let i = 0; i < L.n; i++) {
            const r = p.refs[i];
            refs[at + i] = r;
            if (typeof r?.[1] === 'string' && /\s+-\s+"[^"]*"$/u.test(r[1])) {
                cl[n + at + i] = nameGroupId(r[1]);
            }
        }
        at += L.n;
    }
    // Shards store every ref's own art_cluster id; consumers read cl < 0 as "no same-art siblings" (v1 semantics).
    const size = new Map();
    for (let i = 0; i < n; i++) if (cl[i] >= 0) size.set(cl[i], (size.get(cl[i]) || 0) + 1);
    for (let i = 0; i < n; i++) if (cl[i] >= 0 && size.get(cl[i]) === 1) cl[i] = -1;
    return { game, ver, n, lo, hi, cl, pg: cl.subarray(n), refs, groups: parts.map((p) => p.group), format: 2 };
}

// ---------------------------------------------------------------- v1

async function loadV1(gameKey, entry, onProgress) {
    const persistP = requestPersistence();
    const stats = emptyStats();
    const key = `${gameKey}@${entry.ver}`;
    let cached = await idbGet(key).catch(() => null);
    if (!cached) {
        const total = entry.bin_bytes + entry.meta_bytes;
        stats.total = total;
        let metaLoaded = 0;
        const [bin, metaBytes] = await Promise.all([
            fetchBytes(packBase() + entry.bin, (n) => onProgress?.(n + metaLoaded, total, stats)),
            fetchBytes(packBase() + entry.meta, (n) => { metaLoaded = n; }),
        ]);
        const meta = JSON.parse(new TextDecoder().decode(await gunzipIfNeeded(metaBytes)));
        cached = { bin: bin.buffer, refs: meta.refs };
        stats.hashBytes = bin.length;
        stats.metaBytes = metaBytes.length;
        stats.hashShards = 1;
        stats.metaShards = 1;
        if (!(await remember(key, cached))) stats.cache = 'failed';
        await idbPruneV1(gameKey, key).catch(() => {});
    }
    stats.storage = await persistP;
    finishStats(stats);
    if (stats.downloaded === 0) onProgress?.(1, 1, stats);
    else onProgress?.(stats.downloaded, Math.max(stats.downloaded, stats.total), stats);
    return parseV1(gameKey, cached.bin, cached.refs);
}

function parseV1(game, buf, refs) {
    const head = new DataView(buf, 0, 16);
    const magic = String.fromCharCode(...new Uint8Array(buf, 0, 4));
    if (magic !== 'NSPK' || head.getUint32(4, true) !== 1) throw new Error('bad pack');
    const n = head.getUint32(8, true);
    const ver = head.getUint32(12, true);
    const lo = new Uint32Array(buf, 16, n * 36);
    const packed = new Uint8Array(buf, 16 + n * 144, n * 18);
    const hi = new Uint8Array(n * 36);
    for (let i = 0; i < n * 18; i++) {
        hi[2 * i] = packed[i] & 0xf;
        hi[2 * i + 1] = packed[i] >> 4;
    }
    let off = 16 + n * 144 + n * 18;
    off += (4 - (off % 4)) % 4;
    if (refs.length !== n) throw new Error('pack meta mismatch');
    const cl = new Int32Array(2 * n).fill(-1);
    cl.set(new Int32Array(buf, off, n));
    return { game, ver, n, lo, hi, cl, pg: cl.subarray(n), refs, groups: null, format: 1 };
}

// ---------------------------------------------------------------- io

const FETCH_TRIES = 3;

async function fetchBytes(url, onBytes) {
    for (let attempt = 1; ; attempt++) {
        try {
            return await fetchBytesOnce(url, onBytes);
        } catch (err) {
            // Network errors (TypeError, including a CORS-less edge error page), 429, and 5xx are worth retrying.
            const status = err.status ?? 0;
            const transient = !status || status === 429 || status >= 500;
            if (!transient || attempt >= FETCH_TRIES) throw err;
            onBytes?.(0);
            await new Promise((r) => setTimeout(r, 400 * attempt));
        }
    }
}

async function fetchBytesOnce(url, onBytes) {
    const res = await fetch(url);
    if (!res.ok) throw Object.assign(new Error(`${url} ${res.status}`), { status: res.status });
    if (!res.body?.getReader) return new Uint8Array(await res.arrayBuffer());
    const reader = res.body.getReader();
    const chunks = [];
    let size = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        size += value.length;
        onBytes?.(size);
    }
    const out = new Uint8Array(size);
    let pos = 0;
    for (const c of chunks) { out.set(c, pos); pos += c.length; }
    return out;
}

async function gunzipIfNeeded(bytes) {
    if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}

let dbP = null;
function idb() {
    dbP ||= new Promise((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => req.result.createObjectStore(STORE);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => { dbP = null; reject(req.error); };
    });
    return dbP;
}

async function idbGet(key) {
    const db = await idb();
    return new Promise((resolve, reject) => {
        const req = db.transaction(STORE).objectStore(STORE).get(key);
        req.onsuccess = () => resolve(req.result ?? null);
        req.onerror = () => reject(req.error);
    });
}

async function idbGetMany(keys) {
    const db = await idb();
    return new Promise((resolve, reject) => {
        const store = db.transaction(STORE).objectStore(STORE);
        const out = new Array(keys.length).fill(null);
        let left = keys.length;
        if (!left) resolve(out);
        keys.forEach((k, i) => {
            const req = store.get(k);
            req.onsuccess = () => { out[i] = req.result ?? null; if (--left === 0) resolve(out); };
            req.onerror = () => reject(req.error);
        });
    });
}

async function idbKeys() {
    const db = await idb();
    return new Promise((resolve, reject) => {
        const req = db.transaction(STORE).objectStore(STORE).getAllKeys();
        req.onsuccess = () => resolve(req.result.map(String));
        req.onerror = () => reject(req.error);
    });
}

async function idbPut(key, value) {
    const db = await idb();
    return new Promise((resolve, reject) => {
        const tx = db.transaction(STORE, 'readwrite');
        tx.objectStore(STORE).put(value, key);
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
    });
}

async function idbDelete(test) {
    const db = await idb();
    return new Promise((resolve) => {
        const tx = db.transaction(STORE, 'readwrite');
        const store = tx.objectStore(STORE);
        const req = store.getAllKeys();
        req.onsuccess = () => { for (const k of req.result) if (test(String(k))) store.delete(k); };
        tx.oncomplete = resolve;
        tx.onerror = resolve;
    });
}

function idbPruneV1(gameKey, keepKey) {
    return idbDelete((k) => k.startsWith(gameKey + '@') && k !== keepKey);
}

function idbPruneV2(dir, manifestPath, manifest, gameKey) {
    const keep = new Set([`M:${manifestPath}`]);
    for (const s of manifest.shards) {
        keep.add(`h:${dir}${s.hash}`);
        keep.add(`m:${dir}${s.meta}`);
    }
    const prefixes = ['h:', 'm:', 'M:'].map((p) => p + dir);
    return idbDelete((k) => (prefixes.some((p) => k.startsWith(p)) && !keep.has(k)) || k.startsWith(gameKey + '@'));
}
