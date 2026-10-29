import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createResearchHandler } from '../src/research.mjs';

// Production-default integration tests with entirely synthetic local fixtures.
// No account credentials, network calls or timers are needed.
const DAY = 86_400_000;
const TOKEN = 'synthetic-cadence-device-token-000000000000';
const KEY = 'tcgt_beta_' + 'c'.repeat(48);
const options = { shipperID: '456', apiKey: KEY, deviceToken: TOKEN };
const origin = 'https://beta.tcgtracking.com';
function request(kind = 'opportunities', group = 42, force = false) {
  return new Request(`https://research.example.test/api/v1/${kind}/3/${group}/101`, {
    headers: { Authorization: `Bearer ${TOKEN}`, ...(force ? { 'Cache-Control': 'no-cache' } : {}) },
  });
}
function index(hash = 'data-A') {
  return { schema_version: '2.0', categories: { 3: { category_id: 3, sets: {
    42: { category_id: 3, group_id: 42, set_name: 'Synthetic requested set', ...(hash == null ? {} : { etag: hash }) },
    43: { category_id: 3, group_id: 43, set_name: 'Synthetic other set', etag: 'other-data' },
  } } } };
}
function shard(kind = 'opportunities', group = 42, hash = 'data-A') {
  return { meta: { schema_version: '2.0-testing', status: 'in_testing', category_id: 3, group_id: group, etag: hash, generated_at: '2026-10-29T00:00:00Z' },
    products: { 101: kind === 'opportunities' ? { product_id: 101, name: 'Synthetic exact SKU card', skus: { 1001: { sku_id: 1001, condition_id: 1, condition: 'Near Mint', finish: 'Holofoil', language: 'English', pricing: { market_sku: 0, live_market: null } } } } : { product_id: 101, name: 'Synthetic graded card', variants: {} } } };
}
function reply(body, { status = 200, etag = '"http-shard-A"', headers = {} } = {}) {
  return new Response(status === 304 ? null : JSON.stringify(body), { status, headers: { ...(etag ? { ETag: etag } : {}), ...headers } });
}
function loader(responses) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init, headers: new Headers(init.headers) });
    const response = responses.shift(); assert.ok(response, `Unexpected upstream call ${url}`);
    if (response instanceof Error) throw response;
    Object.defineProperty(response, 'url', { value: url });
    return response;
  };
  return { calls, fetchImpl };
}

test('default daily cadence checks only the needed index/set and skips unchanged shards beyond their TTL', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(index(), { etag: '"http-index-A"' }), reply(shard()), reply(null, { status: 304, etag: '"http-index-A"' })]);
  const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
  const first = await handle(request()); assert.equal(first.status, 200);
  assert.deepEqual(upstream.calls.map(call => call.url), [`${origin}/v1/meta`, `${origin}/v1/3/sets/42`]);
  assert.ok(upstream.calls.every(call => call.headers.get('X-Api-Key') === KEY && call.headers.get('X-Shipper-Id') === '456' && !call.headers.has('Authorization') && call.init.redirect === 'error'));
  clock += 3_600_001; assert.equal((await handle(request())).status, 200); assert.equal(upstream.calls.length, 2);
  clock += DAY;
  const refreshed = await handle(request()); assert.equal(refreshed.status, 200);
  assert.equal(upstream.calls.length, 3, 'An unchanged daily index avoids a shard download after more than24h');
  assert.equal(upstream.calls[2].url, `${origin}/v1/meta`);
  assert.equal(upstream.calls[2].headers.get('If-None-Match'), '"http-index-A"');
  assert.equal((await refreshed.json()).meta.generated_at, '2026-10-29T00:00:00Z');
});

test('manual refresh revalidates the index immediately, fetches changed needed shard, and never sends a data hash as HTTP ETag', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([
    reply(index(), { etag: '"http-index-A"' }), reply(shard()),
    reply(index('data-B'), { etag: '"http-index-B"' }), reply(shard('opportunities', 42, 'data-B'), { etag: '"http-shard-B"' }),
    reply(null, { status: 304, etag: '"http-index-B"' }),
  ]);
  const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(request())).status, 200); clock += 60_001;
  const changed = await handle(request('opportunities', 42, true)); assert.equal(changed.status, 200);
  assert.equal((await changed.json()).meta.etag, 'data-B');
  assert.equal(upstream.calls[2].headers.get('If-None-Match'), '"http-index-A"');
  assert.equal(upstream.calls[3].headers.get('If-None-Match'), '"http-shard-A"');
  assert.ok(upstream.calls.every(call => !['data-A', 'data-B'].includes(call.headers.get('If-None-Match'))));
  assert.equal((await handle(request('opportunities', 42, true))).status, 200);
  assert.equal(upstream.calls.length, 5, 'Manual unchanged index validation does not redownload the shard');
});

test('an index with a changed data hash refreshes the shard before its ordinary daily deadline', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(index()), reply(shard()), reply(index('data-B')), reply(shard('opportunities', 42, 'data-B'))]);
  const handle = createResearchHandler({ ...options, indexTTLms: 600_000, now: () => clock, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(request())).status, 200); clock += 600_001;
  const changed = await handle(request()); assert.equal(changed.status, 200); assert.equal((await changed.json()).meta.etag, 'data-B');
  assert.equal(upstream.calls.length, 4);
});

test('missing index data hash falls back to daily shard HTTP ETag revalidation', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(index(null), { etag: '"index-no-data-hash"' }), reply(shard()), reply(null, { status: 304 }), reply(null, { status: 304 })]);
  const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(request())).status, 200); clock += 3_600_001;
  assert.equal((await handle(request())).status, 200); assert.equal(upstream.calls.length, 2);
  clock += DAY;
  assert.equal((await handle(request())).status, 200); assert.equal(upstream.calls.length, 4);
  assert.equal(upstream.calls[2].headers.get('If-None-Match'), '"index-no-data-hash"');
  assert.equal(upstream.calls[3].headers.get('If-None-Match'), '"http-shard-A"');
});

test('Research and Opportunities keep separate index/data/HTTP ETags and authorization cooldowns', async () => {
  const upstream = loader([reply({}, { status: 403 }), reply(index()), reply(shard())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  const denied = await handle(request('research')); assert.equal(denied.status, 502); assert.equal((await denied.json()).error.code, 'research_access_denied');
  assert.equal((await handle(request('research'))).status, 502); assert.equal(upstream.calls.length, 1, 'No automatic auth retry loop');
  assert.equal((await handle(request())).status, 200);
  assert.deepEqual(upstream.calls.map(call => call.url), [`${origin}/v1/research/meta`, `${origin}/v1/meta`, `${origin}/v1/3/sets/42`]);
});

test('index and shard requests, including304, consume the same upstream budget across route kinds', async () => {
  const upstream = loader([reply(index()), reply(shard()), reply(index())]);
  const handle = createResearchHandler({ ...options, maxUpstreamRequestsPerMinute: 3, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(request())).status, 200);
  const blocked = await handle(request('research')); assert.equal(blocked.status, 503);
  assert.equal((await blocked.json()).error.code, 'upstream_rate_limited'); assert.ok(Number(blocked.headers.get('Retry-After')) > 0);
  assert.equal(upstream.calls.length, 3);
  const conditional = loader([reply(index()), reply(shard()), reply(null, { status: 304 })]);
  const other = createResearchHandler({ ...options, maxUpstreamRequestsPerMinute: 3, fetchImpl: conditional.fetchImpl });
  assert.equal((await other(request())).status, 200);
  assert.equal((await other(request('opportunities', 42, true))).status, 200);
  assert.equal((await other(request('research'))).status, 503, 'The successful index304 consumes the third slot');
  assert.equal(conditional.calls.length, 3);
});

test('the full120/min upstream ceiling applies across client IPs and Research/Opps, then resets at60s', async () => {
  let clock = 1_800_000_000_000; let calls = 0;
  const handle = createResearchHandler({ ...options, syncIndex: false, maxRequestsPerMinute: 1000, now: () => clock,
    fetchImpl: async url => { calls++; const group = Number(/\/sets\/(\d+)/.exec(url)[1]); return reply(shard(url.endsWith('/research') ? 'research' : 'opportunities', group)); } });
  for (let group = 1; group <= 120; group++) assert.equal((await handle(request(group % 2 ? 'research' : 'opportunities', group), { clientIP: `synthetic-client-${group}` })).status, 200);
  const blocked = await handle(request('research', 999), { clientIP: 'another-client' });
  assert.equal(blocked.status, 503); assert.equal((await blocked.json()).error.code, 'upstream_rate_limited'); assert.equal(calls, 120);
  clock += 60_001; assert.equal((await handle(request('research', 999))).status, 200); assert.equal(calls, 121);
});

test('provider Remaining/Reset and Limit headers reduce the shared budget before an avoidable429', async () => {
  for (const headers of [
    { 'X-RateLimit-Limit': '120', 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '17' },
    { 'X-RateLimit-Limit': '1', 'X-RateLimit-Remaining': '119', 'X-RateLimit-Reset': '60' },
  ]) {
    let clock = 1_800_000_000_000;
    const upstream = loader([reply(index(), { headers }), reply(shard())]);
    const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
    const blocked = await handle(request()); assert.equal(blocked.status, 503); assert.equal(upstream.calls.length, 1);
    assert.ok(Number(blocked.headers.get('Retry-After')) >= (headers['X-RateLimit-Limit'] === '1' ? 1 : 17));
    clock += 60_001; assert.equal((await handle(request())).status, 200); assert.equal(upstream.calls.length, 2);
  }
});

test('provider Retry-After blocks authenticated HTTP calls across both route kinds without retry loops', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply({}, { status: 429, headers: { 'Retry-After': '45' } }), reply(index()), reply(shard('research'))]);
  const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
  const failed = await handle(request()); assert.equal(failed.status, 503); assert.equal(failed.headers.get('Retry-After'), '45');
  const other = await handle(request('research')); assert.equal(other.status, 503); assert.equal((await other.json()).error.code, 'upstream_rate_limited');
  assert.equal(upstream.calls.length, 1); clock += 45_001;
  assert.equal((await handle(request('research'))).status, 200); assert.equal(upstream.calls.length, 3);
});

test('concurrent needed sets coalesce the index and use the same bounded pending queue', async () => {
  let acceptIndex; const calls = [];
  const handle = createResearchHandler({ ...options, maxPending: 1, fetchImpl: async url => {
    calls.push(url); if (url.endsWith('/meta')) return new Promise(accept => { acceptIndex = accept; });
    return reply(shard());
  } });
  const first = handle(request()); const same = handle(request());
  await new Promise(resolve => setImmediate(resolve)); assert.equal(calls.length, 1);
  const busy = await handle(request('research')); assert.equal(busy.status, 503); assert.equal((await busy.json()).error.code, 'server_busy');
  acceptIndex(reply(index())); assert.deepEqual((await Promise.all([first, same])).map(response => response.status), [200, 200]);
  assert.equal(calls.length, 2);
});

test('daily sanitized index/shard snapshots survive a handler restart without fetching or persisting credentials', async t => {
  let clock = 1_800_000_000_000;
  const directory = await mkdtemp(join(tmpdir(), 'tcg-beta-cadence-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const sourceIndex = index(); sourceIndex.authtoken = KEY;
  const sourceShard = shard(); sourceShard.products[101].authtoken = TOKEN;
  const firstLoader = loader([reply(sourceIndex, { etag: '"persisted-index-http"' }), reply(sourceShard)]);
  const first = createResearchHandler({ ...options, cacheDirectory: directory, now: () => clock, fetchImpl: firstLoader.fetchImpl });
  assert.equal((await first(request())).status, 200);
  const saved = await readFile(join(directory, 'cache.json'), 'utf8');
  assert.ok(!saved.includes(KEY)); assert.ok(!saved.includes(TOKEN)); assert.ok(!saved.includes('authtoken'));
  assert.equal(JSON.parse(saved).entries.length, 2); assert.equal((await stat(join(directory, 'cache.json'))).mode & 0o777, 0o600);
  clock += 3_600_001;
  const warmLoader = loader([]);
  const warm = createResearchHandler({ ...options, cacheDirectory: directory, now: () => clock, fetchImpl: warmLoader.fetchImpl });
  assert.equal((await warm(request())).status, 200); assert.equal(warmLoader.calls.length, 0);
  clock += DAY;
  const dailyLoader = loader([reply(null, { status: 304 })]);
  const restarted = createResearchHandler({ ...options, cacheDirectory: directory, now: () => clock, fetchImpl: dailyLoader.fetchImpl });
  assert.equal((await restarted(request())).status, 200); assert.equal(dailyLoader.calls.length, 1);
  assert.equal(dailyLoader.calls[0].headers.get('If-None-Match'), '"persisted-index-http"');
});

test('persistent and in-memory caches keep a shared four-body bound, while corrupt snapshots cold-start safely', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'tcg-beta-bounded-')); t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, 'cache.json'), '{not valid JSON');
  let calls = 0;
  const handle = createResearchHandler({ ...options, cacheDirectory: directory, fetchImpl: async url => {
    calls++; if (url.endsWith('/meta')) return reply(index());
    const kind = url.endsWith('/research') ? 'research' : 'opportunities';
    return reply(shard(kind, Number(/\/sets\/(\d+)/.exec(url)[1])));
  } });
  for (const [kind, group] of [['opportunities', 42], ['research', 42], ['opportunities', 43]]) assert.equal((await handle(request(kind, group))).status, 200);
  const saved = JSON.parse(await readFile(join(directory, 'cache.json'), 'utf8'));
  assert.equal(saved.entries.length, 4); assert.equal(calls, 5);
});

test('expired index failure is visible and never silently reuses cached success', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(index()), reply(shard()), reply({}, { status: 503, headers: { 'Retry-After': '30' } })]);
  const handle = createResearchHandler({ ...options, now: () => clock, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(request())).status, 200); clock += DAY + 1;
  const failed = await handle(request()); assert.equal(failed.status, 503); assert.equal((await failed.json()).product, undefined);
  assert.equal((await handle(request())).status, 503); assert.equal(upstream.calls.length, 3);
});

test('invalid index identity or unsolicited304 fails before requesting a shard; unsupported HEAD does not call Beta', async () => {
  const invalid = index(); invalid.categories[3].sets[42].group_id = 999;
  for (const response of [reply(invalid), reply(null, { status: 304 }), reply({ categories: [] })]) {
    const upstream = loader([response]); const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
    const failed = await handle(request()); assert.equal(failed.status, 502); assert.equal((await failed.json()).error.code, 'upstream_invalid_response'); assert.equal(upstream.calls.length, 1);
  }
  const upstream = loader([]); const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  assert.equal((await handle(new Request(request().url, { method: 'HEAD', headers: { Authorization: `Bearer ${TOKEN}` } }))).status, 405);
  assert.equal(upstream.calls.length, 0);
});
