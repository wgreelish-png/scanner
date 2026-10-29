import { APIError, normalizePSACertificate } from './research.mjs';

export const MAX_CERT_RESPONSE_BYTES = 256 * 1024;
const PLACEHOLDER = '{certificateNumber}';
const safeToken = token => typeof token === 'string' && token.length >= 16 && token.length <= 512 && /^[\x21-\x7e]+$/.test(token);
const invalid = () => new APIError(502, 'psa_invalid_response', 'The certificate service returned an unsupported or mismatched certificate response.');

/** Connects to an operator-supplied authorized normalized certificate service.
 * This is an adapter contract, not an undocumented PSA API or HTML scraper. */
export function createPSACertBridge({ urlTemplate, token, fetchImpl = fetch } = {}) {
  if (urlTemplate === undefined || urlTemplate === null || urlTemplate === '') return null;
  if (typeof urlTemplate !== 'string' || urlTemplate.length > 2048 || urlTemplate.split(PLACEHOLDER).length !== 2 || /[{}]/.test(urlTemplate.replace(PLACEHOLDER, ''))) {
    throw new Error('PSA_CERT_SERVICE_URL_TEMPLATE must contain exactly one certificate placeholder in an HTTPS path.');
  }
  let sample;
  try {
    sample = new URL(urlTemplate.replace(PLACEHOLDER, '12345678'));
    if (sample.protocol !== 'https:' || sample.username || sample.password || sample.search || sample.hash || !sample.pathname.includes('12345678')) throw new Error();
  } catch { throw new Error('PSA certificate bridge URL must be HTTPS, without credentials, a query, or a fragment.'); }
  if (token !== undefined && token !== null && token !== '' && !safeToken(token)) throw new Error('PSA_CERT_SERVICE_TOKEN must be a valid printable token.');
  const origin = sample.origin;
  return async function lookup(certificateNumber) {
    if (typeof certificateNumber !== 'string' || !/^[0-9]{6,12}$/.test(certificateNumber)) throw new APIError(400, 'invalid_certificate', 'Enter a 6–12 digit certificate number.');
    const url = new URL(urlTemplate.replace(PLACEHOLDER, certificateNumber));
    if (url.origin !== origin || url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw invalid();
    const headers = { Accept: 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    try {
      const response = await fetchImpl(url.href, { method: 'GET', headers, redirect: 'error', signal: AbortSignal.timeout(12_000) });
      if (response.status !== 200 || (response.url && response.url !== url.href)) {
        try { await response.body?.cancel(); } catch { /* Retain the safe status error. */ }
      }
      if (response.url && response.url !== url.href) throw invalid();
      if ([401, 403].includes(response.status)) throw new APIError(502, 'psa_access_denied', 'The configured certificate service rejected server access.');
      if (response.status === 404) throw new APIError(404, 'certificate_not_found', 'No certificate was returned by the configured certificate service.');
      if ([429, 503].includes(response.status)) {
        const raw = response.headers.get('Retry-After');
        const retryAfter = /^[0-9]{1,6}$/.test(raw ?? '') ? Math.min(3600, Math.max(1, Number(raw))) : 30;
        throw new APIError(503, 'psa_temporarily_unavailable', 'The certificate service is temporarily unavailable. Please retry later.', retryAfter);
      }
      if (response.status !== 200) throw new APIError(502, 'psa_unavailable', 'The certificate service could not complete this request.');
      const length = response.headers.get('Content-Length');
      if (length && /^[0-9]+$/.test(length) && Number(length) > MAX_CERT_RESPONSE_BYTES) { await response.body?.cancel(); throw invalid(); }
      const chunks = []; let size = 0;
      if (response.body) {
        const reader = response.body.getReader();
        try {
          while (true) {
            const { value, done } = await reader.read(); if (done) break;
            size += value.byteLength;
            if (size > MAX_CERT_RESPONSE_BYTES) { await reader.cancel(); throw invalid(); }
            chunks.push(value);
          }
        } finally { reader.releaseLock(); }
      }
      let value;
      try { value = JSON.parse(Buffer.concat(chunks, size).toString('utf8')); }
      catch { throw invalid(); }
      try { return normalizePSACertificate(value, certificateNumber); }
      catch { throw invalid(); }
    } catch (error) {
      if (error instanceof APIError) throw error;
      throw new APIError(error?.name === 'AbortError' || error?.name === 'TimeoutError' ? 504 : 502, 'psa_unavailable', 'The certificate service could not complete this request.');
    }
  };
}
