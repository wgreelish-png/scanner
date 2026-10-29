import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { resolve } from 'node:path';
import { createResearchServer, configurationFromEnvironment } from '../src/server.mjs';

// Local synthetic credentials only. These tests never contact an upstream API.
const TOKEN = 'synthetic-device-token-00000000000000000000';
function send(base, path, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = httpRequest(new URL(path, base), { method, headers }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks)) }));
    });
    request.on('error', reject);
    request.end(body);
  });
}
async function withServer(run) {
  const server = createResearchServer({ deviceToken: TOKEN });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  try { await run(`http://127.0.0.1:${server.address().port}`); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

test('server configuration refuses an unprotected device API and invalid listen endpoints', () => {
  assert.throws(() => createResearchServer({ deviceToken: '' }));
  assert.deepEqual(configurationFromEnvironment({}), { host: '127.0.0.1', port: 8787, shipperID: undefined, apiKey: undefined, deviceToken: undefined, cacheDirectory: resolve('.cache/tcg-beta'), certURLTemplate: undefined, certToken: undefined });
  for (const environment of [{ PORT: '0' }, { PORT: '65536' }, { PORT: 'bad' }, { HOST: 'not-a-listen-ip.example' }]) assert.throws(() => configurationFromEnvironment(environment));
});

test('real HTTP listener exposes safe liveness and validates the device token for app health', async () => {
  await withServer(async base => {
    const health = await send(base, '/health');
    assert.equal(health.status, 200);
    assert.equal(health.body.status, 'ok');
    assert.equal(health.body.researchConfigured, false);
    assert.equal(health.body.psaConfigured, false);
    const denied = await send(base, '/api/v1/health');
    assert.equal(denied.status, 401);
    assert.equal(denied.body.error.code, 'unauthorized');
    const connected = await send(base, '/api/v1/health', { headers: { Authorization: `Bearer ${TOKEN}`, Host: 'untrusted.example' } });
    assert.equal(connected.status, 200);
    assert.equal(JSON.stringify(connected.body).includes(TOKEN), false);
  });
});

test('HTTP wrapper rejects request bodies and duplicate Authorization rather than forwarding ambiguous input', async () => {
  await withServer(async base => {
    const body = await send(base, '/api/v1/health', { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Length': '3' }, body: 'bad' });
    assert.equal(body.status, 400);
    assert.equal(body.body.error.code, 'invalid_request');
    const duplicate = await send(base, '/api/v1/health', { headers: { Authorization: [`Bearer ${TOKEN}`, 'Bearer wrong-token'] } });
    assert.equal(duplicate.status, 400);
    assert.equal(duplicate.body.error.code, 'invalid_request');
  });
});
