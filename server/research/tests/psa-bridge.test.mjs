import test from 'node:test';
import assert from 'node:assert/strict';
import { createPSACertBridge, MAX_CERT_RESPONSE_BYTES } from '../src/psa-bridge.mjs';

// Synthetic normalized adapter responses, not official PSA API responses or
// evidence that these example certification numbers exist.
const TEMPLATE = 'https://authorized-cert.example.test/cert/{certificateNumber}';
const TOKEN = 'synthetic-authorized-bridge-device-token';
const CERTIFICATE = '00123456';
function metadata() {
  return {
    certificateNumber: CERTIFICATE, grader: 'PSA', grade: '9',
    name: 'Synthetic Fixture Card', year: '2001', set: 'Synthetic Fixture Set', number: '1/10',
    language: 'English', printing: 'Holofoil', source: 'Synthetic authorized adapter',
    qualifiers: ['OC'], autographGrade: '10',
    imageURL: 'https://images.example.test/synthetic-card.jpg',
  };
}
function response(body, status = 200, headers = {}) {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json', ...headers },
  });
}
function loader(replies) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init, headers: new Headers(init.headers) });
    const reply = replies.shift();
    assert.ok(reply, 'Unexpected certificate-provider call');
    if (reply instanceof Error) throw reply;
    if (!reply.url) Object.defineProperty(reply, 'url', { configurable: true, value: String(url) });
    return reply;
  };
  return { calls, fetchImpl };
}

test('certificate lookup remains unavailable until an authorized adapter URL is configured', () => {
  assert.equal(createPSACertBridge({}), null);
  assert.equal(createPSACertBridge({ urlTemplate: '' }), null);
});

test('template validation requires one certificate placeholder in a fixed HTTPS path', () => {
  for (const urlTemplate of [
    'http://authorized.example.test/cert/{certificateNumber}',
    'https://user:password@authorized.example.test/cert/{certificateNumber}',
    'https://authorized.example.test/cert/{certificateNumber}?secret=hidden',
    'https://authorized.example.test/cert/{certificateNumber}#fragment',
    'https://authorized.example.test/cert/no-placeholder',
    'https://authorized.example.test/{certificateNumber}/{certificateNumber}',
    'https://{certificateNumber}.example.test/cert',
    'https://authorized.example.test/cert/%7BcertificateNumber%7D',
  ]) {
    assert.throws(() => createPSACertBridge({ urlTemplate }), error => {
      assert.ok(!error.message.includes('password'));
      assert.ok(!error.message.includes('hidden'));
      return true;
    }, urlTemplate);
  }
});

test('lookup preserves leading zeroes, grade labels and qualifier metadata without a fabricated catalog match', async () => {
  const upstream = loader([response(metadata())]);
  const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, token: TOKEN, fetchImpl: upstream.fetchImpl });
  const result = await lookup(CERTIFICATE);
  assert.equal(result.certificateNumber, CERTIFICATE);
  assert.equal(result.grader, 'PSA');
  assert.equal(result.grade, '9');
  assert.deepEqual(result.qualifiers, ['OC']);
  assert.equal(result.autographGrade, '10');
  assert.equal(result.product_id, undefined);
  assert.equal(result.category_id, undefined);
  assert.equal(result.group_id, undefined);
  const call = upstream.calls[0];
  assert.equal(call.url, 'https://authorized-cert.example.test/cert/00123456');
  assert.equal(call.init.redirect, 'error');
  assert.equal(call.headers.get('Authorization'), `Bearer ${TOKEN}`);
  assert.equal(call.headers.get('X-Api-Key'), null);
  assert.equal(call.headers.get('X-Shipper-Id'), null);
});

test('bridge token is optional and never placed in the URL', async () => {
  const upstream = loader([response(metadata())]);
  const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, fetchImpl: upstream.fetchImpl });
  await lookup(CERTIFICATE);
  assert.equal(upstream.calls[0].headers.get('Authorization'), null);
  assert.ok(!upstream.calls[0].url.includes('token'));
});

test('invalid certification values are rejected before any outbound request', async () => {
  const upstream = loader([]);
  const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, fetchImpl: upstream.fetchImpl });
  for (const cert of [12345678, '12345', '1234567890123', ' 12345678', '12345678 ', '1234/5678', '1e7', 'abcdefgh']) {
    await assert.rejects(() => lookup(cert), error => error.status === 400 && error.code === 'invalid_certificate');
  }
  assert.equal(upstream.calls.length, 0);
});

test('metadata must identify the same certificate and exact grading company', async () => {
  for (const transform of [
    value => { value.certificateNumber = '99999999'; },
    value => { value.certificateNumber = Number(CERTIFICATE); },
    value => { value.grader = 'BGS'; },
    value => { delete value.grade; },
    value => { delete value.name; },
    value => { delete value.source; },
    value => { value.grade = 9; },
  ]) {
    const body = metadata(); transform(body);
    const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, fetchImpl: loader([response(body)]).fetchImpl });
    await assert.rejects(() => lookup(CERTIFICATE), error => error.status === 502 && error.code === 'psa_invalid_response');
  }
});

test('raw or ambiguous provider response shapes are not guessed into the normalized contract', async () => {
  for (const body of [
    { PSACert: { CertNumber: CERTIFICATE, Subject: 'Synthetic Fixture', NumericGrade: 9 } },
    { certificate: metadata() },
    'not JSON',
    [],
    null,
  ]) {
    const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, fetchImpl: loader([response(body)]).fetchImpl });
    await assert.rejects(() => lookup(CERTIFICATE), error => error.status === 502 && error.code === 'psa_invalid_response');
  }
});

test('redirect statuses and mismatched response URLs are rejected', async () => {
  const changedURL = response(metadata());
  Object.defineProperty(changedURL, 'url', { value: 'https://another.example.test/collect' });
  for (const reply of [response({}, 302, { Location: 'https://another.example.test/' }), changedURL]) {
    const upstream = loader([reply]);
    const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, token: TOKEN, fetchImpl: upstream.fetchImpl });
    await assert.rejects(() => lookup(CERTIFICATE), error => error.status >= 500);
    assert.equal(upstream.calls.length, 1);
  }
});

test('certificate provider failures use credential-safe statuses and preserve a bounded retry deadline', async () => {
  for (const [status, expectedStatus, code] of [
    [401, 502, 'psa_access_denied'], [403, 502, 'psa_access_denied'],
    [404, 404, 'certificate_not_found'], [429, 503, 'psa_temporarily_unavailable'],
    [503, 503, 'psa_temporarily_unavailable'],
  ]) {
    const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, token: TOKEN,
      fetchImpl: loader([response({ error: TOKEN }, status, { 'Retry-After': '999999' })]).fetchImpl });
    await assert.rejects(() => lookup(CERTIFICATE), error => {
      assert.equal(error.status, expectedStatus); assert.equal(error.code, code);
      assert.ok(!error.message.includes(TOKEN));
      if (status === 429 || status === 503) assert.ok(error.retryAfter >= 1 && error.retryAfter <= 3600);
      return true;
    });
  }
});

test('thrown transport errors and timeout errors never expose provider credentials', async () => {
  for (const failure of [new Error(`private failure ${TOKEN}`), new DOMException(`private ${TOKEN}`, 'TimeoutError')]) {
    const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, token: TOKEN, fetchImpl: loader([failure]).fetchImpl });
    await assert.rejects(() => lookup(CERTIFICATE), error => {
      assert.ok(error.status === 502 || error.status === 504);
      assert.equal(error.code, 'psa_unavailable');
      assert.ok(!error.message.includes(TOKEN));
      return true;
    });
  }
});

test('certificate response bodies are bounded independently of the full research set size', async () => {
  const body = metadata(); body.unused = 'x'.repeat(MAX_CERT_RESPONSE_BYTES);
  const lookup = createPSACertBridge({ urlTemplate: TEMPLATE, fetchImpl: loader([response(body)]).fetchImpl });
  await assert.rejects(() => lookup(CERTIFICATE), error => error.status === 502);
});
