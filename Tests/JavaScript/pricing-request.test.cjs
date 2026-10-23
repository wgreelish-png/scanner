const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/PricingRequest.js'), 'utf8');
const execute = new AsyncFunction('refs', 'fetch', 'AbortController', 'TextDecoder', 'setTimeout', 'clearTimeout', 'location', 'document', source);
function run(refs, fetch, timers = { set: setTimeout, clear: clearTimeout }, context = {}) {
  return execute(refs, fetch, AbortController, TextDecoder, timers.set, timers.clear,
    context.location ?? { origin: 'https://tcgtracking.com', pathname: '/newscanplus/quick', search: '' },
    context.document ?? { readyState: 'complete' });
}
const quoteBody = JSON.stringify({ success: true, items: { 'p:123': { printings: [{
  key: 'Normal', label: 'Normal', quotes: {
    'English|Near Mint': { market_price: 1.25, sku_id: 10 },
    'English|Damaged': { market_price: 0, sku_id: 11 }
  }
}] } } });
test('pricing uses the real same-origin catalog contract without manufactured identity headers', async () => {
  let request;
  const result = await run(['p:123'], async (url, options) => {
    request = { url, options };
    return new Response(quoteBody, { status: 200 });
  });
  assert.equal(request.url, '/newscanplus/api/detail.php');
  assert.equal(request.options.method, 'POST');
  assert.equal(request.options.credentials, 'same-origin');
  assert.equal(request.options.redirect, 'error');
  assert.equal(request.options.cache, 'no-store');
  assert.deepEqual(request.options.headers, { 'Content-Type': 'application/json' });
  assert.deepEqual(JSON.parse(request.options.body), { refs: ['p:123'] });
  assert.equal(result.status, 200);
  assert.equal(result.body, quoteBody);
  const quotes = JSON.parse(result.body).items['p:123'].printings[0].quotes;
  assert.equal(quotes['English|Damaged'].market_price, 0);
  assert.equal(quotes['English|Damaged'].sku_id, 11);
});
test('HTTP failures preserve the actual status and body for native error handling', async () => {
  const result = await run(['p:123'], async () => new Response('{"success":false,"error":"unauthorized"}', { status: 401 }));
  assert.deepEqual(result, { status: 401, body: '{"success":false,"error":"unauthorized"}', serverReason: 'unauthorized', context: 'public_page', documentState: 'complete' });
});
test('untrusted refs are rejected before a network request', async () => {
  for (const refs of [[], null, ['bad'], ['p:1;alert(1)'], ['p:1234567890123'], new Array(6).fill('p:123'), [123]]) {
    await assert.rejects(run(refs, () => { throw new Error('must not fetch'); }), /Invalid catalog references/);
  }
});
test('the request aborts at four seconds and clears its timer', async () => {
  let deadline, cleared = false;
  const timers = {
    set(callback, ms) { assert.equal(ms, 4000); deadline = callback; return 27; },
    clear(id) { assert.equal(id, 27); cleared = true; }
  };
  const pending = run(['p:123'], async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
  }), timers);
  deadline();
  await assert.rejects(pending, error => error.name === 'AbortError');
  assert.equal(cleared, true);
});
test('a declared response larger than two MB is rejected before reading', async () => {
  let read = false;
  await assert.rejects(run(['p:123'], async () => ({
    status: 200, headers: new Headers({ 'Content-Length': '2000001' }),
    body: { getReader() { read = true; throw new Error('must not read'); } }
  })), /Catalog response too large/);
  assert.equal(read, false);
});
test('a streamed oversized body aborts and cancels further reading', async () => {
  let canceled = false, signal;
  const stream = new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(2_000_001)); },
    cancel() { canceled = true; }
  });
  await assert.rejects(run(['p:123'], async (_url, options) => {
    signal = options.signal;
    return new Response(stream, { status: 200 });
  }), /Catalog response too large/);
  assert.equal(signal.aborted, true);
  assert.equal(canceled, true);
});
test('streamed UTF-8 split between chunks remains intact', async () => {
  const bytes = new TextEncoder().encode('{"name":"Pokémon"}');
  const split = bytes.indexOf(0xc3) + 1;
  const stream = new ReadableStream({ start(controller) {
    controller.enqueue(bytes.slice(0, split)); controller.enqueue(bytes.slice(split)); controller.close();
  } });
  const result = await run(['p:123'], async () => new Response(stream, { status: 200 }));
  assert.equal(result.body, '{"name":"Pokémon"}');
});
test('a response without a readable stream still enforces the byte limit', async () => {
  await assert.rejects(run(['p:123'], async () => ({ status: 200, headers: new Headers(),
    body: null, arrayBuffer: async () => new ArrayBuffer(2_000_001)
  })), /Catalog response too large/);
});
test('server text is returned without evaluation or field coercion', async () => {
  const body = '<script>throw new Error("must never execute")</script>';
  const result = await run(['t:123', 'ts:124', 'u:125'], async () => new Response(body, { status: 200 }));
  assert.equal(result.body, body);
});

test('the catalog request requires a fully initialized genuine public page', async () => {
  const contexts = [
    { location: { origin: 'http://127.0.0.1:18764', pathname: '/index.html', search: '' } },
    { location: { origin: 'https://tcgtracking.com', pathname: '/account', search: '' } },
    { location: { origin: 'https://tcgtracking.com', pathname: '/newscanplus/quick', search: '?link=secret' } },
    { document: { readyState: 'loading' } }, { document: { readyState: 'interactive' } }
  ];
  for (const context of contexts) {
    await assert.rejects(run(['p:123'], () => { throw new Error('must not fetch'); }, undefined, context), /Public pricing page is not ready/);
  }
});
test('server access errors produce finite diagnostic reasons without arbitrary content', async () => {
  for (const [error, expected] of [
    ['Invalid origin', 'origin_rejected'], ['Referer required', 'referrer_rejected'], ['csrf missing', 'csrf_rejected'],
    ['token expired', 'token_rejected'], ['public price scope required', 'public_scope_required'], ['authentication required', 'authentication_required'],
    ['unauthorized', 'unauthorized'], ['customer-secret-session-value', 'unknown_http_error']
  ]) {
    const result = await run(['p:123'], async () => new Response(JSON.stringify({ error }), { status: 401 }));
    assert.equal(result.serverReason, expected);
    assert.equal(result.context, 'public_page');
    assert.equal(Object.prototype.hasOwnProperty.call(result, 'message'), false);
    assert.equal(Object.prototype.hasOwnProperty.call(result, 'error'), false);
  }
});
test('HTML and nested JSON error bodies remain unevaluated and safely classified', async () => {
  const html = await run(['p:123'], async () => new Response('<html>private service message</html>', { status: 401 }));
  assert.equal(html.serverReason, 'unknown_http_error');
  const nested = await run(['p:123'], async () => new Response(JSON.stringify({ error: { code: 'invalid_origin', message: 'private' } }), { status: 401 }));
  assert.equal(nested.serverReason, 'origin_rejected');
  const rateLimit = await run(['p:123'], async () => new Response('server text', { status: 429 }));
  assert.equal(rateLimit.serverReason, 'rate_limited');
});

test('the actual five-candidate Quick Scan batch is sent without narrowing or inventing refs', async () => {
  const refs = ['p:84922', 'p:86027', 'p:87718', 'p:87727', 'p:89273'];
  let sent;
  await run(refs, async (_url, request) => { sent = JSON.parse(request.body).refs; return new Response(quoteBody); });
  assert.deepEqual(sent, refs);
});
