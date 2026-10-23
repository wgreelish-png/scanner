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
  const bin = new ArrayBuffer(196), view = new DataView(bin);
  new Uint8Array(bin, 0, 4).set(Buffer.from('NSPS'));
  view.setUint32(4, 2, true); view.setUint32(8, 1, true); view.setUint32(16, 321, true);
  view.setInt32(188, -1, true); view.setInt32(192, -1, true);
  const refs = [['p:123', 'Test card', '1', 'SET', 'Test set', '', '', []]];
  const meta = { k: 321, refs };
  const manifest = { v: 2, shards: [{ group_id: 1, hash: `hash-${version}`, meta: `meta-${version}`, bytes: bin.byteLength, meta_bytes: JSON.stringify(meta).length }] };
  return new Map([
    [BASE + 'index.json', { games: { [game]: { v2: { manifest: manifestPath } } } }],
    [BASE + manifestPath, manifest],
    [BASE + `pokemon/hash-${version}.bin`, bin],
    [BASE + `pokemon/meta-${version}.json.gz`, meta]
  ]);
}
async function page(store, files, { offline = false } = {}) {
  const calls = [], progress = [];
  const context = vm.createContext({
    console, TextDecoder, TextEncoder, Uint8Array, Uint32Array, Int32Array, DataView, ArrayBuffer,
    Blob, Response, DecompressionStream, indexedDB: store,
    navigator: { storage: { persisted: async () => false, persist: async () => false } },
    setTimeout,
    async fetch(url) {
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
  return { calls, progress, load: options => module.namespace.loadPack(game, (loaded, total, stats) => progress.push({ ...stats }), options) };
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
});
