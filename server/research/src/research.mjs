import { createHash, timingSafeEqual } from 'node:crypto';

export const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const UPSTREAM = 'https://beta.tcgtracking.com';
const HOUR = 60 * 60 * 1000;
const META_FIELDS = ['schema_version', 'status', 'category_id', 'game_name', 'group_id', 'set_name', 'set_abbr', 'published_on', 'generated_at', 'etag', 'product_count', 'grade_row_count', 'catalog_ref_url', 'opportunities_ref_url'];
const PRODUCT_FIELDS = ['product_id', 'name', 'ext_number', 'ext_rarity', 'catalog_market_price'];
const GRADE_FIELDS = ['grader', 'grade', 'grade_sort', 'pop', 'sales', 'guide_value', 'market_value', 'confidence', 'last_sold_at', 'synced_on'];
const STAT_FIELDS = ['value', 'confidence', 'market', 'high_all'];
const pick = (value, fields) => Object.fromEntries(fields.filter(key => Object.hasOwn(value, key)).map(key => [key, value[key]]));
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const identifier = value => /^[1-9][0-9]{0,11}$/.test(String(value)) && Number.isSafeInteger(Number(value));
const text = (value, max) => typeof value === 'string' && value.length > 0 && value.length <= max;
const secret = value => typeof value === 'string' && value.length >= 16 && value.length <= 512 && /^[\x21-\x7e]+$/.test(value);
const digest = value => createHash('sha256').update(value).digest();

export class APIError extends Error {
  constructor(status, code, message, retryAfter) { super(message); this.status = status; this.code = code; this.retryAfter = retryAfter; }
}
const invalid = () => new APIError(502, 'upstream_invalid_response', 'The research provider returned an unsupported response.');
function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers } });
}
function errorResponse(error) {
  const safe = error instanceof APIError ? error : new APIError(500, 'internal_error', 'The research service could not complete this request.');
  return json(safe.status, { error: { code: safe.code, message: safe.message } }, safe.retryAfter ? { 'Retry-After': String(safe.retryAfter) } : {});
}
function retrySeconds(value, fallback = 30) {
  if (/^[0-9]{1,6}$/.test(value ?? '')) return Math.max(1, Math.min(3600, Number(value)));
  return fallback;
}
async function boundedJSON(response) {
  const length = response.headers.get('Content-Length');
  if (length && /^[0-9]+$/.test(length) && Number(length) > MAX_RESPONSE_BYTES) {
    await response.body?.cancel();
    throw new APIError(502, 'upstream_response_too_large', 'The research provider response exceeds this service’s size limit.');
  }
  const chunks = []; let size = 0;
  if (response.body) {
    const reader = response.body.getReader();
    try {
      while (true) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.byteLength;
        if (size > MAX_RESPONSE_BYTES) {
          await reader.cancel();
          throw new APIError(502, 'upstream_response_too_large', 'The research provider response exceeds this service’s size limit.');
        }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
  }
  try { return JSON.parse(Buffer.concat(chunks, size).toString('utf8')); }
  catch { throw invalid(); }
}

function sanitizeGrade(row) {
  if (!record(row) || !text(row.grader, 16) || !text(row.grade, 24)) throw invalid();
  const result = pick(row, GRADE_FIELDS);
  if (row.daily_history === null) result.daily_history = null;
  else if (row.daily_history !== undefined) {
    if (!record(row.daily_history)) throw invalid();
    const history = pick(row.daily_history, ['updated_at']);
    if (row.daily_history.stats === null) history.stats = null;
    else if (row.daily_history.stats !== undefined) {
      if (!record(row.daily_history.stats)) throw invalid();
      const stats = pick(row.daily_history.stats, STAT_FIELDS);
      for (const [key, fields] of [['last_sale', ['price', 'date']], ['change', ['week', 'month', 'quarter', 'year']], ['month', ['sales', 'avg', 'low', 'high']], ['year', ['sales', 'avg', 'low', 'high']]]) {
        const value = row.daily_history.stats[key];
        if (value === null) stats[key] = null;
        else if (value !== undefined) { if (!record(value)) throw invalid(); stats[key] = pick(value, fields); }
      }
      history.stats = stats;
    }
    if (row.daily_history.series === null) history.series = null;
    else if (row.daily_history.series !== undefined) {
      if (!Array.isArray(row.daily_history.series) || row.daily_history.series.some(point => !Array.isArray(point) || point.length !== 3)) throw invalid();
      history.series = row.daily_history.series;
    }
    result.daily_history = history;
  }
  return result;
}
function sanitizeProduct(value, expected) {
  if (!record(value) || value.product_id !== expected || !text(value.name, 200) || !record(value.variants)) throw invalid();
  const result = pick(value, PRODUCT_FIELDS);
  if (record(value.images)) result.images = pick(value.images, ['front_200', 'front_400']);
  const variants = Object.create(null);
  for (const [key, variant] of Object.entries(value.variants)) {
    if (!text(key, 100) || !record(variant) || !text(variant.language, 2) || !text(variant.finish, 80) || key !== `${variant.language}:${variant.finish}` || !Array.isArray(variant.grades)) throw invalid();
    const safe = pick(variant, ['language', 'finish', 'updated_at']);
    if (variant.summary === null) safe.summary = null;
    else if (variant.summary !== undefined) {
      if (!record(variant.summary)) throw invalid();
      safe.summary = pick(variant.summary, ['raw_guide_value', 'psa10_guide_value', 'total_grades_tracked', 'total_sales_recorded']);
    }
    safe.grades = variant.grades.map(sanitizeGrade); variants[key] = safe;
  }
  result.variants = variants;
  return result;
}
function validateShard(body, category, group) {
  if (!record(body) || !record(body.meta) || !record(body.products) || body.meta.category_id !== category || body.meta.group_id !== group || !text(body.meta.schema_version, 32) || !text(body.meta.status, 32)) throw invalid();
  const products = Object.create(null);
  for (const [key, product] of Object.entries(body.products)) {
    if (!identifier(key)) throw invalid();
    products[key] = sanitizeProduct(product, Number(key));
  }
  return { meta: pick(body.meta, META_FIELDS), products };
}
export function normalizePSACertificate(value, certificateNumber) {
  if (!record(value) || value.certificateNumber !== certificateNumber || value.grader !== 'PSA' || !text(value.grade, 24) || !text(value.name, 200) || !text(value.source, 200)) throw invalid();
  const result = pick(value, ['certificateNumber', 'grader', 'grade', 'name', 'year', 'set', 'number', 'language', 'printing', 'imageURL', 'source', 'qualifiers', 'autographGrade']);
  for (const key of ['year', 'set', 'number', 'language', 'printing']) {
    if (result[key] !== undefined && result[key] !== null && (!text(result[key], 300))) throw invalid();
  }
  if (result.imageURL !== undefined && result.imageURL !== null) {
    try { const url = new URL(result.imageURL); if (url.protocol !== 'https:' || url.username || url.password) throw invalid(); }
    catch { throw invalid(); }
  }
  if (result.qualifiers !== undefined && result.qualifiers !== null) {
    const value = result.qualifiers;
    if (!(typeof value === 'string' && value.length <= 300) && !(Array.isArray(value) && value.length <= 20 && value.every(item => text(item, 80)))) throw invalid();
    // Keep a legacy combined qualifier intact; never guess comma semantics.
    if (typeof value === 'string') result.qualifiers = [value];
  }
  if (result.autographGrade !== undefined && result.autographGrade !== null && !text(result.autographGrade, 24)) throw invalid();
  return result;
}

/** All upstream credentials stay in this process. The phone uses its own token. */
export function createResearchHandler({ shipperID, apiKey, deviceToken, fetchImpl = fetch, now = Date.now, psaLookup = null,
  ttlMs = HOUR, maxEntries = 4, maxRequestsPerMinute = 120, rateWindowMs = 60_000, maxClients = 1024, maxPending = 4 } = {}) {
  if (!secret(deviceToken) || deviceToken.length < 32) throw new Error('RESEARCH_DEVICE_TOKEN must be a strong 32–512 character printable token.');
  if (!Number.isInteger(maxEntries) || maxEntries < 1 || maxEntries > 16 || !Number.isFinite(ttlMs) || ttlMs <= 0 || ttlMs > HOUR || !Number.isInteger(maxRequestsPerMinute) || maxRequestsPerMinute < 1 || !Number.isFinite(rateWindowMs) || rateWindowMs <= 0 || !Number.isInteger(maxClients) || maxClients < 1 || !Number.isInteger(maxPending) || maxPending < 1) throw new Error('Invalid bounded cache or rate limit configuration.');
  const expectedToken = digest(deviceToken);
  const researchConfigured = identifier(shipperID) && secret(apiKey);
  const cache = new Map(), pending = new Map(), clients = new Map(), cooldown = new Map();
  function rateLimit(clientIP) {
    const time = now();
    for (const [key, value] of clients) if (value.until <= time) clients.delete(key);
    const key = String(clientIP).slice(0, 128);
    let client = clients.get(key);
    if (!client) {
      if (clients.size >= maxClients) throw new APIError(429, 'rate_limited', 'Please wait before making another research request.', Math.ceil(rateWindowMs / 1000));
      client = { count: 0, until: time + rateWindowMs }; clients.set(key, client);
    }
    if (++client.count > maxRequestsPerMinute) throw new APIError(429, 'rate_limited', 'Please wait before making another research request.', Math.max(1, Math.ceil((client.until - time) / 1000)));
  }
  function remember(key, value) {
    cache.delete(key); cache.set(key, value);
    while (cache.size > maxEntries) cache.delete(cache.keys().next().value);
  }
  async function loadSet(category, group) {
    if (!researchConfigured) throw new APIError(503, 'research_not_configured', 'Configure Research API credentials on the server before requesting research.');
    const key = `${category}:${group}`, time = now(), previous = cache.get(key);
    if (previous && time >= previous.checkedAt && time < previous.checkedAt + ttlMs) { remember(key, previous); return previous.body; }
    const blocked = cooldown.get(key);
    if (blocked && time < blocked.until) throw blocked.error;
    if (blocked) cooldown.delete(key);
    if (pending.has(key)) return pending.get(key);
    if (pending.size >= maxPending) throw new APIError(503, 'server_busy', 'The research service is busy. Please retry shortly.', 2);
    const task = (async () => {
      const url = `${UPSTREAM}/v1/${category}/sets/${group}/research`;
      const headers = { Accept: 'application/json', 'X-Shipper-Id': String(shipperID), 'X-Api-Key': apiKey };
      if (previous?.etag) headers['If-None-Match'] = previous.etag;
      try {
        const response = await fetchImpl(url, { method: 'GET', headers, redirect: 'error', signal: AbortSignal.timeout(15_000) });
        if (response.status !== 200 || (response.url && response.url !== url)) {
          try { await response.body?.cancel(); } catch { /* Retain the safe status error. */ }
        }
        if (response.url && response.url !== url) throw invalid();
        if (response.status === 304) {
          if (!previous) throw invalid();
          remember(key, { ...previous, checkedAt: now() }); return previous.body;
        }
        if (response.status === 404) { cache.delete(key); throw new APIError(404, 'not_covered', 'Research is not available for this set.'); }
        if ([401, 403].includes(response.status)) throw new APIError(502, 'research_access_denied', 'The research provider rejected server access. Check the server’s credentials, subscription, and IP allowlist.');
        if (response.status === 429 || response.status === 503) throw new APIError(503, 'research_temporarily_unavailable', 'The research provider is temporarily unavailable. Please retry later.', retrySeconds(response.headers.get('Retry-After')));
        if (response.status !== 200) throw new APIError(502, 'research_unavailable', 'The research provider could not complete this request.');
        const body = validateShard(await boundedJSON(response), category, group);
        const etag = response.headers.get('ETag');
        remember(key, { body, etag: etag && etag.length <= 512 && !/[\r\n]/.test(etag) ? etag : undefined, checkedAt: now() });
        return body;
      } catch (error) {
        const safe = error instanceof APIError ? error : new APIError(error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 504 : 502, 'research_unavailable', 'The research provider could not complete this request.');
        const delay = safe.retryAfter ?? (safe.code === 'research_access_denied' ? 60 : safe.code === 'not_covered' ? 60 : 2);
        cooldown.delete(key); cooldown.set(key, { until: now() + delay * 1000, error: safe });
        while (cooldown.size > maxEntries) cooldown.delete(cooldown.keys().next().value);
        throw safe;
      }
    })();
    pending.set(key, task);
    try { return await task; } finally { if (pending.get(key) === task) pending.delete(key); }
  }
  return async function handle(request, { clientIP = 'unknown' } = {}) {
    try {
      const url = new URL(request.url);
      if (request.method !== 'GET') return json(405, { error: { code: 'method_not_allowed', message: 'Use GET for this endpoint.' } }, { Allow: 'GET' });
      if (url.search || url.hash || url.username || url.password) throw new APIError(400, 'invalid_request', 'Use an exact endpoint without query parameters.');
      const health = () => json(200, { status: 'ok', service: 'card-show-research', version: 1, researchConfigured, psaConfigured: typeof psaLookup === 'function' });
      if (url.pathname === '/health') return health();
      rateLimit(clientIP);
      const authorization = request.headers.get('Authorization') ?? '';
      const supplied = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
      if (supplied.length > 512 || !timingSafeEqual(digest(supplied), expectedToken)) throw new APIError(401, 'unauthorized', 'The research server requires a valid device token.');
      if (url.pathname === '/api/v1/health') return health();
      const route = /^\/api\/v1\/research\/([123])\/([1-9][0-9]{0,11})\/([1-9][0-9]{0,11})$/.exec(url.pathname);
      if (route) {
        const [, cat, group, product] = route;
        const body = await loadSet(Number(cat), Number(group));
        if (!Object.hasOwn(body.products, product)) throw new APIError(404, 'product_not_covered', 'Research is not available for this product in the selected set.');
        return json(200, { meta: body.meta, product: body.products[product] });
      }
      const psa = /^\/api\/v1\/psa\/cert\/([0-9]{6,12})$/.exec(url.pathname);
      if (psa) {
        if (typeof psaLookup !== 'function') throw new APIError(501, 'psa_not_configured', 'PSA certificate lookup is not configured. Select the card and grade manually to view research.');
        // The adapter must resolve an authorized provider response. A barcode is
        // never itself a catalog product ID, grade, price, or authenticity check.
        const value = await psaLookup(psa[1]);
        return json(200, normalizePSACertificate(value, psa[1]));
      }
      if (url.pathname.startsWith('/api/v1/psa/cert/')) throw new APIError(400, 'invalid_certificate', 'Enter a 6–12 digit certificate number.');
      if (url.pathname.startsWith('/api/v1/research/')) throw new APIError(400, 'invalid_identity', 'Choose supported category, set, and product identifiers.');
      throw new APIError(404, 'not_found', 'This endpoint does not exist.');
    } catch (error) { return errorResponse(error); }
  };
}
