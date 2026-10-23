/* Function body for WKWebView.callAsyncJavaScript, executed on the real public
 * TCGTracking Quick Scan origin. `refs` is an argument, never source interpolation.
 * Keep the request identical to the site's same-origin catalogDetail fetch.
 */
if (!Array.isArray(refs) || refs.length < 1 || refs.length > 5 ||
    refs.some(ref => typeof ref !== 'string' || !/^(?:p|t|ts|u):\d{1,12}$/.test(ref))) {
  throw new TypeError('Invalid catalog references');
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
  return { status: response.status, body };
} finally {
  clearTimeout(timer);
}
