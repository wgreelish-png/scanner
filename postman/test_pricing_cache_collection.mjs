import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Buffer } from 'node:buffer';
import test from 'node:test';
import vm from 'node:vm';

const collection = JSON.parse(readFileSync(new URL('./TCGTracking-Pricing-Cache-Measurement.postman_collection.json', import.meta.url)));
const pre = collection.event.find(event => event.listen === 'prerequest').script.exec.join('\n');
const post = collection.event.find(event => event.listen === 'test').script.exec.join('\n');
const names = collection.item.map(item => item.name);
const categories = { categories: [{ id: 3, name: 'Pokémon' }] };
function sets(ids = [10, 20]) { return { category_id: 3, sets: ids.map(id => ({ id, name: 'Synthetic set' })) }; }
function cards(setID = 10, ids = [100, 101]) { return { set_id: setID, products: ids.map(id => ({ id, name: 'Pokémon synthetic' })) }; }
function skus(setID = 10) { return { set_id: setID, updated: '2026-10-31T09:35:00Z', product_count: 2, sku_count: 3, products: {
  100: { 9001: { cnd: 'NM', var: 'Normal', var_a: 'N', vid: 1, lng: 'EN', mkt: 0 }, 9002: { cnd: 'LP', var: 'Normal', lng: 'EN', mkt: null } },
  200: { 9003: { cnd: 'NM', var: 'Holofoil', lng: 'EN', mkt: '1.25' } },
} }; }
function harness(config = {}, { fallbackBytes = false } = {}) {
  const values = new Map(collection.variable.map(item => [item.key, item.value]));
  for (const [key, value] of Object.entries(config)) values.set(key, String(value));
  const history = [];
  let now = Date.now();
  class MockDate extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  function run(number, body, options = {}) {
    const item = collection.item[number - 1];
    const locals = new Map(Object.entries(options.environment || {}));
    const headers = new Map([...item.request.header.map(item => [item.key.toLowerCase(), item.value]), ...Object.entries(options.requestHeaders || {}).map(([key, value]) => [key.toLowerCase(), value])]);
    const responseHeaders = new Map(Object.entries(options.headers || {}).map(([key, value]) => [key.toLowerCase(), value]));
    const output = { name: item.name, headers, tests: [], logs: [], timers: [], skipped: false };
    const variables = {
      get: key => locals.has(key) ? locals.get(key) : values.get(key),
      set: (key, value) => locals.set(key, value),
      replaceIn(text) { return text.replace(/\{\{([^}]+)\}\}/g, (_, key) => this.get(key) ?? '{{' + key + '}}'); },
    };
    const pm = {
      info: { requestName: item.name }, variables,
      collectionVariables: { get: key => values.get(key), set: (key, value) => values.set(key, value), unset: key => values.delete(key) },
      request: { method: options.method || item.request.method, url: { toString: () => options.url || item.request.url }, headers: { remove: key => headers.delete(key.toLowerCase()) } },
      response: { code: options.code ?? 200, responseTime: options.responseTime ?? 25,
        responseSize: options.responseSize,
        text: () => options.text ?? JSON.stringify(body),
        headers: { get: key => responseHeaders.get(key.toLowerCase()) },
      },
      execution: { skipRequest: () => { output.skipped = true; }, setNextRequest: name => { output.next = name; } },
      test(name, fn) { try { fn(); output.tests.push({ name, passed: true }); } catch (error) { output.tests.push({ name, passed: false, error: error.message }); } },
      visualizer: { set: (template, data) => { output.visualizer = { template, data }; } },
    };
    const context = vm.createContext({ pm, Date: MockDate, ...(fallbackBytes ? {} : { Buffer }), require: fallbackBytes ? () => { throw Error('No buffer module'); } : () => ({ Buffer }), console: { log: (...args) => output.logs.push(args) }, setTimeout: (fn, ms) => { output.timers.push(ms); fn(); } });
    try { vm.runInContext(pre, context); } catch (error) { output.preError = error.message; }
    output.url = variables.replaceIn(options.url || item.request.url);
    if (!output.skipped && !output.preError) {
      try { vm.runInContext(post, context); } catch (error) { output.postError = error.message; }
    }
    if (values.get('tcgt_cache_summary')) output.summary = JSON.parse(values.get('tcgt_cache_summary'));
    history.push(output);
    return output;
  }
  return { values, run, history, advance: seconds => { now += seconds * 1000; } };
}
function discover(config = {}, ids = [10, 20], options) { const h = harness(config, options); h.run(1, categories); h.run(2, sets(ids)); return h; }
function complete(h, ids) { for (const id of ids) { h.run(3, cards(id)); h.run(4, skus(id)); } return h.history.at(-1); }
function resume(h, number, body, options = {}) {
  h.values.set('tcgt_cache_resume', 'true');
  for (let preceding = 1; preceding < number; preceding += 1) assert.equal(h.run(preceding, {}).skipped, true);
  return h.run(number, body, options);
}
function noScriptErrors(h) { for (const output of h.history) { assert.equal(output.preError, undefined); assert.equal(output.postError, undefined); } }

test('collection is standalone public GET-only, fixed host, no auth, redirects or embedded credentials', () => {
  assert.equal(collection.info.schema, 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json');
  assert.equal(collection.item.length, 4); assert.equal(collection.auth.type, 'noauth');
  assert.ok(collection.item.every(item => item.request.method === 'GET' && item.request.auth.type === 'noauth' && item.protocolProfileBehavior.followRedirects === false && item.protocolProfileBehavior.disableCookies === true));
  assert.ok(collection.item.every(item => item.request.url.startsWith('https://openapi.tcgtracking.com/v1/')));
  assert.ok(!collection.variable.some(item => /key|token|shipper|cookie|credential|secret/i.test(item.key)));
});

test('full run loops sets and produces complete measured totals, counts and explicit byte definitions', () => {
  const h = discover({ tcgt_cache_mode: 'full' });
  const first = h.run(3, cards()); assert.equal(first.next, names[3]);
  const second = h.run(4, skus()); assert.equal(second.next, names[2]);
  h.run(3, cards(20)); const result = h.run(4, skus(20));
  noScriptErrors(h); assert.equal(result.next, null);
  assert.equal(result.summary.status, 'completed'); assert.equal(result.summary.coverage_complete, true);
  assert.equal(result.summary.successful_set_count, 2); assert.equal(result.summary.measured.card_product_count, 4);
  assert.equal(result.summary.measured.sku_product_count, 4); assert.equal(result.summary.measured.sku_count, 6);
  assert.equal(result.summary.measured.card_matched_sku_count, 4); assert.equal(result.summary.measured.card_join_set_count, 2);
  assert.equal(result.summary.measured.known_market_quote_count, 4); assert.equal(result.summary.measured.zero_market_quote_count, 2); assert.equal(result.summary.measured.missing_market_quote_count, 2);
  assert.equal(result.summary.full_category_planning.basis, 'measured_complete_full_run'); assert.equal(result.summary.full_category_planning.estimate_only, false);
  assert.equal(result.summary.full_category_planning.daily_skus_decoded_bytes, result.summary.measured.daily_skus_decoded_bytes);
  assert.equal(result.summary.measured.initial_cards_and_skus_decoded_bytes, result.summary.measured.static_cards_decoded_bytes + result.summary.measured.daily_skus_decoded_bytes);
  assert.equal(result.summary.full_category_planning.initial_cards_and_skus_decoded_bytes, result.summary.measured.initial_cards_and_skus_decoded_bytes);
  assert.equal(result.summary.full_category_planning.two_snapshot_staging_bytes, 2 * result.summary.measured.combined_validated_decoded_bytes);
  assert.equal(result.summary.device_offline_behavior_verified, false); assert.ok(result.visualizer.template.includes('{{summary}}'));
});

test('sample chooses deterministic evenly spaced numeric IDs, labels extrapolation and excludes offline claims', () => {
  const h = discover({ tcgt_cache_sample_size: 3 }, [50, 20, 40, 10, 30]);
  const initial = JSON.parse(h.values.get('tcgt_cache_summary')); assert.deepEqual(initial.selected_set_ids, [10, 30, 50]);
  const result = complete(h, [10, 30, 50]); noScriptErrors(h);
  assert.equal(result.summary.coverage_complete, false); assert.equal(result.summary.total_discovered_sets, 5);
  assert.equal(result.summary.full_category_planning.basis, 'sample_extrapolation_not_guaranteed');
  assert.equal(result.summary.full_category_planning.daily_skus_decoded_bytes, Math.round(result.summary.measured.daily_skus_decoded_bytes * 5 / 3));
  assert.equal(result.summary.current_app_cache_limits.discovered_sets_exceed_limit, true);
});

test('single-set samples choose the midpoint; full mode includes every set regardless of sample size', () => {
  const one = discover({ tcgt_cache_sample_size: 1 }, [1, 2, 3, 4, 5]);
  assert.deepEqual(JSON.parse(one.values.get('tcgt_cache_summary')).selected_set_ids, [3]);
  const full = discover({ tcgt_cache_mode: 'full', tcgt_cache_sample_size: 1 }, [5, 2, 3]);
  assert.deepEqual(JSON.parse(full.values.get('tcgt_cache_summary')).selected_set_ids, [2, 3, 5]);
});

test('decoded UTF-8 bytes handle non-ASCII and fallback without TextEncoder or buffer support', () => {
  for (const fallbackBytes of [false, true]) {
    const h = discover({}, [10], { fallbackBytes });
    const text = JSON.stringify({ products: [{ id: 100, name: 'Pokémon 日本語 🃏 \ud800' }] });
    const result = h.run(3, null, { text }); noScriptErrors(h);
    assert.equal(result.summary.measurements[0].decoded_body_bytes, Buffer.byteLength(text, 'utf8'));
    assert.ok(Buffer.byteLength(text, 'utf8') > text.length);
  }
});

test('Content-Length, encoding and runtime responseSize stay separate from decoded text size', () => {
  const h = discover({}, [10]);
  const result = h.run(3, cards(), { headers: { 'Content-Length': '99', 'Content-Encoding': 'gzip' }, responseSize: 777 });
  const row = result.summary.measurements[0]; assert.equal(row.content_length_bytes, 99); assert.equal(row.content_encoding, 'gzip'); assert.equal(row.runtime_reported_response_size_bytes, 777);
  assert.equal(row.decoded_body_bytes, Buffer.byteLength(JSON.stringify(cards()), 'utf8')); assert.notEqual(row.decoded_body_bytes, 99);
  const next = h.run(4, skus(), { headers: { 'Content-Length': '-2' } }); assert.equal(next.summary.measurements[1].content_length_bytes, undefined);
  assert.equal(next.summary.measured.content_length_response_count, 1);
});

test('zero products and zero SKUs are valid and distinct from unsupported or missing fields', () => {
  const h = discover({}, [10]); h.run(3, { products: [] });
  const result = h.run(4, { set_id: 10, products: {}, product_count: 0, sku_count: 0 }); noScriptErrors(h);
  assert.equal(result.summary.status, 'completed'); assert.equal(result.summary.measured.sku_count, 0); assert.equal(result.summary.measured.card_product_count, 0);
  const bad = discover({}, [10]); bad.run(3, {}); const failure = bad.run(4, { set_id: 10 });
  assert.equal(failure.summary.status, 'partial'); assert.equal(failure.summary.successful_set_count, 0);
});

test('unknown optional categories wrapper warns and continues fixed configured category without guessing', () => {
  const h = harness(); const result = h.run(1, { unexpected: [] });
  assert.equal(result.next, names[1]); assert.equal(result.summary.discovery.categories.status, 'unsupported_discovery_contract'); assert.equal(result.summary.warnings.length, 1);
  h.run(2, sets([10])); const final = complete(h, [10]); noScriptErrors(h); assert.equal(final.summary.status, 'completed');
});

test('set discovery fails closed for missing wrappers, empty/duplicate IDs, conflicting aliases and wrong category', () => {
  for (const body of [{ groups: [{ id: 10 }] }, { sets: [] }, { sets: [{ id: 10 }, { set_id: 10 }] }, { sets: [{ id: 10, group_id: 11 }] }, { category_id: 2, sets: [{ id: 10 }] }, { sets: Array.from({ length: 2001 }, (_, index) => ({ id: index + 1 })) }]) {
    const h = harness(); h.run(1, categories); const result = h.run(2, body); noScriptErrors(h);
    assert.equal(result.next, null); assert.equal(result.summary.status, 'halted'); assert.equal(result.summary.selected_set_count, 0);
  }
});

test('explicit agreeing discovery aliases work without importing Beta schemas', () => {
  const h = harness(); h.run(1, { categories: [{ category_id: 3, id: 3, name: 'Pokemon' }] });
  const result = h.run(2, { sets: [{ set_id: 10, group_id: 10, id: 10 }, { group_id: 20 }] });
  noScriptErrors(h); assert.deepEqual(result.summary.selected_set_ids, [10, 20]);
});

test('HTTP failures are partial and never inflate a full-run coverage or sample estimate', () => {
  const h = discover({ tcgt_cache_mode: 'full' }); h.run(3, cards()); h.run(4, { error: 'private text omitted' }, { code: 401 });
  const result = complete(h, [20]); noScriptErrors(h);
  assert.equal(result.summary.status, 'partial'); assert.equal(result.summary.successful_set_count, 1); assert.equal(result.summary.failed_endpoint_count, 1); assert.equal(result.summary.coverage_complete, false);
  assert.equal(result.summary.full_category_planning.daily_skus_decoded_bytes, null); assert.ok(!JSON.stringify(result.summary).includes('private text omitted'));
});

test('SKU contract requires matching identity, nested rows, actual counts, dimensions and valid market quotes', () => {
  const invalidBodies = [ { ...skus(), set_id: 11 }, { ...skus(), category_id: 2 }, { ...skus(), sku_count: 99 }, { products: skus().products }, { set_id: 10, products: { 100: [] } }, { set_id: 10, products: { 100: { 9001: { cnd: 'NM', lng: 'EN', mkt: 1 } } } }, { set_id: 10, products: { 100: { 9001: { cnd: 'NM', var: 'Normal', lng: 'EN', mkt: true } } } } ];
  for (const body of invalidBodies) {
    const h = discover({}, [10]); h.run(3, cards()); const result = h.run(4, body); noScriptErrors(h);
    assert.equal(result.summary.status, 'partial'); assert.equal(result.summary.measurements[1].status, 'unsupported_schema_or_identity'); assert.equal(result.summary.measured.sku_count, 0);
  }
});

test('bad JSON is recorded without storing raw bodies; bad card IDs do not produce a false join', () => {
  const h = discover({}, [10]); h.run(3, null, { text: 'not json with arbitrary private message' }); const result = h.run(4, skus());
  assert.equal(result.summary.measurements[0].status, 'invalid_json'); assert.equal(result.summary.measurements[1].card_join_available, false); assert.equal(result.summary.measured.card_join_set_count, 0);
  assert.ok(!h.values.get('tcgt_cache_state').includes('private message'));
  const duplicate = discover({}, [10]); const bad = duplicate.run(3, cards(10, [100, 100])); assert.equal(bad.summary.measurements[0].status, 'unsupported_schema_or_identity');
});

test('429/503 stops for explicit resume and limits additional attempts across resumes', () => {
  const h = discover({}, [10]); h.run(3, cards());
  const first = h.run(4, { error: 'busy' }, { code: 429, headers: { 'Retry-After': '1' } });
  assert.equal(first.next, null); assert.equal(first.summary.status, 'retry_waiting');
  assert.equal(first.summary.resume_request, names[3]); assert.equal(first.summary.retry_after_seconds, 1);
  assert.deepEqual(first.timers, [1000]); // Only normal rate delay; no Retry-After sleep.
  h.advance(1);
  const second = resume(h, 4, { error: 'busy' }, { code: 503, headers: { 'Retry-After': '0' } });
  assert.equal(second.next, null); assert.equal(second.summary.retry_after_seconds, 0);
  assert.equal(h.values.get('tcgt_cache_resume'), 'false');
  const exhausted = resume(h, 4, { error: 'busy' }, { code: 429 }); noScriptErrors(h);
  assert.equal(exhausted.next, null); assert.equal(exhausted.summary.status, 'halted');
  assert.equal(exhausted.summary.measurements[1].status, 'retry_exhausted');
  assert.equal(exhausted.summary.measured.request_attempts, 6);
});

test('categories explicit resume preserves counters and exhaustion stops without early follow-up requests', () => {
  const h = harness(); const first = h.run(1, {}, { code: 429, headers: { 'Retry-After': '0' } });
  assert.equal(first.next, null); assert.equal(first.summary.status, 'retry_waiting');
  resume(h, 1, {}, { code: 503, headers: { 'Retry-After': '0' } });
  const exhausted = resume(h, 1, {}, { code: 429 }); noScriptErrors(h);
  assert.equal(exhausted.next, null); assert.equal(exhausted.summary.status, 'halted'); assert.equal(exhausted.summary.measured.request_attempts, 3);
  assert.equal(exhausted.summary.discovery.categories.status, 'retry_exhausted');
});

test('successful explicit retry is measured once and preserves the current card-to-SKU join', () => {
  const h = discover({}, [10]); h.run(3, cards());
  h.run(4, {}, { code: 503, headers: { 'Retry-After': '1' } }); h.advance(1);
  const final = resume(h, 4, skus()); noScriptErrors(h);
  assert.equal(final.summary.measurements.length, 2); assert.equal(final.summary.measured.request_attempts, 5);
  assert.equal(final.summary.measured.card_matched_sku_count, 2); assert.equal(final.summary.measured.card_join_set_count, 1);
  assert.equal(final.summary.status, 'completed'); assert.equal(final.summary.retry_not_before, null);
});

test('long Retry-After pauses without sleeping and early or implicit resume is blocked before sending', () => {
  const h = discover({}, [10]); const paused = h.run(3, {}, { code: 429, headers: { 'Retry-After': '120' } });
  assert.equal(paused.next, null); assert.equal(paused.summary.status, 'retry_waiting');
  assert.equal(paused.summary.retry_after_seconds, 120); assert.ok(paused.summary.retry_not_before);
  assert.deepEqual(paused.timers, [1000]);
  const implicit = h.run(3, cards()); assert.equal(implicit.skipped, true); assert.match(implicit.preError, /stopped or paused/);
  const freshEarly = h.run(1, categories); assert.equal(freshEarly.skipped, true); assert.match(freshEarly.preError, /wait is still active/);
  h.values.set('tcgt_cache_resume', 'true');
  const early = h.run(1, categories); assert.equal(early.skipped, true); assert.match(early.preError, /wait is still active/);
  assert.equal(early.summary.measured.request_attempts, 3);
  h.advance(120); const resumed = resume(h, 3, cards()); assert.equal(resumed.next, names[3]);
  const final = h.run(4, skus()); assert.equal(final.summary.status, 'completed'); assert.equal(final.summary.measured.request_attempts, 5);
});

test('Retry-After HTTP dates and malformed headers have bounded explicit waits; discovery exhaustion halts', () => {
  const h = harness(); h.run(1, categories);
  const retry = h.run(2, {}, { code: 503, headers: { 'Retry-After': new Date(Date.now() + 120000).toUTCString() } });
  assert.equal(retry.summary.status, 'retry_waiting'); assert.ok(retry.summary.retry_after_seconds >= 119);
  h.advance(120); const resumed = resume(h, 2, sets([10])); assert.equal(resumed.next, names[2]); noScriptErrors(h);
  const missing = harness(); const fallback = missing.run(1, {}, { code: 429, headers: { 'Retry-After': 'not a date' } });
  assert.equal(fallback.summary.retry_after_seconds, 5);
  const exhausted = harness({ tcgt_cache_max_retries: 0 }); exhausted.run(1, categories);
  const stop = exhausted.run(2, {}, { code: 429 }); assert.equal(stop.summary.status, 'halted'); assert.equal(stop.next, null);
});

test('request 01 restarts derived state/results and does not retain old card IDs or counters', () => {
  const h = discover({ tcgt_cache_mode: 'full' }, [10]); complete(h, [10]);
  h.values.set('tcgt_cache_set_id', '999'); const reset = h.run(1, categories); noScriptErrors(h);
  assert.equal(reset.summary.measured.request_attempts, 1); assert.equal(reset.summary.measurements.length, 0); assert.equal(reset.summary.selected_set_count, 0); assert.equal(h.values.has('tcgt_cache_set_id'), false);
});

test('environment overrides cannot change URLs, and unsafe URLs or methods are blocked before sending', () => {
  const h = discover({}, [10]); const safe = h.run(3, cards(), { environment: { tcgt_cache_category_id: '2', tcgt_cache_set_id: '999', tcgt_cache_delay_ms: '9999' }, requestHeaders: { Authorization: 'secret', Cookie: 'session', 'X-Api-Key': 'secret', 'X-Shipper-Id': '1', 'If-None-Match': 'old' } });
  assert.equal(safe.url, 'https://openapi.tcgtracking.com/v1/3/sets/10/cards'); assert.equal(safe.headers.size, 1);
  for (const options of [{ url: 'https://example.invalid/v1/categories' }, { url: 'https://openapi.tcgtracking.com.evil.invalid/v1/categories' }, { url: 'https://openapi.tcgtracking.com/v1/categories?key=secret' }, { method: 'POST' }]) {
    const bad = harness().run(1, categories, options); assert.equal(bad.skipped, true); assert.equal(bad.next, null); assert.match(bad.preError, /Blocked/);
  }
});

test('invalid configuration, changed configuration and oversized derived state stop before a request', () => {
  for (const config of [{ tcgt_cache_category_id: '3/../x' }, { tcgt_cache_mode: 'all' }, { tcgt_cache_sample_size: 0 }, { tcgt_cache_max_retries: 3 }, { tcgt_cache_delay_ms: -1 }, { tcgt_cache_delay_ms: 0 }, { tcgt_cache_resume: 'yes' }]) assert.equal(harness(config).run(1, categories).skipped, true);
  const h = discover({}, [10]); h.values.set('tcgt_cache_sample_size', '2'); assert.equal(h.run(3, cards()).skipped, true);
  const large = harness(); large.values.set('tcgt_cache_state', 'x'.repeat(2 * 1024 * 1024 + 1)); assert.equal(large.run(3, cards()).skipped, true);
});

test('metadata-only state stays bounded and drops transient product ID join after each set', () => {
  const h = discover({ tcgt_cache_mode: 'full' }, [10]); const ids = Array.from({ length: 10000 }, (_, index) => index + 1); h.run(3, cards(10, ids));
  assert.ok(JSON.parse(h.values.get('tcgt_cache_state')).current_card_ids.length === 10000);
  const result = h.run(4, skus()); noScriptErrors(h);
  const state = JSON.parse(h.values.get('tcgt_cache_state')); assert.equal(state.current_card_ids, undefined); assert.ok(h.values.get('tcgt_cache_state').length < 10000); assert.ok(h.values.get('tcgt_cache_summary').length < 20000);
  assert.ok(!h.values.get('tcgt_cache_state').includes('Pokémon synthetic')); assert.equal(result.summary.measurements[0].product_count, 10000);
});

test('unexpected request order is blocked before duplicate rows can inflate totals', () => {
  const h = discover({ tcgt_cache_mode: 'full' }, [10]); h.run(3, cards());
  const duplicate = h.run(3, cards()); assert.equal(duplicate.skipped, true); assert.match(duplicate.preError, /Unexpected request order/);
  assert.equal(duplicate.summary.measurements.length, 1);
  const final = h.run(4, skus()); assert.equal(final.summary.coverage_complete, true);
  assert.equal(final.summary.measured.card_product_count, 2);
});

test('derived state overflow halts, clears stale loop state and publishes a bounded failure summary', () => {
  const h = discover({}, [10]); const state = JSON.parse(h.values.get('tcgt_cache_state'));
  state.warnings.push('x'.repeat(2 * 1024 * 1024 - h.values.get('tcgt_cache_state').length - 50));
  h.values.set('tcgt_cache_state', JSON.stringify(state));
  const result = h.run(3, cards()); assert.equal(result.next, null); assert.match(result.postError, /exceeded 2 MiB/);
  assert.equal(result.summary.status, 'halted'); assert.equal(result.summary.coverage_complete, false);
  assert.equal(h.values.has('tcgt_cache_state'), false); assert.ok(h.values.get('tcgt_cache_summary').length < 1000);
});
