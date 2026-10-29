import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { pathToFileURL } from 'node:url';
import { createResearchHandler } from './research.mjs';
import { createPSACertBridge } from './psa-bridge.mjs';

export function configurationFromEnvironment(environment = process.env) {
  const port = environment.PORT === undefined || environment.PORT === '' ? 8787 : Number(environment.PORT);
  const host = environment.HOST || '127.0.0.1';
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !(host === 'localhost' || isIP(host))) throw new Error('Configure a valid listen IP and port.');
  return { host, port, shipperID: environment.TCG_BETA_SHIPPER_ID, apiKey: environment.TCG_BETA_API_KEY,
    deviceToken: environment.RESEARCH_DEVICE_TOKEN,
    certURLTemplate: environment.PSA_CERT_SERVICE_URL_TEMPLATE,
    certToken: environment.PSA_CERT_SERVICE_TOKEN };
}

export function createResearchServer(configuration) {
  const psaLookup = configuration.psaLookup ?? createPSACertBridge({ urlTemplate: configuration.certURLTemplate, token: configuration.certToken });
  const handler = createResearchHandler({ shipperID: configuration.shipperID, apiKey: configuration.apiKey, deviceToken: configuration.deviceToken, psaLookup,
    ...(configuration.fetchImpl ? { fetchImpl: configuration.fetchImpl } : {}) });
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 20_000, headersTimeout: 10_000, keepAliveTimeout: 5_000 }, async (incoming, outgoing) => {
    try {
      // There are no upload endpoints; reject bodies rather than buffering them.
      if (incoming.headers['transfer-encoding'] || Number(incoming.headers['content-length'] || 0) > 0 || (incoming.headersDistinct.authorization?.length ?? 0) > 1) {
        outgoing.writeHead(400, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', Connection: 'close' });
        outgoing.end(JSON.stringify({ error: { code: 'invalid_request', message: 'Send one authorization header and no request body.' } }));
        return;
      }
      const headers = new Headers();
      for (const [name, value] of Object.entries(incoming.headers)) {
        if (typeof value === 'string') headers.set(name, value);
        else if (Array.isArray(value)) for (const item of value) headers.append(name, item);
      }
      // Never use the untrusted Host header to construct an upstream URL.
      const url = new URL(incoming.url || '/', 'http://research.internal');
      const request = new Request(url, { method: incoming.method || 'GET', headers });
      const response = await handler(request, { clientIP: incoming.socket.remoteAddress || 'unknown' });
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      outgoing.end(Buffer.from(await response.arrayBuffer()));
    } catch {
      if (!outgoing.headersSent) outgoing.writeHead(500, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      outgoing.end(JSON.stringify({ error: { code: 'internal_error', message: 'The research service could not complete this request.' } }));
    }
  });
  server.maxConnections = 128;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const configuration = configurationFromEnvironment();
    const server = createResearchServer(configuration);
    server.on('error', () => { console.error('Research server could not listen on its configured address.'); process.exitCode = 1; });
    server.listen(configuration.port, configuration.host, () => console.log('Research server is listening. Configure HTTPS on the reverse proxy before connecting the app.'));
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
      server.close(() => { process.exitCode = 0; });
      setTimeout(() => server.closeAllConnections(), 5000).unref();
    });
  } catch {
    // Do not print errors that might include an operator-supplied credential URL.
    console.error('Research server configuration is invalid. Check the documented environment variable requirements.');
    process.exitCode = 1;
  }
}
