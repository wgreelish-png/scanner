const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../CardShowScanner/Resources/ScannerRuntime/newscanplus/assets/js/core/pack.js'), 'utf8');
const BASE = '/newscanplus/packs/';
const game = 'tcgp:3';
const manifestPath = 'pokemon/manifest-1.json';

// Keep the store across VM contexts, representing a persistent database across page reloads.
function indexedDBStore({ writesFail = false } = {}) {
  const values = new Map();
  const db = {
    createObjectStore() {},
    transaction() {
      const tx = {};
      const request = action => {
        const req = {};
        queueMicrotask(() => {
          try { req.result = action(); req.onsuccess?.(); }
          catch (error) { req.error = tx.error = error; req.onerror?.(); tx.onerror?.(); }
          queueMicrotask(() => tx.oncomplete?.());
        });
        return req;
      };
      tx.objectStore = () => ({
        get: key => request(() => values.has(key) ? structuredClone(values.get(key)) : undefined),
        getAllKeys: () => request(() => [...values.keys()]),
        put: (value, key) => request(() => {
          if (writesFail) throw new Error('Storage full');
          values.set(key, structuredClone(value));
        }),
        delete: key => request(() => values.delete(key))
      });
      return tx;
    }
  };
  return { values, open() {
    const req = {};
    queueMicrotask(() => { req.result = db; req.onupgradeneeded?.(); req.onsuccess?.(); });
    return req;
  } };
}
function fixture(version = 1) {
  const versionManifest = `pokemon/manifest-${version}.json`;
  const bin = new ArrayBuffer(196), view = new DataView(bin);
  new Uint8Array(bin, 0, 4).set(Buffer.from('NSPS'));
  view.setUint32(4, 2, true); view.setUint32(8, 1, true); view.setUint32(16, 321, true);
  view.setInt32(188, -1, true); view.setInt32(192, -1, true);
  const refs = [['p:123', 'Test card', '1', 'SET', 'Test set', '', '', []]];
  const meta = { k: 321, refs };
  const manifest = { v: 2, shards: [{ group_id: 1, hash: `hash-${version}`, meta: `meta-${version}`, bytes: bin.byteLength, meta_bytes: JSON.stringify(meta).length }] };
  return new Map([
    [BASE + 'index.json', { games: { [game]: { v2: { manifest: versionManifest } } } }],
    [BASE + versionManifest, manifest],
    [BASE + `pokemon/hash-${version}.bin`, bin],
    [BASE + `pokemon/meta-${version}.json.gz`, meta]
  ]);
}
async function page(store, files, { offline = false, native = null, nativeWritesFail = false } = {}) {
  const calls = [], localCalls = [], progress = [];
  const token = '01234567-89ab-cdef-0123-456789abcdef';
  const context = vm.createContext({
    console, TextDecoder, TextEncoder, Uint8Array, Uint32Array, Int32Array, DataView, ArrayBuffer,
    Blob, Response, DecompressionStream, indexedDB: store,
    navigator: { storage: { persisted: async () => false, persist: async () => false } },
    setTimeout, clearTimeout, AbortController,
    ...(native ? { location: { origin: 'http://127.0.0.1:18764' }, CardShowNativeCache: { token } } : {}),
    async fetch(url, options = {}) {
      if (String(url).startsWith('/scanner-cache/')) {
        localCalls.push({ url, method: options.method || 'GET' });
        assert.equal(options.headers['X-Scanner-Cache'], token);
        const parsed = new URL(url, 'http://127.0.0.1:18764'), key = parsed.searchParams.get('key');
        if (parsed.pathname.endsWith('/keys')) return new Response(JSON.stringify([...native.keys()]));
        if (options.method === 'PUT') {
          if (typeof nativeWritesFail === 'function' ? nativeWritesFail(key) : nativeWritesFail) return new Response('', { status: 507 });
          native.set(key, new Uint8Array(options.body).slice());
          return new Response(null, { status: 204 });
        }
        if (options.method === 'DELETE') { native.delete(key); return new Response(null, { status: 204 }); }
        return native.has(key) ? new Response(native.get(key).slice()) : new Response('', { status: 404 });
      }
      calls.push(url);
      if (offline) throw new TypeError('Offline');
      const file = files.get(url);
      if (!file) return new Response('', { status: 404 });
      return new Response(file instanceof ArrayBuffer ? file.slice(0) : JSON.stringify(file));
    }
  });
  const module = new vm.SourceTextModule(source, { context });
  await module.link(async () => {
    const dependency = new vm.SyntheticModule(['staticUrl'], function () { this.setExport('staticUrl', value => value); }, { context });
    return dependency;
  });
  await module.evaluate();
  return { calls, localCalls, progress, load: options => module.namespace.loadPack(game, (loaded, total, stats) => progress.push({ ...stats }), options) };
}

test('a complete saved v2 pack reopens in a new page with zero network requests', async () => {
  const store = indexedDBStore(), files = fixture();
  const first = await page(store, files);
  const downloaded = await first.load({ cacheFirst: true });
  assert.equal(downloaded.n, 1); assert.equal(first.calls.length, 4);
  assert.equal(store.values.get('cur:' + game), manifestPath, 'complete marker commits before load resolves');
  assert.ok(first.progress.at(-1).downloaded > 0);
  const reopened = await page(store, files, { offline: true });
  const saved = await reopened.load({ cacheFirst: true });
  assert.equal(saved.refs[0][0], 'p:123'); assert.equal(reopened.calls.length, 0);
  assert.equal(reopened.progress.at(-1).downloaded, 0);
  assert.equal(reopened.progress.at(-1).cachedHashShards, 1);
  assert.equal(reopened.progress.at(-1).cachedMetaShards, 1);
});

test('an explicit update checks the index while reusing unchanged shards', async () => {
  const store = indexedDBStore(), files = fixture();
  await (await page(store, files)).load({ cacheFirst: true });
  const update = await page(store, files);
  await update.load({ cacheFirst: false });
  assert.deepEqual(update.calls, [BASE + 'index.json']);
  assert.equal(update.progress.at(-1).downloaded, 0);
});

test('missing or corrupt cached shards are repaired without treating them as complete', async () => {
  for (const damage of ['missing', 'truncated', 'checksum']) {
    const store = indexedDBStore(), files = fixture();
    await (await page(store, files)).load({ cacheFirst: true });
    const key = 'h:pokemon/hash-1';
    if (damage === 'missing') store.values.delete(key);
    if (damage === 'truncated') store.values.set(key, new ArrayBuffer(2));
    if (damage === 'checksum') {
      const data = store.values.get(key); new DataView(data).setUint32(16, 999, true);
    }
    const repaired = await page(store, files);
    assert.equal((await repaired.load({ cacheFirst: true })).n, 1);
    assert.ok(repaired.calls.includes(BASE + 'pokemon/hash-1.bin'), damage);
    assert.ok(repaired.progress.at(-1).downloaded > 0, damage);
  }
});

test('failed persistent writes stay usable for this load and report the cache failure', async () => {
  const store = indexedDBStore({ writesFail: true });
  const first = await page(store, fixture());
  assert.equal((await first.load({ cacheFirst: true })).n, 1);
  assert.equal(first.progress.at(-1).cache, 'failed');
  assert.equal(store.values.size, 0);
});

test('cached-first accepts an older complete v2 marker even without the cached index', async () => {
  const store = indexedDBStore(), files = fixture();
  await (await page(store, files)).load({ cacheFirst: true });
  store.values.delete('index');
  const reopened = await page(store, files, { offline: true });
  assert.equal((await reopened.load({ cacheFirst: true })).n, 1);
  assert.equal(reopened.calls.length, 0);
});

test('legacy v1 packs also reopen without network or changing their saved schema', async () => {
  const store = indexedDBStore();
  const bin = new ArrayBuffer(184), view = new DataView(bin);
  new Uint8Array(bin, 0, 4).set(Buffer.from('NSPK'));
  view.setUint32(4, 1, true); view.setUint32(8, 1, true); view.setUint32(12, 7, true);
  view.setInt32(180, -1, true);
  const refs = [['p:123', 'Legacy card', '1', 'SET', 'Test set', '', '', []]];
  const files = new Map([
    [BASE + 'index.json', { games: { [game]: { ver: 7, bin: 'legacy.bin', meta: 'legacy.json', bin_bytes: 184, meta_bytes: 100 } } }],
    [BASE + 'legacy.bin', bin], [BASE + 'legacy.json', { refs }]
  ]);
  assert.equal((await (await page(store, files)).load({ cacheFirst: true })).format, 1);
  const reopened = await page(store, files, { offline: true });
  assert.equal((await reopened.load({ cacheFirst: true })).refs[0][1], 'Legacy card');
  assert.equal(reopened.calls.length, 0);
  assert.equal(reopened.progress.at(-1).cachedHashShards, 1);
  const native = new Map();
  const migrated = await page(store, files, { native, offline: true });
  assert.equal((await migrated.load({ cacheFirst: true })).format, 1);
  assert.equal(migrated.calls.length, 0);
  const nativeOnly = await page(unavailableIndexedDB(), files, { native, offline: true });
  assert.equal((await nativeOnly.load({ cacheFirst: true })).refs[0][1], 'Legacy card');
  assert.equal(nativeOnly.calls.length, 0);
});

function unavailableIndexedDB() {
  return { open() {
    const request = {};
    queueMicrotask(() => { request.error = new Error('WebKit storage unavailable'); request.onerror?.(); });
    return request;
  } };
}

test('native app cache survives fresh pages with IndexedDB unavailable and zero remote downloads', async () => {
  const native = new Map(), files = fixture();
  const first = await page(unavailableIndexedDB(), files, { native });
  assert.equal((await first.load({ cacheFirst: true })).n, 1);
  assert.equal(first.calls.length, 4);
  assert.equal(first.progress.at(-1).cacheBackend, 'native');
  assert.equal(first.progress.at(-1).cache, 'ok');
  assert.equal(first.progress.at(-1).storage.persisted, true);
  assert.ok(native.has('cur:' + game));
  const reopened = await page(unavailableIndexedDB(), files, { native, offline: true });
  assert.equal((await reopened.load({ cacheFirst: true })).refs[0][0], 'p:123');
  assert.equal(reopened.calls.length, 0);
  assert.equal(reopened.progress.at(-1).downloaded, 0);
  assert.equal(reopened.progress.at(-1).cachedHashShards, 1);
  assert.ok(reopened.localCalls.length > 0, 'reads travel only to app storage');
});

test('an existing website database migrates to native app storage without redownloading', async () => {
  const legacy = indexedDBStore(), native = new Map(), files = fixture();
  await (await page(legacy, files)).load({ cacheFirst: true });
  const migrated = await page(legacy, files, { native, offline: true });
  assert.equal((await migrated.load({ cacheFirst: true })).n, 1);
  assert.equal(migrated.calls.length, 0);
  assert.ok(native.has('h:pokemon/hash-1'));
  const reopened = await page(unavailableIndexedDB(), files, { native, offline: true });
  assert.equal((await reopened.load({ cacheFirst: true })).n, 1);
  assert.equal(reopened.calls.length, 0);
});

test('native corrupt data is repaired with the original shard validation', async () => {
  const native = new Map(), files = fixture();
  await (await page(unavailableIndexedDB(), files, { native })).load({ cacheFirst: true });
  native.set('h:pokemon/hash-1', new Uint8Array([1, 0, 0]));
  const repaired = await page(unavailableIndexedDB(), files, { native });
  assert.equal((await repaired.load({ cacheFirst: true })).n, 1);
  assert.ok(repaired.calls.includes(BASE + 'pokemon/hash-1.bin'));
  assert.ok(repaired.progress.at(-1).downloaded > 0);
});

test('native write failure preserves scanning but never claims the database was saved', async () => {
  const native = new Map();
  const failed = await page(unavailableIndexedDB(), fixture(), { native, nativeWritesFail: true });
  assert.equal((await failed.load({ cacheFirst: true })).n, 1);
  assert.equal(failed.progress.at(-1).cache, 'failed');
  assert.equal(failed.progress.at(-1).storage.persisted, false);
  assert.equal(native.size, 0);
});

test('a failed replacement marker preserves the last complete native database', async () => {
  const native = new Map();
  await (await page(unavailableIndexedDB(), fixture(1), { native })).load({ cacheFirst: true });
  const update = await page(unavailableIndexedDB(), fixture(2), { native, nativeWritesFail: key => key === 'cur:' + game });
  assert.equal((await update.load({ cacheFirst: false })).n, 1);
  assert.equal(update.progress.at(-1).cache, 'failed');
  assert.ok(native.has('h:pokemon/hash-1'), 'previous complete pack must not be pruned');
  const reopened = await page(unavailableIndexedDB(), fixture(2), { native, offline: true });
  assert.equal((await reopened.load({ cacheFirst: true })).ver, 'pokemon/manifest-1.json');
  assert.equal(reopened.calls.length, 0);
});
