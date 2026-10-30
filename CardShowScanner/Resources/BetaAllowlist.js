/* Function body for WKWebView.callAsyncJavaScript in WKContentWorld.page.
 * `operation`, `expectedIP` and `expectedShipperID` are structured native arguments. The real signed-in
 * /apiforbeta page supplies its fresh CSRF token and server-detected public IP.
 * A save replaces the allowlist in ONE request; it never sends an empty list.
 * Return only bounded, classified results, never cookies, tokens or raw errors.
 */
const endpoint = 'https://tcgtracking.com/apiforbeta';
const failed = status => ({ status });
// Native calls this before releasing its foreground-only browser. It has no
// credentials and remains safe even if the page navigated during the request.
if (operation === 'cancel') {
  globalThis.__CardShowBetaAllowlistAbort?.abort();
  return failed('cancelled');
}
let page;
try { page = new URL(location.href); } catch { return failed('page_changed'); }
if (typeof window !== 'object' || window.top !== window ||
    page.origin !== 'https://tcgtracking.com' || page.username || page.password ||
    page.port || page.search || page.hash ||
    typeof document !== 'object' || document.readyState !== 'complete') {
  return failed('page_changed');
}
if (page.pathname !== '/apiforbeta') {
  return failed(/(?:^|\/)(?:login|sign[-_]?in)(?:\.php)?(?:\/|$)/i.test(page.pathname)
    ? 'sign_in_required' : 'page_changed');
}
if (operation !== 'probe' && operation !== 'save') return failed('page_changed');

function validIP(value) {
  if (typeof value !== 'string' || !value || value.length > 45 || value.trim() !== value) return false;
  if (/^[0-9.]+$/.test(value)) {
    const parts = value.split('.');
    return parts.length === 4 && parts.every(part => /^(?:0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255);
  }
  // The URL parser validates IPv6 structure, including compressed/embedded IPv4.
  // Reject scope identifiers, prefixes, whitespace and every URL delimiter first.
  if (!value.includes(':') || !/^[0-9a-f:.]+$/i.test(value)) return false;
  try {
    const url = new URL('https://[' + value + ']/');
    return url.hostname.startsWith('[') && url.hostname.endsWith(']');
  } catch { return false; }
}

function normalizedIP(value) {
  if (!validIP(value)) return null;
  const host = new URL(value.includes(':') ? 'https://[' + value + ']/' : 'https://' + value + '/').hostname;
  // WebKit normalizes IPv6 compression and case. Treat mapped IPv4 spellings
  // as the same address too, matching native inet_pton identity validation.
  const mapped = /^\[::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})\]$/i.exec(host);
  if (mapped) {
    const high = parseInt(mapped[1], 16), low = parseInt(mapped[2], 16);
    return [high >> 8, high & 255, low >> 8, low & 255].join('.');
  }
  return host.toLowerCase();
}

const token = typeof CSRF_TOKEN === 'string' ? CSRF_TOKEN : '';
const ip = typeof DETECTED_IP === 'string' ? DETECTED_IP : '';
const shipperID = typeof SHIPPER_ID === 'number' && Number.isInteger(SHIPPER_ID) &&
  SHIPPER_ID > 0 && SHIPPER_ID <= 4_294_967_295 ? String(SHIPPER_ID) : '';
const input = document.getElementById('allowedIpsInput');
if (!input || input.tagName !== 'TEXTAREA' || typeof input.value !== 'string' ||
    input.value.length > 4_096 || !validIP(ip) || token.length < 16 || token.length > 512 ||
    !/^[\x21-\x7e]+$/.test(token) || !shipperID) {
  return failed(document.querySelector('input[type="password"]') ? 'sign_in_required' : 'page_changed');
}
if (typeof expectedShipperID !== 'string' || !/^[1-9][0-9]{0,9}$/.test(expectedShipperID) ||
    expectedShipperID !== shipperID) return failed('account_mismatch');
const allowedIPs = input.value.split(/\r?\n/).map(value => value.trim()).filter(Boolean);
if (allowedIPs.length > 10 || allowedIPs.some(value => value.length > 100)) return failed('page_changed');
if (operation === 'probe') return { status: 'ready', ip, allowedIPs, shipperID };
if (!validIP(expectedIP) || expectedIP !== ip) return failed('page_changed');
if (allowedIPs.length === 1 && normalizedIP(allowedIPs[0]) === normalizedIP(ip)) {
  return { status: 'already_current', ip, allowedIPs };
}

const maximumBytes = 65_536;
const controller = new AbortController();
globalThis.__CardShowBetaAllowlistAbort?.abort();
globalThis.__CardShowBetaAllowlistAbort = controller;
const timer = setTimeout(() => controller.abort(), 12_000);
function retryDetails(response) {
  const value = response.headers.get('Retry-After');
  if (!value || !/^\d{1,7}$/.test(value.trim())) return {};
  const seconds = Number(value.trim());
  return seconds > 0 ? { retryAfterSeconds: Math.min(seconds, 86_400) } : {};
}
try {
  const response = await fetch(endpoint, {
    method: 'POST', credentials: 'same-origin', cache: 'no-store', redirect: 'error',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': token },
    body: JSON.stringify({ action: 'save_ips', allowed_ips: ip, csrf_token: token }),
    signal: controller.signal
  });
  if (response.redirected) return failed('sign_in_required');
  if (response.status === 401) return failed('sign_in_required');
  if (response.status === 403) return failed('access_denied');
  if (response.status === 429) return { status: 'rate_limited', ...retryDetails(response) };
  if (response.status === 503) return { status: 'save_failed', ...retryDetails(response) };
  if (response.status !== 200 || !/^application\/json(?:\s*;|\s*$)/i.test(response.headers.get('Content-Type') || '')) {
    return failed('save_failed');
  }
  const declaredLength = Number(response.headers.get('Content-Length'));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    controller.abort();
    return failed('save_failed');
  }
  let text = '';
  if (response.body?.getReader) {
    const reader = response.body.getReader();
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let bytes = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (bytes > maximumBytes) {
          controller.abort();
          reader.cancel().catch(() => {});
          return failed('save_failed');
        }
        text += decoder.decode(chunk.value, { stream: true });
      }
      text += decoder.decode();
    } finally { reader.releaseLock(); }
  } else {
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength > maximumBytes) {
      controller.abort();
      return failed('save_failed');
    }
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }
  let data;
  try { data = JSON.parse(text); } catch { return failed('save_failed'); }
  if (data?.ok !== true || !Array.isArray(data.allowed_ips) ||
      data.allowed_ips.length !== 1 || normalizedIP(data.allowed_ips[0]) !== normalizedIP(ip)) {
    return failed('save_failed');
  }
  if (controller.signal.aborted || location.href !== endpoint ||
      document.getElementById('allowedIpsInput') !== input ||
      typeof DETECTED_IP !== 'string' || DETECTED_IP !== ip || String(SHIPPER_ID) !== shipperID) {
    return failed('page_changed');
  }
  input.value = data.allowed_ips[0];
  return { status: 'saved', ip, allowedIPs: data.allowed_ips };
} catch {
  return failed('network_failed');
} finally {
  clearTimeout(timer);
  if (globalThis.__CardShowBetaAllowlistAbort === controller) delete globalThis.__CardShowBetaAllowlistAbort;
}
