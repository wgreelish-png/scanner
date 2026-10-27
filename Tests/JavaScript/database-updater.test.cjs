const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../CardShowScanner/Resources/DatabaseUpdater.js'), 'utf8');
const config = { game: 'tcgp:3', cacheToken: '01234567-89ab-cdef-0123-456789abcdef' };
const prepared = { status: 'updated', downloadedBytes: 196, cachedShards: 2,
  previousManifestPath: 'pokemon/manifest-old.json', proposedManifestPath: 'pokemon/manifest-new.json' };

function harness({ result = prepared, prepare, origin = 'http://127.0.0.1:18764' } = {}) {
  const imports = [], games = [];
  const sandbox = { location: { origin } };
  // Maintenance must not touch DOM, camera permission or media capture.
  Object.defineProperty(sandbox, 'navigator', { get() { throw new Error('Maintenance touched camera environment'); } });
  const context = vm.createContext(sandbox);
  const script = new vm.Script(source, { importModuleDynamically: async specifier => {
    imports.push(specifier);
    assert.equal(sandbox.CardShowNativeCache.token, config.cacheToken, 'native cache configured before import');
    const module = new vm.SyntheticModule(['prepareCachedPackUpdate'], function () {
      this.setExport('prepareCachedPackUpdate', async game => { games.push(game); return prepare ? prepare(game) : result; });
    }, { context });
    await module.link(() => {}); await module.evaluate(); return module;
  } });
  script.runInContext(context);
  return { imports, games, run: value => sandbox.CardShowDatabaseUpdater.run(value) };
}

test('database maintenance imports only the bundled pack module and returns a staged publication plan', async () => {
  const h = harness();
  assert.deepEqual(JSON.parse(JSON.stringify(await h.run(config))), prepared);
  assert.deepEqual(h.imports, ['/newscanplus/assets/js/core/pack.js']);
  assert.deepEqual(h.games, ['tcgp:3']);
});

test('database maintenance rejects unsupported configuration before importing or fetching', async () => {
  for (const value of [null, {}, { ...config, game: 'other' }, { ...config, cacheToken: '' },
    { ...config, cacheToken: 'x'.repeat(257) }]) {
    const h = harness();
    assert.equal((await h.run(value)).status, 'failed'); assert.equal(h.imports.length, 0);
  }
  const h = harness({ origin: 'https://tcgtracking.com' });
  assert.equal((await h.run(config)).status, 'failed'); assert.equal(h.imports.length, 0);
});

test('maintenance skips uncached games and never leaks arbitrary errors or result fields', async () => {
  const skipped = harness({ result: { status: 'skipped', downloadedBytes: 0, cachedShards: 0, secret: 'discard' } });
  assert.deepEqual(JSON.parse(JSON.stringify(await skipped.run(config))), { status: 'skipped', downloadedBytes: 0, cachedShards: 0 });
  const failed = harness({ prepare: () => { throw new Error('private server or cookie details'); } });
  assert.deepEqual(JSON.parse(JSON.stringify(await failed.run(config))), { status: 'failed', downloadedBytes: 0, cachedShards: 0 });
  const safe = harness({ result: { ...prepared, rawError: 'discard', cardName: 'discard' } });
  assert.deepEqual(JSON.parse(JSON.stringify(await safe.run(config))), prepared);
});

test('maintenance validates exact scalar results and both safe manifest paths', async () => {
  for (const result of [null, { ...prepared, status: 'success' }, { ...prepared, downloadedBytes: -1 },
    { ...prepared, downloadedBytes: Infinity }, { ...prepared, downloadedBytes: 1.2 },
    { ...prepared, cachedShards: 8193 }, { ...prepared, cachedShards: -1 },
    { ...prepared, proposedManifestPath: '../other.json' }, { ...prepared, previousManifestPath: 'https://example.test/pack' },
    { ...prepared, proposedManifestPath: 'pokemon//manifest.json' }, { ...prepared, previousManifestPath: null }]) {
    const h = harness({ result });
    assert.equal((await h.run(config)).status, 'failed');
  }
  const current = harness({ result: { ...prepared, status: 'upToDate', downloadedBytes: 0 } });
  assert.equal((await current.run(config)).status, 'upToDate');
});

test('overlapping maintenance requests do not start two downloads and a completed run can retry', async () => {
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  const h = harness({ prepare: () => pending });
  const first = h.run(config);
  assert.equal((await h.run(config)).status, 'failed');
  finish(prepared);
  assert.equal((await first).status, 'updated'); assert.equal(h.imports.length, 1);
  assert.equal((await h.run(config)).status, 'updated'); assert.equal(h.imports.length, 2);
});
