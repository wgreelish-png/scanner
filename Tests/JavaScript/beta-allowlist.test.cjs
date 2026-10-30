const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/BetaAllowlist.js'), 'utf8');
const fixtureIP = '203.0.113.42';
const fixtureToken = 'fixture-csrf-token-not-a-real-session';

function fixture(options = {}) {
  const requests = [], timers = new Map();
  let timerID = 0;
  const input = { tagName: 'TEXTAREA', value: options.allowedText ?? '198.51.100.19\n2001:db8::5' };
  const location = { href: options.href ?? 'https://tcgtracking.com/apiforbeta' };
  const window = {};
  window.top = options.subframe ? {} : window;
  const context = vm.createContext({
    URL, AbortController, TextDecoder, Uint8Array, window, location,
    document: {
      readyState: options.readyState ?? 'complete',
      getElementById: name => name === 'allowedIpsInput' && !options.noInput ? input : null,
      querySelector: () => options.passwordForm ? {} : null
    },
    setTimeout(fn, milliseconds) { const id = ++timerID; timers.set(id, { fn, milliseconds }); return id; },
    clearTimeout(id) { timers.delete(id); },
    async fetch(url, request) {
      requests.push({ url, ...request });
      if (options.fetch) return options.fetch(url, request);
      return new Response(options.rawBody ?? JSON.stringify(options.body ?? { ok: true, allowed_ips: [options.ip ?? fixtureIP] }), {
        status: options.status ?? 200,
        headers: { 'Content-Type': options.contentType ?? 'application/json; charset=UTF-8', ...options.headers }
      });
    }
  });
  if (!options.noToken) vm.runInContext(`const CSRF_TOKEN = ${JSON.stringify(options.token ?? fixtureToken)};`, context);
  if (!options.noIP) vm.runInContext(`const DETECTED_IP = ${JSON.stringify(options.ip ?? fixtureIP)};`, context);
  if (!options.noShipper) vm.runInContext(`const SHIPPER_ID = ${JSON.stringify(options.shipperID ?? 4881)};`, context);
  const execute = vm.runInContext(`(async function(operation, expectedIP, expectedShipperID) { ${source}\n})`, context);
  return {
    context, requests, input, location, timers,
    async run(operation = 'probe', expectedIP = options.ip ?? fixtureIP, expectedShipperID = '4881') {
      // JSON removes VM-realm prototypes while preserving the exact public result.
      return JSON.parse(JSON.stringify(await execute(operation, expectedIP, expectedShipperID)));
    },
    fireTimeout() { for (const timer of [...timers.values()]) timer.fn(); }
  };
}

test('probe reads the real page IP and existing addresses without writing or exposing the token', async () => {
  const f = fixture();
  assert.deepEqual(await f.run(), { status: 'ready', ip: fixtureIP,
    allowedIPs: ['198.51.100.19', '2001:db8::5'], shipperID: '4881' });
  assert.equal(f.requests.length, 0);
  assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
  assert.equal(JSON.stringify(await f.run()).includes(fixtureToken), false);
});

test('save replaces previous addresses atomically with one exact current IP using the website session', async () => {
  const f = fixture();
  assert.deepEqual(await f.run('save'), { status: 'saved', ip: fixtureIP, allowedIPs: [fixtureIP] });
  assert.equal(f.requests.length, 1);
  const request = f.requests[0];
  assert.equal(request.url, 'https://tcgtracking.com/apiforbeta');
  assert.equal(request.method, 'POST');
  assert.equal(request.credentials, 'same-origin');
  assert.equal(request.redirect, 'error');
  assert.equal(request.cache, 'no-store');
  assert.deepEqual({ ...request.headers }, { 'Content-Type': 'application/json', 'X-CSRF-Token': fixtureToken });
  assert.deepEqual(JSON.parse(request.body), { action: 'save_ips', allowed_ips: fixtureIP, csrf_token: fixtureToken });
  assert.equal(f.input.value, fixtureIP);
  assert.equal(f.timers.size, 0);
  assert.equal(f.context.__CardShowBetaAllowlistAbort, undefined);
});

test('an already-current singleton skips POST, but an additional old address is replaced', async () => {
  const current = fixture({ allowedText: `\n${fixtureIP}\r\n` });
  assert.deepEqual(await current.run('save'), { status: 'already_current', ip: fixtureIP, allowedIPs: [fixtureIP] });
  assert.equal(current.requests.length, 0);
  const extra = fixture({ allowedText: `${fixtureIP}\n198.51.100.19` });
  assert.equal((await extra.run('save')).status, 'saved');
  assert.equal(extra.requests.length, 1);
});

test('an empty existing allowlist is populated without an intermediate clear request', async () => {
  const f = fixture({ allowedText: '' });
  assert.equal((await f.run('save')).status, 'saved');
  assert.equal(f.requests.length, 1);
  assert.equal(JSON.parse(f.requests[0].body).allowed_ips, fixtureIP);
});

test('IPv6 is preserved exactly as detected by the provider, including compressed and embedded IPv4 forms', async () => {
  for (const ip of ['2001:db8:0:1::abcd', '2001:0DB8:0:0:0:0:0:1', '::ffff:192.0.2.128']) {
    const f = fixture({ ip });
    assert.equal((await f.run()).ip, ip);
    assert.equal((await f.run('save')).status, 'saved');
    assert.equal(JSON.parse(f.requests[0].body).allowed_ips, ip);
  }
});

test('equivalent expanded, uppercase and mapped IPv6 responses preserve the provider-confirmed singleton', async () => {
  for (const [ip, returned] of [
    ['2606:4700:4700::abcd', '2606:4700:4700:0000:0000:0000:0000:ABCD'],
    ['2606:4700:4700:0:0:0:0:1111', '2606:4700:4700::1111'],
    ['::ffff:8.8.8.8', '8.8.8.8']
  ]) {
    const f = fixture({ ip, body: { ok: true, allowed_ips: [returned] } });
    assert.deepEqual(await f.run('save'), { status: 'saved', ip, allowedIPs: [returned] });
    assert.equal(f.input.value, returned);
    assert.equal(f.requests.length, 1);
    assert.deepEqual(await f.run('save'), { status: 'already_current', ip, allowedIPs: [returned] });
    assert.equal(f.requests.length, 1);
  }
  const wrong = fixture({ ip: '2606:4700:4700::1111',
    body: { ok: true, allowed_ips: ['2606:4700:4700::1001'] } });
  assert.deepEqual(await wrong.run('save'), { status: 'save_failed' });
  assert.equal(wrong.input.value, '198.51.100.19\n2001:db8::5');
});

test('invalid, empty, scoped and non-IP detected values never clear the account allowlist', async () => {
  const values = ['', ' ', '203.0.113.999', '203.0.113', '01.2.3.4', '203.0.113.4/32',
    '203.0.113.42\n198.51.100.1', '2001:db8::gg', '2001:db8:::1', 'fe80::1%en0',
    '2001:db8::1/128', 'https://evil.example', '2001:db8::1]:443', '1', '127.1'];
  for (const ip of values) {
    const f = fixture({ ip });
    assert.deepEqual(await f.run('save'), { status: 'page_changed' }, ip);
    assert.equal(f.requests.length, 0);
    assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
  }
});

test('a stale or different native selection cannot replace the detected address', async () => {
  for (const expectedIP of ['', '198.51.100.1', '203.0.113.42\n198.51.100.1', '2001:db8::1']) {
    const f = fixture();
    assert.deepEqual(await f.run('save', expectedIP), { status: 'page_changed' });
    assert.equal(f.requests.length, 0);
  }
});

test('only the exact trusted management page can receive a save', async () => {
  const urls = ['http://tcgtracking.com/apiforbeta', 'https://tcgtracking.com.evil/apiforbeta',
    'https://www.tcgtracking.com/apiforbeta', 'https://evil.example/apiforbeta',
    'https://user:password@tcgtracking.com/apiforbeta', 'https://tcgtracking.com:8443/apiforbeta',
    'https://tcgtracking.com/apiforbeta?return=evil', 'https://tcgtracking.com/apiforbeta#other',
    'https://tcgtracking.com/apiforbeta/', 'javascript:alert(1)', 'about:blank'];
  for (const href of urls) {
    const f = fixture({ href });
    assert.deepEqual(await f.run('save'), { status: 'page_changed' }, href);
    assert.equal(f.requests.length, 0);
  }
});

test('subframes, incomplete documents and unknown operations never mutate the allowlist', async () => {
  for (const options of [{ subframe: true }, { readyState: 'loading' }]) {
    const f = fixture(options);
    assert.deepEqual(await f.run('save'), { status: 'page_changed' });
    assert.equal(f.requests.length, 0);
  }
  const f = fixture();
  assert.deepEqual(await f.run('generate_key'), { status: 'page_changed' });
  assert.equal(f.requests.length, 0);
});

test('missing or changed website fields and tokens fail closed', async () => {
  for (const options of [{ noInput: true }, { noToken: true }, { noIP: true }, { noShipper: true },
    { token: '' }, { token: 'x'.repeat(513) }, { token: 'bad-token\nwith-newline' },
    { allowedText: 'x'.repeat(4097) }, { allowedText: Array(11).fill('198.51.100.1').join('\n') }]) {
    const f = fixture(options);
    assert.deepEqual(await f.run('save'), { status: 'page_changed' });
    assert.equal(f.requests.length, 0);
  }
});

test('a different signed-in website account cannot change the intended Beta account', async () => {
  for (const expectedShipperID of ['4882', '', '04881', '4.881e3', '4881\n', '4294967296']) {
    const f = fixture();
    assert.deepEqual(await f.run('probe', fixtureIP, expectedShipperID), { status: 'account_mismatch' });
    assert.deepEqual(await f.run('save', fixtureIP, expectedShipperID), { status: 'account_mismatch' });
    assert.equal(f.requests.length, 0);
  }
  for (const shipperID of [0, -1, 1.5, 4294967296, '4881']) {
    const f = fixture({ shipperID });
    assert.deepEqual(await f.run('save'), { status: 'page_changed' });
    assert.equal(f.requests.length, 0);
  }
});

test('login redirects and a login form are reported without sending credentials or changes', async () => {
  for (const href of ['https://tcgtracking.com/login.php', 'https://tcgtracking.com/account/login']) {
    const f = fixture({ href });
    assert.deepEqual(await f.run('save'), { status: 'sign_in_required' });
    assert.equal(f.requests.length, 0);
  }
  const f = fixture({ noToken: true, passwordForm: true });
  assert.deepEqual(await f.run('save'), { status: 'sign_in_required' });
  assert.equal(f.requests.length, 0);
});

test('HTTP failures are classified without publishing the raw response or changing local form values', async () => {
  for (const [status, expected] of [[401, 'sign_in_required'], [403, 'access_denied'],
    [429, 'rate_limited'], [500, 'save_failed'], [503, 'save_failed']]) {
    const f = fixture({ status, rawBody: 'private-error-message and tokens' });
    assert.deepEqual(await f.run('save'), { status: expected });
    assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
    assert.equal(f.timers.size, 0);
  }
});

test('rate limits expose only a bounded numeric wait, never provider error text', async () => {
  for (const [header, wait] of [['12', 12], ['7200', 7200], ['9999999', 86400], ['0', undefined], ['-1', undefined],
    ['private token', undefined], ['Fri, 30 Oct 2026 18:00:00 GMT', undefined]]) {
    const f = fixture({ status: 429, headers: { 'Retry-After': header } });
    assert.deepEqual(await f.run('save'), wait === undefined ? { status: 'rate_limited' } :
      { status: 'rate_limited', retryAfterSeconds: wait });
  }
});

test('HTTP 200 is insufficient: only an explicit success with the exact singleton is accepted', async () => {
  const bodies = [{ ok: false, error: 'private-token' }, { ok: 'true', allowed_ips: [fixtureIP] },
    { ok: true }, { ok: true, allowed_ips: [] }, { ok: true, allowed_ips: [fixtureIP, '198.51.100.1'] },
    { ok: true, allowed_ips: ['198.51.100.1'] }, { success: true, allowed_ips: [fixtureIP] }];
  for (const body of bodies) {
    const f = fixture({ body });
    assert.deepEqual(await f.run('save'), { status: 'save_failed' });
    assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
  }
});

test('HTML, redirected responses and malformed JSON cannot be mistaken for a successful save', async () => {
  for (const options of [{ contentType: 'text/html', rawBody: '<form>Log in</form>' },
    { rawBody: '{"ok":' }, { rawBody: '' }, { status: 201 }]) {
    const f = fixture(options);
    assert.deepEqual(await f.run('save'), { status: 'save_failed' });
  }
  const f = fixture({ fetch: async () => ({ redirected: true }) });
  assert.deepEqual(await f.run('save'), { status: 'sign_in_required' });
});

test('declared and streamed oversized bodies are rejected before recording success', async () => {
  const declared = fixture({ headers: { 'Content-Length': '65537' } });
  assert.deepEqual(await declared.run('save'), { status: 'save_failed' });
  assert.equal(declared.requests[0].signal.aborted, true);
  const streamed = fixture({ rawBody: ' '.repeat(65_537) });
  assert.deepEqual(await streamed.run('save'), { status: 'save_failed' });
  assert.equal(streamed.requests[0].signal.aborted, true);
  assert.equal(streamed.input.value, '198.51.100.19\n2001:db8::5');
});

test('invalid UTF-8 and disconnected requests never expose raw errors', async () => {
  const invalid = fixture({ fetch: async () => new Response(new Uint8Array([0xc3, 0x28]),
    { status: 200, headers: { 'Content-Type': 'application/json' } }) });
  assert.deepEqual(await invalid.run('save'), { status: 'network_failed' });
  const disconnected = fixture({ fetch: async () => { throw new Error('private URL or token'); } });
  assert.deepEqual(await disconnected.run('save'), { status: 'network_failed' });
  assert.equal(disconnected.context.__CardShowBetaAllowlistAbort, undefined);
});

test('the bounded request deadline aborts a stalled save and clears its timer', async () => {
  const f = fixture({ fetch: async (_, request) => new Promise((resolve, reject) => {
    request.signal.addEventListener('abort', () => reject(new Error('fixture abort')));
  }) });
  const pending = f.run('save');
  assert.equal(f.timers.size, 1);
  assert.equal([...f.timers.values()][0].milliseconds, 12_000);
  f.fireTimeout();
  assert.deepEqual(await pending, { status: 'network_failed' });
  assert.equal(f.requests[0].signal.aborted, true);
  assert.equal(f.timers.size, 0);
});

test('foreground cancellation aborts an in-flight request without starting another save', async () => {
  const f = fixture({ fetch: async (_, request) => new Promise((resolve, reject) => {
    request.signal.addEventListener('abort', () => reject(new Error('fixture cancelled')));
  }) });
  const pending = f.run('save');
  assert.deepEqual(await f.run('cancel'), { status: 'cancelled' });
  assert.deepEqual(await pending, { status: 'network_failed' });
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].signal.aborted, true);
  assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
  assert.equal(f.timers.size, 0);
});

test('a response from a previous page cannot update the current form or report connected', async () => {
  let complete;
  const f = fixture({ fetch: async () => new Promise(resolve => { complete = resolve; }) });
  const pending = f.run('save');
  f.location.href = 'https://tcgtracking.com/login.php';
  complete(new Response(JSON.stringify({ ok: true, allowed_ips: [fixtureIP] }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }));
  assert.deepEqual(await pending, { status: 'page_changed' });
  assert.equal(f.input.value, '198.51.100.19\n2001:db8::5');
});

test('cancellation remains safe after navigation and does not require a valid token or page', async () => {
  const f = fixture({ href: 'about:blank', noToken: true, noInput: true });
  assert.deepEqual(await f.run('cancel'), { status: 'cancelled' });
  assert.equal(f.requests.length, 0);
});
