/* Function body for WKWebView.callAsyncJavaScript, executed on the real public
 * TCGTracking Quick Scan origin. `refs` is an argument, never source interpolation.
 * Keep the request identical to the site's same-origin catalogDetail fetch.
 * Runs in WKContentWorld.page after ordinary public-page initialization.
 */
if (!Array.isArray(refs) || refs.length < 1 || refs.length > 5 ||
    refs.some(ref => typeof ref !== 'string' || !/^(?:p|t|ts|u):\d{1,12}$/.test(ref))) {
  throw new TypeError('Invalid catalog references');
}
if (typeof location !== 'object' || location.origin !== 'https://tcgtracking.com' ||
    !['/newscanplus/quick', '/newscanplus/quick/'].includes(location.pathname) || location.search ||
    typeof document !== 'object' || document.readyState !== 'complete') {
  throw new TypeError('Public pricing page is not ready');
}
// Return only an allowlisted classification for diagnostics. Never return arbitrary
// server messages, cookie/token values or response text as a diagnostic field.
function classifyFailure(body, status) {
  if (status >= 200 && status < 300) return 'none';
  if (status === 429) return 'rate_limited';
  let object;
  try { object = JSON.parse(body); } catch { return 'unknown_http_error'; }
  const values = [];
  for (const key of ['code', 'error', 'reason', 'message']) {
    const value = object?.[key];
    if (typeof value === 'string') values.push(value.slice(0, 512));
    else if (value && typeof value === 'object') {
      for (const field of ['code', 'reason', 'message']) if (typeof value[field] === 'string') values.push(value[field].slice(0, 512));
    }
  }
  const message = values.join(' ').toLowerCase();
  if (/csrf|cross[-_ ]site request forgery/.test(message)) return 'csrf_rejected';
  if (/referr?er/.test(message)) return 'referrer_rejected';
  if (/origin|cors|same[-_ ]site|cross[-_ ]site/.test(message)) return 'origin_rejected';
  if (/scope/.test(message) && /price|public/.test(message)) return 'public_scope_required';
  if (/token|bearer|api[-_ ]?key/.test(message)) return 'token_rejected';
  if (/log[-_ ]?in|logged[-_ ]?in|sign[-_ ]?in|signed[-_ ]?in|authentication|unauthenticated/.test(message)) return 'authentication_required';
  if (/unauthori[sz]ed/.test(message)) return 'unauthorized';
  if (/invalid[-_ ]?(refs?|reference)|validation|bad[-_ ]request/.test(message)) return 'validation_error';
  return 'unknown_http_error';
}
const maximumBytes = 2_000_000;
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 4000);
try {
  const response = await fetch('/newscanplus/api/detail.php', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refs }),
    cache: 'no-store',
    redirect: 'error',
    signal: controller.signal
  });
  const contentLength = Number(response.headers.get('Content-Length'));
  if (Number.isFinite(contentLength) && contentLength > maximumBytes) {
    controller.abort();
    throw new RangeError('Catalog response too large');
  }
  let body = '';
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
          throw new RangeError('Catalog response too large');
        }
        body += decoder.decode(chunk.value, { stream: true });
      }
      body += decoder.decode();
    } finally {
      reader.releaseLock();
    }
  } else {
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength > maximumBytes) {
      controller.abort();
      throw new RangeError('Catalog response too large');
    }
    body = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }
  return { status: response.status, body, serverReason: classifyFailure(body, response.status), context: 'public_page', documentState: document.readyState };
} finally {
  clearTimeout(timer);
}
