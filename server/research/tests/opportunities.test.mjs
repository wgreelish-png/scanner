import test from 'node:test';
import assert from 'node:assert/strict';
import { createResearchHandler, MAX_RESPONSE_BYTES } from '../src/research.mjs';

// Entirely synthetic OppsV2 fixtures; these do not establish live access,
// marketplace inventory, an actual transaction or Research subscription status.
const TOKEN = 'synthetic-opportunities-device-token-0000000000';
const KEY = 'tcgt_beta_' + 'b'.repeat(48);
const options = { shipperID: '123', apiKey: KEY, deviceToken: TOKEN };
const PATH = '/api/v1/opportunities/3/42/101';
const UPSTREAM = 'https://beta.tcgtracking.com/v1/3/sets/42';
const researchPath = '/api/v1/research/3/42/101';
function request(path = PATH, token = TOKEN, method = 'GET') {
  return new Request(`https://research.example.test${path}`, { method, headers: token == null ? {} : { Authorization: `Bearer ${token}` } });
}
function fixture(group = 42) {
  return {
    meta: {
      schema_version: '2.0', category_id: 3, group_id: group,
      game_name: 'Synthetic game', set_name: 'Synthetic set', set_abbr: null,
      published_on: null, generated_at: '2026-10-29T00:00:00Z', etag: 'data-hash-is-not-http-etag',
      opp_count: 0, product_count: 2, sku_count: 2,
      catalog_ref_url: `https://openapi.tcgtracking.com/v1/3/sets/${group}.json`,
      flags: { mp_seller_listings_blocked: false, mp_singles_buyer_fee_pct: 0, mp_free_ship_threshold_us: 30, mp_default_ship_singles: 0, mp_default_ship_sealed: null },
    },
    products: {
      101: {
        product_id: 101, name: 'Synthetic card', ext_number: '1/10', ext_rarity: null,
        is_sealed: false, is_token: false, image_count: 1,
        images: { front_200: 'https://cdn.tcgtracking.com/product/101_200w.jpg', back_200: null },
        links: { tcgplayer: 'https://www.tcgplayer.com/product/101', tcg_affiliate: null },
        skus: {
          1001: {
            sku_id: 1001, condition_id: 1, condition: 'Near Mint', finish: 'Holofoil', language: 'English', manapool_id: null,
            timestamps: { opp_computed_at: null, tcgp_live_updated_at: '2026-10-28T23:00:00Z', tcgp_sales_updated_at: null },
            pricing: { market_product: 0, market_sku: '0.00', live_market: null, avg_30d: 12, listed_low_card: 0, listed_low_ship: 0, listed_low_total: 0, direct_low_card: null },
            opportunity: {
              is_available: false, unavailable_reason: 'sold_out', unavailable_at: null, best_source: 'tcg', opp_key: 'tcg:1001',
              buy_card: 0, fee_amount: 0, ship_1x: 0, cost_1x: 0,
              pack_free_ship: { buy_qty: 0, cost_pack_unit: null, cost_effective: 0 },
              benchmarks: { market_sku: { ref: null, cmp_basis: 'card', cmp_cost: 0, savings: null, discount_pct: null } },
              tightest_default: { low_key: 'market_sku', ref_price: null, savings: null, discount_pct: null },
            },
            opportunities_by_source: { tcg: { is_available: false, buy_card: 0 }, manapool: null },
            marketplaces: {
              tcgplayer: {
                available: false, updated_at: null, product_url: 'https://www.tcgplayer.com/product/101', direct_low_card: 0, total_qty_available: 0,
                listings: [{ rank: 1, price: 0, ship_price: null, landed_price: 0, seller_name: null, seller_key: 'synthetic-seller', seller_url: 'https://shop.tcgplayer.com/sellerfeedback/synthetic-seller', seller_qty: 0, updated_at: null }],
              },
              manapool: {
                available: false, seller_detail_status: 'blocked_pt403', updated_at: null, product_url: 'https://manapool.com/card/synthetic',
                low_price: 0, fee_amount: 0, estimated_ship_1x: 0, landed_1x: 0, total_qty_available: null,
                listings: [{ rank: 1, price: 0, ship_price: 0, fee_amount: 0, landed_price: 0, seller_id: null, seller_name: 'Synthetic seller', seller_url: 'https://manapool.com/sellers/synthetic', seller_qty: 0, origin_country: 'US', us_disable_first_class: false, updated_at: null }],
              },
            },
            trends: {
              updated_at: null, trend_30d_vs_90d_pct: -2, trend_90d_pct: 0, tcg_mp_trend_30d_pct: null, triple_trend_pass: false,
              windows: {
                '30d': { tcg_qty: 0, tcg_market_avg: 12, tcg_sold_avg: null, tcg_sold_avg_with_sh: null, mp_qty: 0, mp_avg: null, combined_qty: 0 },
                '90d': { tcg_qty: 2, tcg_market_avg: null, tcg_sold_avg: 10, tcg_sold_avg_with_sh: 11, mp_qty: 0, mp_avg: null, combined_qty: 2 },
                '365d': { tcg_qty: null, tcg_sold_avg: null, tcg_sold_avg_with_sh: null, mp_qty: null, combined_qty: 0 },
              },
              series_52w: { tcg_qty: [0, null, 2], mp_qty: null }, chart_buckets_90d: null,
            },
          },
          1002: { sku_id: null, condition_id: 2, condition: 'Lightly Played', finish: 'Normal', language: 'Japanese' },
        },
      },
      202: { product_id: 202, name: 'Other synthetic card', skus: {} },
    },
  };
}
function researchFixture() {
  return { meta: { schema_version: '2.0-testing', status: 'in_testing', category_id: 3, group_id: 42 }, products: { 101: { product_id: 101, name: 'Synthetic graded card', variants: {} } } };
}
function reply(body, status = 200, headers = {}) {
  return new Response(status === 304 ? null : typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { ETag: '"opportunities-http-etag"', ...headers } });
}
function loader(responses) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init, headers: new Headers(init.headers) });
    const response = responses.shift(); assert.ok(response, 'Unexpected upstream request');
    if (response instanceof Error) throw response;
    if (!response.url) Object.defineProperty(response, 'url', { value: url });
    return response;
  };
  return { calls, fetchImpl };
}

test('opportunities uses the authenticated fixed Beta set endpoint and never forwards the device token', async () => {
  const upstream = loader([reply(fixture())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const token of [null, '', 'incorrect', TOKEN + 'extra']) assert.equal((await handle(request(PATH, token))).status, 401);
  assert.equal(upstream.calls.length, 0);
  const response = await handle(request()); assert.equal(response.status, 200);
  const call = upstream.calls[0];
  assert.equal(call.url, UPSTREAM); assert.equal(call.init.method, 'GET'); assert.equal(call.init.redirect, 'error');
  assert.equal(call.headers.get('X-Shipper-Id'), '123'); assert.equal(call.headers.get('X-Api-Key'), KEY);
  assert.equal(call.headers.get('Authorization'), null); assert.ok(call.init.signal instanceof AbortSignal);
  const body = await response.text(); assert.ok(!body.includes(KEY)); assert.ok(!body.includes(TOKEN));
});

test('opportunities preserves exact product, condition, finish, language, explicit windows, zero, null and missing fields', async () => {
  const source = fixture();
  const handle = createResearchHandler({ ...options, fetchImpl: loader([reply(source)]).fetchImpl });
  const response = await handle(request()); assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body, { meta: source.meta, product: source.products[101] });
  assert.equal(body.products, undefined);
  assert.equal(body.product.skus[1001].pricing.avg_30d, 12);
  assert.equal(body.product.skus[1001].trends.windows['30d'].tcg_sold_avg, null, 'A pricing fallback is not a sold average');
  assert.equal(body.product.skus[1002].sku_id, null);
  assert.equal(Object.hasOwn(body.product.skus[1002], 'pricing'), false);
});

test('opportunities health reports credential configuration without testing provider access or Research subscription', async () => {
  const upstream = loader([]);
  const configured = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  const publicHealth = await (await configured(request('/health', null))).json();
  assert.equal(publicHealth.opportunitiesConfigured, true);
  assert.equal(publicHealth.researchConfigured, true);
  const unconfigured = createResearchHandler({ deviceToken: TOKEN, fetchImpl: upstream.fetchImpl });
  assert.equal((await (await unconfigured(request('/api/v1/health'))).json()).opportunitiesConfigured, false);
  const absent = await unconfigured(request()); assert.equal(absent.status, 503);
  assert.equal((await absent.json()).error.code, 'opportunities_not_configured');
  assert.equal(upstream.calls.length, 0);
});

test('opportunities validates canonical path identities before fetching', async () => {
  const upstream = loader([]); const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const path of [
    '/api/v1/opportunities/4/42/101', '/api/v1/opportunities/3/0/101', '/api/v1/opportunities/3/42/0101',
    '/api/v1/opportunities/3/42/1e2', '/api/v1/opportunities/3/42/1234567890123', '/api/v1/opportunities/3/42/%31%30%31',
    PATH + '/extra', PATH + '?url=https://evil.example', PATH + '?refresh=1',
  ]) assert.equal((await handle(request(path))).status, 400, path);
  for (const method of ['POST', 'PUT', 'DELETE']) assert.equal((await handle(request(PATH, TOKEN, method))).status, 405);
  assert.equal(upstream.calls.length, 0);
});

test('opportunities validates upstream set/product/SKU identities and schema before caching', async () => {
  const mutations = [
    body => { body.meta.category_id = 2; }, body => { body.meta.group_id = 43; },
    body => { body.products[101].product_id = 202; }, body => { body.products[101].product_id = '101'; },
    body => { body.products[101].skus[1001].sku_id = 1002; }, body => { body.products[101].skus[1001].condition_id = 0; },
    body => { body.products[101].skus[1001].condition = 'Lightly Played'; },
    body => { body.products[101].skus.bad = body.products[101].skus[1001]; },
    body => { body.products[101].skus[1001].pricing.market_sku = { secret: KEY }; },
    body => { body.products[101].skus[1001].trends.windows = []; },
  ];
  const bodies = [{}, 'not JSON', ...mutations.map(mutate => { const body = fixture(); mutate(body); return body; })];
  for (const body of bodies) {
    const handle = createResearchHandler({ ...options, fetchImpl: loader([reply(body)]).fetchImpl });
    const response = await handle(request()); assert.equal(response.status, 502);
    assert.equal((await response.json()).error.code, 'upstream_invalid_response');
  }
});

test('opportunities separates missing set and missing product without assuming no sales or stock', async () => {
  const uncovered = createResearchHandler({ ...options, fetchImpl: loader([reply({}, 404)]).fetchImpl });
  const set = await uncovered(request()); assert.equal(set.status, 404); assert.equal((await set.json()).error.code, 'not_covered');
  const handle = createResearchHandler({ ...options, fetchImpl: loader([reply(fixture())]).fetchImpl });
  const product = await handle(request('/api/v1/opportunities/3/42/999'));
  assert.equal(product.status, 404); assert.equal((await product.json()).error.code, 'product_not_covered');
});

test('opportunities strips unknown fields and authtoken at every nested boundary and omits unsafe links', async () => {
  const body = fixture();
  function addSecrets(value) {
    if (Array.isArray(value)) value.forEach(addSecrets);
    else if (value && typeof value === 'object') { Object.values(value).forEach(addSecrets); value.authtoken = KEY; }
  }
  addSecrets(body);
  body.meta.catalog_ref_url = 'https://evil.example/catalog';
  body.products[101].images.front_200 = 'javascript:alert(1)';
  body.products[101].links.tcg_affiliate = 'https://www.tcgplayer.com.evil.example/';
  body.products[101].skus[1001].marketplaces.tcgplayer.listings[0].seller_url = 'https://user:pass@shop.tcgplayer.com/sellerfeedback/synthetic';
  body.products[101].skus[1001].trends.windows.private = { authtoken: KEY };
  body.products[101].skus[1001].trends.chart_buckets_90d = { authtoken: KEY };
  // Dictionary identities are strict, so only inject into documented records.
  delete body.products.authtoken; delete body.products[101].skus.authtoken; delete body.products[202].skus.authtoken;
  const handle = createResearchHandler({ ...options, fetchImpl: loader([reply(body)]).fetchImpl });
  const response = await handle(request()); assert.equal(response.status, 200);
  const output = await response.text(); assert.ok(!output.includes(KEY)); assert.ok(!output.includes('authtoken')); assert.ok(!output.includes('evil.example')); assert.ok(!output.includes('javascript:'));
  const safe = JSON.parse(output);
  assert.equal(safe.meta.catalog_ref_url, undefined); assert.equal(safe.product.images.front_200, undefined);
  assert.equal(safe.product.skus[1001].marketplaces.tcgplayer.listings[0].seller_url, undefined);
  assert.equal(safe.product.skus[1001].trends.chart_buckets_90d, undefined);
});

test('opportunities cache and HTTP ETag revalidation are separate from Research for the same set', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(researchFixture(), 200, { ETag: '"research-http"' }), reply(fixture()), reply(null, 304)]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, now: () => clock });
  assert.equal((await handle(request(researchPath))).status, 200);
  assert.equal((await handle(request())).status, 200);
  const secondProduct = await handle(request('/api/v1/opportunities/3/42/202')); assert.equal(secondProduct.status, 200);
  assert.equal((await secondProduct.json()).product.product_id, 202); assert.equal(upstream.calls.length, 2);
  assert.equal(upstream.calls[1].headers.get('If-None-Match'), null);
  clock += 3_600_001;
  const refreshed = await handle(request()); assert.equal(refreshed.status, 200);
  assert.equal(upstream.calls[2].url, UPSTREAM);
  assert.equal(upstream.calls[2].headers.get('If-None-Match'), '"opportunities-http-etag"');
  assert.equal((await refreshed.json()).meta.generated_at, fixture().meta.generated_at);
});

test('Research access denial cooldown never blocks opportunities for the same set', async () => {
  const upstream = loader([reply({ private: KEY }, 403), reply(fixture())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  const research = await handle(request(researchPath)); assert.equal(research.status, 502);
  assert.equal((await research.json()).error.code, 'research_access_denied');
  assert.equal((await handle(request())).status, 200);
  assert.equal((await handle(request(researchPath))).status, 502);
  assert.equal(upstream.calls.length, 2);
});

test('opportunities access errors are credential-safe and distinct from phone authorization', async () => {
  for (const status of [401, 403]) {
    const handle = createResearchHandler({ ...options, fetchImpl: loader([reply({ authtoken: KEY, client_ip: '192.0.2.1' }, status)]).fetchImpl });
    const response = await handle(request()); assert.equal(response.status, 502);
    const output = await response.text(); assert.equal(JSON.parse(output).error.code, 'opportunities_access_denied');
    assert.ok(!output.includes(KEY)); assert.ok(!output.includes('192.0.2.1')); assert.ok(!output.includes('Research subscription'));
  }
  const handle = createResearchHandler({ ...options, fetchImpl: loader([new Error(KEY)]).fetchImpl });
  const response = await handle(request()); assert.equal(response.status, 502); assert.ok(!(await response.text()).includes(KEY));
});

test('opportunities honors Retry-After and never silently serves expired data after a failure', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([reply(fixture()), reply({}, 429, { 'Retry-After': '45' }), reply(fixture())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, now: () => clock });
  assert.equal((await handle(request())).status, 200); clock += 3_600_001;
  const failed = await handle(request()); assert.equal(failed.status, 503); assert.equal(failed.headers.get('Retry-After'), '45');
  assert.equal((await failed.json()).error.code, 'opportunities_temporarily_unavailable');
  assert.equal((await handle(request())).status, 503); assert.equal(upstream.calls.length, 2);
  clock += 45_001; assert.equal((await handle(request())).status, 200); assert.equal(upstream.calls.length, 3);
});

test('opportunities rejects redirects, changed response URLs, unsolicited 304s and oversized bodies', async () => {
  const changed = reply(fixture()); Object.defineProperty(changed, 'url', { value: 'https://evil.example/shard' });
  const huge = fixture(); huge.padding = 'x'.repeat(MAX_RESPONSE_BYTES);
  for (const response of [reply({}, 302, { Location: 'https://evil.example' }), changed, reply(null, 304), reply(huge), reply(fixture(), 200, { 'Content-Length': String(MAX_RESPONSE_BYTES + 1) })]) {
    const handle = createResearchHandler({ ...options, fetchImpl: loader([response]).fetchImpl });
    assert.equal((await handle(request())).status, 502);
  }
});

test('opportunities bounds SKU, listing and weekly arrays instead of returning a partially truncated identity', async () => {
  const mutations = [
    body => { body.products[101].skus = Object.fromEntries(Array.from({ length: 513 }, (_, i) => [10000 + i, { sku_id: 10000 + i, condition_id: 1, condition: 'Near Mint', finish: 'Normal', language: 'English' }])); },
    body => { body.products[101].skus[1001].marketplaces.tcgplayer.listings = Array.from({ length: 21 }, () => ({ price: 1 })); },
    body => { body.products[101].skus[1001].trends.series_52w.tcg_qty = Array(53).fill(0); },
  ];
  for (const mutate of mutations) {
    const body = fixture(); mutate(body);
    const handle = createResearchHandler({ ...options, fetchImpl: loader([reply(body)]).fetchImpl });
    const response = await handle(request()); assert.equal(response.status, 502); assert.equal((await response.json()).error.code, 'upstream_invalid_response');
  }
});

test('opportunities and Research share global client rate, cache and pending-request bounds', async () => {
  const upstream = loader([reply(researchFixture()), reply(fixture()), reply(researchFixture())]);
  const cached = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, maxEntries: 1 });
  for (const path of [researchPath, PATH, researchPath]) assert.equal((await cached(request(path))).status, 200);
  assert.equal(upstream.calls.length, 3, 'A shared one-entry cache must evict across adapters');
  const rates = createResearchHandler({ ...options, fetchImpl: loader([reply(researchFixture())]).fetchImpl, maxRequestsPerMinute: 1 });
  assert.equal((await rates(request(researchPath))).status, 200);
  assert.equal((await rates(request())).status, 429);
  let resolve;
  const queued = createResearchHandler({ ...options, maxPending: 1, fetchImpl: () => new Promise(accept => { resolve = accept; }) });
  const first = queued(request(researchPath));
  const busy = await queued(request()); assert.equal(busy.status, 503); assert.equal((await busy.json()).error.code, 'server_busy');
  resolve(reply(researchFixture())); assert.equal((await first).status, 200);
});

test('concurrent opportunities requests deduplicate only their own shard', async () => {
  const waiting = []; let calls = 0;
  const handle = createResearchHandler({ ...options, fetchImpl: url => { calls++; return new Promise(accept => waiting.push(() => accept(reply(url.endsWith('/research') ? researchFixture() : fixture())))); } });
  const responses = [handle(request()), handle(request('/api/v1/opportunities/3/42/202')), handle(request(researchPath))];
  assert.equal(calls, 2, 'Research and opportunities require independent upstream loads');
  waiting.forEach(resolve => resolve());
  assert.deepEqual((await Promise.all(responses)).map(response => response.status), [200, 200, 200]);
});
