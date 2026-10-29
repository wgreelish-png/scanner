import test from 'node:test';
import assert from 'node:assert/strict';
import { createResearchHandler, MAX_RESPONSE_BYTES } from '../src/research.mjs';

// Synthetic contract fixtures only. These IDs, values and counts are not live
// Research API coverage or evidence of an actual PSA certificate or sale.
const TOKEN = 'device-token-for-tests-0000000000000000';
const KEY = 'tcgt_beta_' + 'a'.repeat(48);
// These focused shard-contract fixtures deliberately omit index traffic. The
// production-default daily/index/budget integration is covered in cadence.test.
const options = { shipperID: '123', apiKey: KEY, deviceToken: TOKEN, syncIndex: false, ttlMs: 3_600_000 };
const PATH = '/api/v1/research/3/42/101';
const UPSTREAM = 'https://beta.tcgtracking.com/v1/3/sets/42/research';

function shard(group = 42, category = 3) {
  return {
    meta: {
      schema_version: '2.0-testing', status: 'in_testing', category_id: category,
      game_name: 'Synthetic Fixture Game', group_id: group, set_name: 'Synthetic Fixture Set',
      generated_at: '2026-10-28T00:00:00Z', etag: 'synthetic-data-hash',
      product_count: 2, grade_row_count: 3,
    },
    products: {
      101: {
        product_id: 101, name: 'Synthetic Fixture Card', ext_number: '1/10',
        catalog_market_price: 0,
        variants: {
          'EN:Normal': {
            language: 'EN', finish: 'Normal', updated_at: '2026-10-27T23:00:00Z',
            summary: { raw_guide_value: 0, psa10_guide_value: 120, total_grades_tracked: 2, total_sales_recorded: 0 },
            grades: [
              {
                grader: 'PSA', grade: '10', grade_sort: 10, pop: null, sales: 0,
                guide_value: 120, market_value: 110, confidence: 2,
                last_sold_at: null, synced_on: '2026-10-27',
                daily_history: {
                  updated_at: '2026-10-27T23:00:00Z',
                  stats: {
                    last_sale: { price: 0, date: '2026-10-26' },
                    month: { sales: 0, avg: null, low: null, high: null },
                    year: { sales: 2, avg: 120, low: 110, high: 130 },
                  },
                  series: [['2026-10-26', 2, 120], ['2026-10-28', 0, null]],
                },
              },
              { grader: 'RAW', grade: 'Raw', grade_sort: 0, pop: null, sales: 0, guide_value: 0 },
            ],
          },
          'EN:Holofoil': {
            language: 'EN', finish: 'Holofoil',
            grades: [{ grader: 'PSA', grade: '9', grade_sort: 9, pop: 0, sales: 2, guide_value: 9, market_value: null }],
          },
        },
      },
      202: { product_id: 202, name: 'Another Synthetic Card', variants: {} },
    },
  };
}

function request(path = PATH, token = TOKEN, method = 'GET') {
  const headers = token == null ? {} : { Authorization: `Bearer ${token}` };
  return new Request(`https://research.example.test${path}`, { method, headers });
}

function upstreamReply(body, { status = 200, etag = '"synthetic-http-etag"', headers = {} } = {}) {
  const response = new Response(status === 304 ? null : (typeof body === 'string' ? body : JSON.stringify(body)), {
    status, headers: { 'Content-Type': 'application/json', ...(etag == null ? {} : { ETag: etag }), ...headers },
  });
  return response;
}

function loader(replies) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    const inputURL = url instanceof Request ? url.url : String(url);
    calls.push({ url: inputURL, init, headers: new Headers(init.headers ?? (url instanceof Request ? url.headers : {})) });
    const reply = replies.shift();
    assert.ok(reply, 'Unexpected upstream request');
    if (reply instanceof Error) throw reply;
    Object.defineProperty(reply, 'url', { configurable: true, value: inputURL });
    return reply;
  };
  return { calls, fetchImpl };
}

test('health is public and reveals no credential or configuration values', async () => {
  const upstream = loader([]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  const response = await handle(request('/health', null));
  assert.equal(response.status, 200);
  const text = await response.text();
  assert.equal(JSON.parse(text).status, 'ok');
  assert.ok(!text.includes(TOKEN)); assert.ok(!text.includes(KEY));
  assert.equal(upstream.calls.length, 0);
});

test('phone authorization is required and is never forwarded as Beta authentication', async () => {
  const upstream = loader([upstreamReply(shard())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const token of [null, '', 'wrong', `${TOKEN}wrong`]) {
    const response = await handle(request(PATH, token));
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error.code, 'unauthorized');
  }
  assert.equal(upstream.calls.length, 0);
  const success = await handle(request());
  assert.equal(success.status, 200);
  assert.equal(upstream.calls.length, 1);
  const call = upstream.calls[0];
  assert.equal(call.url, UPSTREAM);
  assert.equal(call.headers.get('X-Shipper-Id'), '123');
  assert.equal(call.headers.get('X-Api-Key'), KEY);
  assert.equal(call.headers.get('Authorization'), null);
  assert.equal(call.init.redirect, 'error');
  const text = await success.text();
  assert.ok(!text.includes(TOKEN)); assert.ok(!text.includes(KEY));
});

test('returns only the exact requested product and preserves real fields, sparse history and zero/null/missing', async () => {
  const fixture = shard();
  const upstream = loader([upstreamReply(fixture)]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  const response = await handle(request());
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.meta, fixture.meta);
  assert.deepEqual(body.product, fixture.products[101]);
  assert.equal(body.products, undefined);
  assert.equal(body.product.catalog_market_price, 0);
  assert.equal(body.product.variants['EN:Normal'].grades[0].market_value, 110);
  assert.equal(body.product.variants['EN:Holofoil'].grades[0].market_value, null);
  assert.equal('market_value' in body.product.variants['EN:Normal'].grades[1], false);
  assert.equal(body.product.variants['EN:Normal'].grades[0].daily_history.series.length, 2);
});

test('an uncovered set and a missing product are different responses', async () => {
  const uncovered = createResearchHandler({ ...options, fetchImpl: loader([upstreamReply({}, { status: 404 })]).fetchImpl });
  const absent = await uncovered(request());
  assert.equal(absent.status, 404);
  assert.equal((await absent.json()).error.code, 'not_covered');
  const available = createResearchHandler({ ...options, fetchImpl: loader([upstreamReply(shard())]).fetchImpl });
  const missing = await available(request('/api/v1/research/3/42/999'));
  assert.equal(missing.status, 404);
  assert.equal((await missing.json()).error.code, 'product_not_covered');
});

test('rejects unsupported categories, noncanonical IDs, queries and encoded path manipulation before fetching', async () => {
  const upstream = loader([]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const path of [
    '/api/v1/research/4/42/101', '/api/v1/research/3/0/101', '/api/v1/research/3/42/0101',
    '/api/v1/research/3/42/1e2', '/api/v1/research/3/42/1234567890123',
    '/api/v1/research/3/42/%31%30%31', '/api/v1/research/3/42/101?url=https://evil.example/',
    '/api/v1/research/3/42/101/extra', '/api/v1/research/3/42/101?refresh=1',
  ]) {
    const response = await handle(request(path));
    assert.ok(response.status >= 400 && response.status < 500, path);
  }
  assert.equal(upstream.calls.length, 0);
});

test('rejects methods that could mutate data', async () => {
  const upstream = loader([]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const method of ['POST', 'PUT', 'DELETE']) {
    const response = await handle(request(PATH, TOKEN, method));
    assert.equal(response.status, 405);
  }
  assert.equal(upstream.calls.length, 0);
});

test('validates category/set/product identity and JSON structure before caching', async () => {
  const wrongProduct = shard(); wrongProduct.products[101].product_id = 202;
  const wrongCategory = shard(42, 2);
  const wrongSet = shard(43);
  for (const body of ['not JSON', {}, wrongCategory, wrongSet, wrongProduct]) {
    const upstream = loader([upstreamReply(body)]);
    const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
    const response = await handle(request());
    assert.equal(response.status, 502);
    assert.equal((await response.json()).error.code, 'upstream_invalid_response');
  }
});

test('upstream credentials, denied IP addresses and arbitrary failure bodies never leak to the phone', async () => {
  for (const status of [401, 403]) {
    const secretBody = { error: `secret ${KEY}`, client_ip: '192.0.2.55' };
    const handle = createResearchHandler({ ...options, fetchImpl: loader([upstreamReply(secretBody, { status })]).fetchImpl });
    const response = await handle(request());
    assert.equal(response.status, 502);
    const text = await response.text();
    assert.equal(JSON.parse(text).error.code, 'research_access_denied');
    assert.ok(!text.includes(KEY)); assert.ok(!text.includes('192.0.2.55'));
  }
  const handle = createResearchHandler({ ...options, fetchImpl: loader([new Error(`private upstream ${KEY}`)]).fetchImpl });
  const response = await handle(request());
  assert.ok(response.status >= 500);
  assert.ok(!(await response.text()).includes(KEY));
});

test('response size is bounded even when a valid JSON response contains a large unused field', async () => {
  const body = shard(); body.padding = 'x'.repeat(MAX_RESPONSE_BYTES);
  const handle = createResearchHandler({ ...options, fetchImpl: loader([upstreamReply(body)]).fetchImpl });
  const response = await handle(request());
  assert.equal(response.status, 502);
  assert.equal((await response.json()).error.code, 'upstream_response_too_large');
});

test('fresh set data serves other products from the same set, then uses ETag revalidation after one hour', async () => {
  let clock = 1_800_000_000_000;
  const fixture = shard();
  const upstream = loader([upstreamReply(fixture), upstreamReply(null, { status: 304 })]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, now: () => clock });
  const first = await handle(request()); assert.equal(first.status, 200);
  const second = await handle(request('/api/v1/research/3/42/202')); assert.equal(second.status, 200);
  assert.equal((await second.json()).product.product_id, 202);
  assert.equal(upstream.calls.length, 1);
  clock += 3_600_001;
  const revalidated = await handle(request());
  assert.equal(revalidated.status, 200);
  assert.deepEqual((await revalidated.json()).meta, fixture.meta, '304 must not invent a newer provider timestamp');
  assert.equal(upstream.calls.length, 2);
  assert.equal(upstream.calls[1].headers.get('If-None-Match'), '"synthetic-http-etag"');
});

test('expired data is not an invisible stale fallback when refresh fails', async () => {
  let clock = 1_800_000_000_000;
  const upstream = loader([upstreamReply(shard()), upstreamReply({}, { status: 503 }), upstreamReply(shard())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, now: () => clock });
  assert.equal((await handle(request())).status, 200);
  clock += 3_600_001;
  const failed = await handle(request());
  assert.ok(failed.status >= 500);
  const retryAfter = Number(failed.headers.get('Retry-After'));
  assert.ok(retryAfter > 0, 'Provider retry deadline must be visible to the phone');
  assert.equal((await failed.json()).product, undefined);
  const coolingDown = await handle(request());
  assert.equal(coolingDown.status, 503);
  assert.equal(upstream.calls.length, 2, 'Retry-After prevents hammering the upstream while expired data stays unavailable');
  clock += retryAfter * 1000 + 1;
  assert.equal((await handle(request())).status, 200);
  assert.equal(upstream.calls.length, 3);
});

test('the cache retains at most four sets', async () => {
  const upstream = loader([42, 43, 44, 45, 46, 42].map(group => upstreamReply(shard(group))));
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl });
  for (const group of [42, 43, 44, 45, 46, 42]) {
    const response = await handle(request(`/api/v1/research/3/${group}/101`));
    assert.equal(response.status, 200);
  }
  assert.equal(upstream.calls.length, 6);
});

test('concurrent lookups for the same set share the upstream request', async () => {
  let resolve;
  let calls = 0;
  const fetchImpl = async url => {
    calls += 1;
    const response = await new Promise(accept => { resolve = accept; });
    Object.defineProperty(response, 'url', { value: String(url) });
    return response;
  };
  const handle = createResearchHandler({ ...options, fetchImpl });
  const first = handle(request());
  const second = handle(request('/api/v1/research/3/42/202'));
  await new Promise(accept => setImmediate(accept));
  assert.equal(calls, 1);
  resolve(upstreamReply(shard()));
  const responses = await Promise.all([first, second]);
  assert.deepEqual(responses.map(response => response.status), [200, 200]);
});

test('rate limiting has a retry deadline and cannot be bypassed by a fresh set ID', async () => {
  const upstream = loader([upstreamReply(shard())]);
  const handle = createResearchHandler({ ...options, fetchImpl: upstream.fetchImpl, maxRequestsPerMinute: 2 });
  assert.equal((await handle(request())).status, 200);
  assert.equal((await handle(request())).status, 200);
  const blocked = await handle(request('/api/v1/research/3/999/101'));
  assert.equal(blocked.status, 429);
  assert.equal((await blocked.json()).error.code, 'rate_limited');
  assert.ok(Number(blocked.headers.get('Retry-After')) > 0);
  assert.equal(upstream.calls.length, 1);
});

test('PSA requires an independently configured resolver and preserves the certificate as a string', async () => {
  const handle = createResearchHandler({ ...options, fetchImpl: loader([]).fetchImpl });
  const missing = await handle(request('/api/v1/psa/cert/00123456'));
  assert.equal(missing.status, 501);
  assert.equal((await missing.json()).error.code, 'psa_not_configured');
  const received = [];
  const normalized = {
    certificateNumber: '00123456', grader: 'PSA', grade: '10', name: 'Synthetic Fixture Card',
    year: '2001', set: 'Synthetic Fixture Set', number: '1/10', language: 'English',
    printing: 'Holofoil', source: 'Synthetic test adapter',
  };
  const configured = createResearchHandler({ ...options, fetchImpl: loader([]).fetchImpl,
    psaLookup: async certificate => { received.push(certificate); return normalized; } });
  const result = await configured(request('/api/v1/psa/cert/00123456'));
  assert.equal(result.status, 200);
  const body = await result.json();
  assert.deepEqual(received, ['00123456']);
  assert.equal(JSON.stringify(body).includes('00123456'), true);
  assert.equal(body.product_id, undefined, 'The resolver must not manufacture a catalog product match');
});

test('invalid certificate paths never invoke the PSA adapter; a mismatched returned cert is rejected', async () => {
  let calls = 0;
  const handle = createResearchHandler({ ...options, fetchImpl: loader([]).fetchImpl,
    psaLookup: async () => { calls += 1; return { certificateNumber: '99999999', grader: 'PSA', grade: '10', name: 'Synthetic Fixture', source: 'Synthetic adapter' }; } });
  for (const cert of ['12345', '1234567890123', 'abc12345', '1234%205678']) {
    const response = await handle(request('/api/v1/psa/cert/' + cert));
    assert.ok(response.status >= 400 && response.status < 500);
  }
  assert.equal(calls, 0);
  const mismatch = await handle(request('/api/v1/psa/cert/00123456'));
  assert.equal(mismatch.status, 502);
  assert.equal(calls, 1);
});
