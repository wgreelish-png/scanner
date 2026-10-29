import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const collection = JSON.parse(readFileSync(new URL('./TCGTracking-Market.postman_collection.json', import.meta.url)));
const pre = collection.event.find(event => event.listen === 'prerequest').script.exec.join('\n');
const responseScript = collection.event.find(event => event.listen === 'test').script.exec.join('\n');
const credentials = { tcgt_shipper_id: '123', tcgt_beta_key: 'synthetic-beta-key-not-a-live-secret' };
function harness(secrets = credentials) {
  const values = new Map(collection.variable.map(item => [item.key, item.value]));
  function run(number, body, { code = 200, url, malformed = false } = {}) {
    const item = collection.item[number - 1];
    const local = new Map(); const headers = new Map(item.request.header.map(item => [item.key.toLowerCase(), item.value]));
    const output = { tests: [], skipped: false, headers, logs: [] };
    const variables = {
      get: key => local.has(key) ? local.get(key) : values.get(key),
      set: (key, value) => local.set(key, value),
      replaceIn(text) { return text.replace(/\{\{([^}]+)\}\}/g, (_, key) => this.get(key) ?? '{{' + key + '}}'); },
    };
    const pm = {
      info: { requestName: item.name }, variables,
      environment: { get: key => secrets[key] },
      collectionVariables: { get: key => values.get(key), set: (key, value) => values.set(key, value), unset: key => values.delete(key) },
      request: { url: { toString: () => url ?? item.request.url }, headers: { remove: key => headers.delete(key.toLowerCase()), upsert: ({ key, value }) => headers.set(key.toLowerCase(), value) } },
      execution: { skipRequest: () => { output.skipped = true; }, setNextRequest: value => { output.next = value; } },
      response: { code, json() { if (malformed) throw Error('not JSON'); return body; } },
      test(name, fn) { try { fn(); output.tests.push({ name, passed: true }); } catch (error) { output.tests.push({ name, passed: false }); } },
      visualizer: { set: (template, data) => { output.visualizer = { template, data }; } },
    };
    const context = vm.createContext({ pm, console: { log: (...args) => output.logs.push(args) } });
    try { vm.runInContext(pre, context); } catch (error) { output.preError = error.message; }
    output.url = variables.replaceIn(url ?? item.request.url);
    if (!output.skipped && !output.preError) vm.runInContext(responseScript, context);
    output.summary = JSON.parse(values.get('tcgt_market_summary'));
    return output;
  }
  return { values, run };
}
function publicFixture(skus) {
  return { set_id: 22872, updated: '2026-10-29T00:00:00Z', products: { 512035: skus ?? {
    1001: { cnd: 'NM', var: 'Holofoil', lng: 'EN', mkt: 0, low: 0, hi: null, cnt: 0, mp: null },
    1002: { cnd: 'LP', var: 'Holofoil', lng: 'EN', mkt: 1 },
  } } };
}
function betaFixture(skus) {
  return { meta: { schema_version: '2.0', category_id: 3, group_id: 22872, generated_at: '2026-10-29T00:00:00Z' }, products: { 512035: {
    product_id: 512035, name: 'Synthetic Charmander', skus: skus ?? { 1001: {
      sku_id: 1001, condition_id: 1, condition: 'Near Mint', finish: 'Holofoil', language: 'English',
      pricing: { market_sku: 0, avg_30d: 12, listed_low_card: 0, listed_low_ship: null, listed_low_total: null },
      timestamps: { tcgp_sales_updated_at: null },
      marketplaces: { tcgplayer: { available: false, total_qty_available: 0, listings: [{ price: 0, ship_price: null, landed_price: 0, seller_qty: 0, authtoken: credentials.tcgt_beta_key }] } },
      trends: { windows: { '30d': { tcg_qty: 0, tcg_market_avg: 12, tcg_sold_avg: null, combined_qty: 0 }, '90d': { tcg_sold_avg: 10, tcg_sold_avg_with_sh: 11 }, '365d': null } },
    } },
  } } };
}
const index = { categories: { 3: { category_id: 3, sets: { 22872: { group_id: 22872, set_name: 'SV: Scarlet & Violet Promo Cards', opp_count: 0 } } } } };
function ready(secrets) { const h = harness(secrets); h.run(1, publicFixture()); return h; }

test('separate collection has exactly three read-only fixed-host requests and no embedded credentials or Research URLs', () => {
  assert.equal(collection.item.length, 3);
  assert.equal(collection.info.schema, 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json');
  assert.ok(collection.item.every(item => item.request.method === 'GET' && item.request.auth.type === 'noauth' && item.protocolProfileBehavior.followRedirects === false));
  assert.equal(collection.item[0].request.url, 'https://openapi.tcgtracking.com/v1/{{tcgt_market_category_id}}/sets/{{tcgt_market_group_id}}/skus');
  assert.equal(collection.item[1].request.url, 'https://beta.tcgtracking.com/v1/meta');
  assert.ok(!collection.item.some(item => item.request.url.includes('/research')));
  assert.ok(!collection.variable.some(item => Object.hasOwn(credentials, item.key)));
});

test('one collection run preserves public zero/null context and exact Beta SKU windows without a sold-average fallback', () => {
  const h = ready(); const meta = h.run(2, index); assert.equal(meta.summary.beta_index.status, 'set_indexed');
  const result = h.run(3, betaFixture());
  assert.ok(result.tests.every(item => item.passed));
  assert.equal(result.summary.public.status, 'available'); assert.equal(result.summary.public.price_context.mkt, 0);
  assert.equal(result.summary.public.price_context.hi, null); assert.equal(result.summary.public.price_context.cnt, 0);
  assert.equal(result.summary.opportunities.sku_id, '1001'); assert.equal(result.summary.opportunities.pricing.avg_30d, 12);
  assert.equal(result.summary.opportunities.trends.windows['30d'].tcg_sold_avg, null);
  assert.equal(result.summary.opportunities.trends.windows['90d'].tcg_sold_avg, 10);
  assert.equal(result.summary.opportunities.marketplaces.tcgplayer.listings[0].price, 0);
  assert.equal(result.summary.opportunities.marketplaces.tcgplayer.listings[0].ship_price, null);
  assert.ok(result.visualizer.template.includes('{{summary}}'));
  assert.equal(JSON.parse(result.visualizer.data.summary).opportunities.status, 'available');
});

test('public credentials are absent while only fixed Beta requests get private environment headers', () => {
  const h = harness(); const first = h.run(1, publicFixture()); const second = h.run(2, index); const third = h.run(3, betaFixture());
  assert.equal(first.headers.get('x-api-key'), undefined); assert.equal(first.headers.get('x-shipper-id'), undefined);
  for (const result of [first, second, third]) assert.equal(result.headers.get('authorization'), undefined);
  for (const result of [second, third]) { assert.equal(result.headers.get('x-shipper-id'), '123'); assert.equal(result.headers.get('x-api-key'), credentials.tcgt_beta_key); }
  assert.equal(third.url, 'https://beta.tcgtracking.com/v1/3/sets/22872');
});

test('missing Beta credentials and denied auth cannot stop public pricing or request 03 visualization', () => {
  const h = ready({});
  const meta = h.run(2, { error: 'requires account' }, { code: 401 });
  assert.equal(meta.next, undefined); assert.equal(meta.skipped, false);
  const result = h.run(3, { error: 'denied' }, { code: 403 });
  assert.equal(result.summary.public.status, 'available'); assert.equal(result.summary.opportunities.status, 'http_error');
  assert.equal(result.summary.opportunities.http_status, 403);
  assert.equal(result.summary.opportunities.credentials, 'missing_or_invalid_local_values');
  assert.ok(result.visualizer); assert.equal(result.headers.get('x-api-key'), undefined);
});

test('optional meta discovery reports a unique hint but never changes the public target group', () => {
  const h = ready();
  const result = h.run(2, { categories: { 3: { sets: { 99999: { group_id: 99999, set_name: 'SV: Scarlet & Violet Promo Cards' } } } } });
  assert.equal(result.summary.beta_index.status, 'set_not_indexed');
  assert.equal(result.summary.beta_index.exact_set_name_hint.group_id, '99999');
  assert.equal(result.summary.beta_index.group_was_changed, false);
  assert.equal(h.values.get('tcgt_market_group_id'), '22872');
  const third = h.run(3, betaFixture()); assert.equal(third.url, 'https://beta.tcgtracking.com/v1/3/sets/22872');
  assert.equal(third.summary.public.status, 'available');
});

test('HTTP success and product/SKU missing coverage are separate tests and statuses', () => {
  const h = ready();
  const absent = betaFixture(); absent.products = { 42: { product_id: 42, name: 'Other card', skus: {} } };
  const result = h.run(3, absent);
  assert.equal(result.summary.opportunities.status, 'product_missing'); assert.equal(result.summary.opportunities.http_status, 200);
  assert.ok(result.tests.find(item => item.name === 'Beta exact SKU HTTP 200').passed);
  assert.ok(result.tests.some(item => !item.passed));
  const missingSKU = h.run(3, betaFixture({})); assert.equal(missingSKU.summary.opportunities.status, 'sku_missing');
});

test('exact public variant must have one SKU and null/missing public price stays unavailable while zero is retained', () => {
  const h = harness();
  const row = { cnd: 'NM', var: 'Holofoil', lng: 'EN', mkt: null };
  const ambiguous = h.run(1, publicFixture({ 1001: row, 1002: row })); assert.equal(ambiguous.summary.public.status, 'sku_ambiguous');
  for (const mkt of [null, undefined]) {
    const result = h.run(1, publicFixture({ 1001: { ...row, mkt } }));
    assert.equal(result.summary.public.status, 'available'); assert.equal(result.summary.public.price_status, 'unavailable');
  }
  assert.equal(h.run(1, publicFixture()).summary.public.price_context.mkt, 0);
});

test('another condition, language, printing or SKU never substitutes for the public exact SKU', () => {
  for (const mutate of [row => { row.language = 'Japanese'; }, row => { row.finish = 'Normal'; }, row => { row.condition_id = 2; row.condition = 'Lightly Played'; }]) {
    const body = betaFixture(); mutate(body.products[512035].skus[1001]);
    assert.equal(ready().run(3, body).summary.opportunities.status, 'sku_missing');
  }
  const body = betaFixture(); body.products[512035].skus[1002] = { ...body.products[512035].skus[1001], sku_id: 1002 }; delete body.products[512035].skus[1001];
  assert.equal(ready().run(3, body).summary.opportunities.status, 'sku_missing');
});

test('schema and category/group/product/SKU identity mismatches do not masquerade as missing coverage', () => {
  const variants = [
    [1, () => ({ products: {} }), 'identity_mismatch'],
    [1, () => ({ ...publicFixture(), category_id: 2 }), 'identity_mismatch'],
    [1, () => ({ ...publicFixture(), set_id: 1 }), 'identity_mismatch'],
    [3, () => ({ ...betaFixture(), meta: { schema_version: '2.0', category_id: 3, group_id: 1 } }), 'identity_mismatch'],
    [3, () => { const body = betaFixture(); body.products[512035].product_id = 1; return body; }, 'invalid_product'],
    [3, () => { const body = betaFixture(); body.products[512035].skus[1001].sku_id = 1002; return body; }, 'invalid_sku'],
    [3, () => { const body = betaFixture(); body.products[512035].skus[1001].pricing.market_sku = {}; return body; }, 'invalid_response'],
    [3, () => { const body = betaFixture(); body.products['p:512035'] = body.products[512035]; return body; }, 'unexpected_product_keys'],
  ];
  for (const [number, fixture, expected] of variants) {
    const result = ready().run(number, fixture()); assert.equal(result.summary[number === 1 ? 'public' : 'opportunities'].status, expected);
  }
  assert.equal(ready().run(3, null, { malformed: true }).summary.opportunities.status, 'invalid_response');
});

test('unsafe hosts, queries, path injection and stale target comparisons are blocked or cleared', () => {
  const h = ready();
  const unsafe = h.run(3, betaFixture(), { url: 'https://evil.example/v1/3/sets/22872' });
  assert.equal(unsafe.skipped, true); assert.equal(unsafe.headers.get('x-api-key'), undefined);
  assert.equal(ready().run(3, betaFixture(), { url: 'https://beta.tcgtracking.com/v1/3/sets/22872?url=https://evil.example' }).skipped, true);
  h.values.set('tcgt_market_group_id', '3/../../evil'); assert.equal(h.run(1, publicFixture()).skipped, true);
  const changed = ready(); changed.values.set('tcgt_market_group_id', '99999');
  const result = changed.run(3, betaFixture());
  assert.equal(result.summary.public.status, 'not_run'); assert.equal(result.summary.opportunities.status, 'identity_mismatch');
});

test('new public run clears old Beta success, shareable summaries omit headers/secrets and raw provider errors', () => {
  const h = ready(); h.run(2, index); const result = h.run(3, betaFixture());
  assert.ok(!JSON.stringify(result.summary).includes(credentials.tcgt_beta_key));
  assert.ok(!JSON.stringify(result.logs).includes(credentials.tcgt_beta_key));
  assert.ok(!JSON.stringify(result.visualizer).includes(credentials.tcgt_beta_key));
  const newRun = h.run(1, publicFixture()); assert.equal(newRun.summary.opportunities.status, 'not_run'); assert.equal(newRun.summary.beta_index.status, 'not_run');
  const failed = h.run(3, { authtoken: credentials.tcgt_beta_key, client_ip: '192.0.2.1' }, { code: 403 });
  assert.ok(!JSON.stringify(failed.summary).includes('192.0.2.1')); assert.ok(!JSON.stringify(failed.summary).includes(credentials.tcgt_beta_key));
});

test('nullable documented SKU ID, explicit missing fields and decimal strings are preserved', () => {
  const body = betaFixture(); const row = body.products[512035].skus[1001];
  row.sku_id = null; row.pricing.market_sku = '0.00'; delete row.pricing.direct_low_card;
  const result = ready().run(3, body);
  assert.equal(result.summary.opportunities.status, 'available'); assert.equal(result.summary.opportunities.pricing.market_sku, '0.00');
  assert.equal(Object.hasOwn(result.summary.opportunities.pricing, 'direct_low_card'), false);
});
