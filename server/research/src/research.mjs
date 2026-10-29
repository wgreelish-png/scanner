import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { lstat, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const UPSTREAM = 'https://beta.tcgtracking.com';
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const META_FIELDS = ['schema_version', 'status', 'category_id', 'game_name', 'group_id', 'set_name', 'set_abbr', 'published_on', 'generated_at', 'etag', 'product_count', 'grade_row_count', 'catalog_ref_url', 'opportunities_ref_url'];
const PRODUCT_FIELDS = ['product_id', 'name', 'ext_number', 'ext_rarity', 'catalog_market_price'];
const GRADE_FIELDS = ['grader', 'grade', 'grade_sort', 'pop', 'sales', 'guide_value', 'market_value', 'confidence', 'last_sold_at', 'synced_on'];
const STAT_FIELDS = ['value', 'confidence', 'market', 'high_all'];
const OPPORTUNITY_META_FIELDS = ['schema_version', 'category_id', 'game_name', 'group_id', 'set_name', 'set_abbr', 'published_on', 'generated_at', 'etag', 'opp_count', 'product_count', 'sku_count'];
const PRICE_FIELDS = ['market_product', 'market_sku', 'live_market', 'avg_30d', 'listed_low_card', 'listed_low_ship', 'listed_low_total', 'direct_low_card'];
const WINDOW_FIELDS = ['tcg_qty', 'tcg_market_avg', 'tcg_sold_avg', 'tcg_sold_avg_with_sh', 'mp_qty', 'mp_avg', 'combined_qty'];
const TIMESTAMP_FIELDS = ['opp_computed_at', 'tcgp_live_updated_at', 'last_verified_at', 'tcgp_sales_updated_at', 'mp_sales_updated_at', 'product_scrape_fetched_at'];
const MAX_SKUS = 512;
const MAX_LISTINGS = 20;
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

// OppsV2 is a separate, condition-specific set shard. Never feed these rows
// through the graded Research schema or infer a sale from pricing.avg_30d.
function fields(value, { strings = [], numbers = [], booleans = [] } = {}) {
  if (!record(value)) throw invalid();
  const result = pick(value, [...strings, ...numbers, ...booleans]);
  for (const key of strings) if (result[key] != null && (typeof result[key] !== 'string' || result[key].length > 512)) throw invalid();
  for (const key of numbers) {
    const item = result[key];
    if (item != null && !(typeof item === 'number' && Number.isFinite(item)) && !(typeof item === 'string' && /^-?[0-9]{1,20}(?:\.[0-9]{1,8})?$/.test(item))) throw invalid();
  }
  for (const key of booleans) if (result[key] != null && typeof result[key] !== 'boolean') throw invalid();
  return result;
}
function optionalObject(result, source, key, sanitize) {
  if (source[key] === null) result[key] = null;
  else if (source[key] !== undefined) result[key] = sanitize(source[key]);
}
function safeLinks(value, rules) {
  if (!record(value)) throw invalid();
  const result = {};
  for (const [key, rule] of Object.entries(rules)) {
    if (value[key] === null) { result[key] = null; continue; }
    if (value[key] === undefined) continue;
    // Links are display/navigation metadata, never upstream proxy targets.
    // Drop unsupported optional links without discarding useful pricing rows.
    if (typeof value[key] !== 'string' || value[key].length > 500) continue;
    try {
      const url = new URL(value[key]);
      if (url.protocol === 'https:' && !url.username && !url.password && !url.port && rule(url)) result[key] = value[key];
    } catch { /* An optional untrusted link is omitted. */ }
  }
  return result;
}
const tcgLink = url => ['www.tcgplayer.com', 'tcgplayer.com', 'shop.tcgplayer.com'].includes(url.hostname);
const manapoolLink = url => ['manapool.com', 'www.manapool.com'].includes(url.hostname);
function sanitizeOpportunity(value) {
  const result = fields(value, {
    strings: ['unavailable_reason', 'unavailable_at', 'best_source', 'opp_key'],
    numbers: ['buy_card', 'fee_amount', 'ship_1x', 'cost_1x'], booleans: ['is_available'],
  });
  optionalObject(result, value, 'pack_free_ship', row => fields(row, { numbers: ['buy_qty', 'cost_pack_unit', 'cost_effective'] }));
  optionalObject(result, value, 'benchmarks', benchmarks => {
    if (!record(benchmarks)) throw invalid();
    const safe = {};
    for (const key of ['market_product', 'market_sku', 'avg_30d', 'listed_card', 'listed_direct', 'listed_total']) {
      optionalObject(safe, benchmarks, key, row => fields(row, { strings: ['cmp_basis'], numbers: ['ref', 'cmp_cost', 'savings', 'discount_pct'] }));
    }
    return safe;
  });
  optionalObject(result, value, 'tightest_default', row => fields(row, { strings: ['low_key'], numbers: ['ref_price', 'savings', 'discount_pct'] }));
  return result;
}
function sanitizeMarketplace(value, source, productID) {
  const manapool = source === 'manapool';
  const result = fields(value, {
    strings: ['updated_at', ...(manapool ? ['seller_detail_status'] : [])], booleans: ['available'],
    numbers: manapool ? ['low_price', 'fee_amount', 'estimated_ship_1x', 'landed_1x', 'total_qty_available'] : ['direct_low_card', 'total_qty_available'],
  });
  Object.assign(result, safeLinks(value, { product_url: url => manapool ? manapoolLink(url) : tcgLink(url) && url.pathname === `/product/${productID}` }));
  if (value.listings === null) result.listings = null;
  else if (value.listings !== undefined) {
    if (!Array.isArray(value.listings) || value.listings.length > MAX_LISTINGS) throw invalid();
    result.listings = value.listings.map(row => {
      const listing = fields(row, {
        strings: ['seller_name', 'updated_at', ...(manapool ? ['seller_id', 'origin_country'] : ['seller_key'])],
        numbers: ['rank', 'price', 'ship_price', 'landed_price', 'seller_qty', ...(manapool ? ['fee_amount'] : [])],
        booleans: manapool ? ['us_disable_first_class'] : [],
      });
      Object.assign(listing, safeLinks(row, { seller_url: url => manapool ? manapoolLink(url) : tcgLink(url) && url.pathname.startsWith('/sellerfeedback/') }));
      return listing;
    });
  }
  return result;
}
function sanitizeTrends(value) {
  const result = fields(value, { strings: ['updated_at'], numbers: ['trend_30d_vs_90d_pct', 'trend_90d_pct', 'tcg_mp_trend_30d_pct'], booleans: ['triple_trend_pass'] });
  optionalObject(result, value, 'windows', windows => {
    if (!record(windows)) throw invalid();
    const safe = {};
    for (const key of ['30d', '90d', '365d']) optionalObject(safe, windows, key, row => fields(row, { numbers: WINDOW_FIELDS }));
    return safe;
  });
  optionalObject(result, value, 'series_52w', series => {
    if (!record(series)) throw invalid();
    const safe = {};
    for (const key of ['tcg_qty', 'mp_qty']) {
      if (series[key] === null) safe[key] = null;
      else if (series[key] !== undefined) {
        if (!Array.isArray(series[key]) || series[key].length > 52 || series[key].some(item => item !== null && !(Number.isSafeInteger(item) && item >= 0))) throw invalid();
        safe[key] = series[key];
      }
    }
    return safe;
  });
  // The provider names chart_buckets_90d but does not document its child
  // fields. Do not forward arbitrary nested objects under that name.
  if (value.chart_buckets_90d === null) result.chart_buckets_90d = null;
  return result;
}
function sanitizeOpportunityProduct(value, expected) {
  if (!record(value) || value.product_id !== expected || !text(value.name, 200) || !record(value.skus) || Object.keys(value.skus).length > MAX_SKUS) throw invalid();
  const result = fields(value, { strings: ['name', 'ext_number', 'ext_rarity'], numbers: ['product_id', 'image_count'], booleans: ['is_sealed', 'is_token'] });
  optionalObject(result, value, 'images', images => safeLinks(images, Object.fromEntries(['front_200', 'front_400', 'back_200', 'back_400'].map(key => [key, url => url.hostname === 'cdn.tcgtracking.com' && new RegExp(`^/product/${expected}(?:_2)?_(?:200|400)w\\.jpg$`).test(url.pathname)]))));
  optionalObject(result, value, 'links', links => safeLinks(links, { tcgplayer: url => tcgLink(url) && url.pathname === `/product/${expected}`, tcg_affiliate: tcgLink }));
  const skus = Object.create(null);
  for (const [key, row] of Object.entries(value.skus)) {
    if (!/^[1-9][0-9]{0,19}$/.test(key) || !record(row) || !Object.hasOwn(row, 'sku_id') ||
      (row.sku_id !== null && !((typeof row.sku_id === 'string' || Number.isSafeInteger(row.sku_id)) && String(row.sku_id) === key)) ||
      !Number.isInteger(row.condition_id) || row.condition_id < 1 || row.condition_id > 6 || row.condition !== ['Near Mint', 'Lightly Played', 'Moderately Played', 'Heavily Played', 'Damaged', 'Unopened'][row.condition_id - 1] || !text(row.finish, 30) || !text(row.language, 20)) throw invalid();
    const sku = fields(row, { strings: ['condition', 'finish', 'language', 'manapool_id'], numbers: ['sku_id', 'condition_id'] });
    optionalObject(sku, row, 'timestamps', timestamps => fields(timestamps, { strings: TIMESTAMP_FIELDS }));
    optionalObject(sku, row, 'pricing', pricing => fields(pricing, { numbers: PRICE_FIELDS }));
    optionalObject(sku, row, 'opportunity', sanitizeOpportunity);
    optionalObject(sku, row, 'opportunities_by_source', sources => {
      if (!record(sources)) throw invalid();
      const safe = {};
      for (const source of ['manapool', 'tcg']) optionalObject(safe, sources, source, sanitizeOpportunity);
      return safe;
    });
    optionalObject(sku, row, 'marketplaces', marketplaces => {
      if (!record(marketplaces)) throw invalid();
      const safe = {};
      for (const source of ['manapool', 'tcgplayer']) optionalObject(safe, marketplaces, source, market => sanitizeMarketplace(market, source, expected));
      return safe;
    });
    optionalObject(sku, row, 'trends', sanitizeTrends);
    skus[key] = sku;
  }
  result.skus = skus;
  return result;
}
function validateOpportunitiesShard(body, category, group) {
  if (!record(body) || !record(body.meta) || !record(body.products) || body.meta.category_id !== category || body.meta.group_id !== group || !text(body.meta.schema_version, 32)) throw invalid();
  const meta = fields(body.meta, { strings: OPPORTUNITY_META_FIELDS.filter(key => !['category_id', 'group_id', 'opp_count', 'product_count', 'sku_count'].includes(key)), numbers: ['category_id', 'group_id', 'opp_count', 'product_count', 'sku_count'] });
  Object.assign(meta, safeLinks(body.meta, { catalog_ref_url: url => url.hostname === 'openapi.tcgtracking.com' && url.pathname === `/v1/${category}/sets/${group}.json` }));
  optionalObject(meta, body.meta, 'flags', flags => fields(flags, { booleans: ['mp_seller_listings_blocked'], numbers: ['mp_singles_buyer_fee_pct', 'mp_free_ship_threshold_us', 'mp_default_ship_singles', 'mp_default_ship_sealed'] }));
  const products = Object.create(null);
  for (const [key, product] of Object.entries(body.products)) {
    if (!identifier(key)) throw invalid();
    products[key] = sanitizeOpportunityProduct(product, Number(key));
  }
  return { meta, products };
}
function validateIndex(body) {
  if (!record(body) || !record(body.categories)) throw invalid();
  const categories = Object.create(null);
  for (const [category, value] of Object.entries(body.categories)) {
    if (!identifier(category) || !record(value) || !record(value.sets) || (value.category_id !== undefined && value.category_id !== Number(category))) throw invalid();
    const sets = Object.create(null);
    for (const [group, row] of Object.entries(value.sets)) {
      if (!identifier(group) || !record(row) || (row.group_id !== undefined && row.group_id !== Number(group)) || (row.category_id !== undefined && row.category_id !== Number(category))) throw invalid();
      if (row.etag !== undefined && row.etag !== null && !text(row.etag, 128)) throw invalid();
      sets[group] = row.etag == null ? {} : { etag: row.etag };
    }
    categories[category] = { sets };
  }
  // The index is internal cadence metadata. Do not retain arbitrary URLs,
  // provider diagnostics or other fields in memory or the disk snapshot.
  return { categories };
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
  ttlMs = DAY, indexTTLms = DAY, syncIndex = true, cacheDirectory = null, maxUpstreamRequestsPerMinute = 120,
  maxEntries = 4, maxRequestsPerMinute = 120, rateWindowMs = 60_000, maxClients = 1024, maxPending = 4 } = {}) {
  if (!secret(deviceToken) || deviceToken.length < 32) throw new Error('RESEARCH_DEVICE_TOKEN must be a strong 32–512 character printable token.');
  if (!Number.isInteger(maxEntries) || maxEntries < 1 || maxEntries > 16 || !Number.isFinite(ttlMs) || ttlMs <= 0 || ttlMs > DAY || !Number.isFinite(indexTTLms) || indexTTLms <= 0 || indexTTLms > DAY || typeof syncIndex !== 'boolean' || (cacheDirectory !== null && (typeof cacheDirectory !== 'string' || !cacheDirectory.length)) || !Number.isInteger(maxUpstreamRequestsPerMinute) || maxUpstreamRequestsPerMinute < 1 || maxUpstreamRequestsPerMinute > 120 || !Number.isInteger(maxRequestsPerMinute) || maxRequestsPerMinute < 1 || !Number.isFinite(rateWindowMs) || rateWindowMs <= 0 || !Number.isInteger(maxClients) || maxClients < 1 || !Number.isInteger(maxPending) || maxPending < 1) throw new Error('Invalid bounded cache or rate limit configuration.');
  const expectedToken = digest(deviceToken);
  const researchConfigured = identifier(shipperID) && secret(apiKey);
  const cache = new Map(), pending = new Map(), clients = new Map(), cooldown = new Map();
  const upstreamRate = { window: Math.floor(now() / 60_000) * 60_000, used: 0, limit: maxUpstreamRequestsPerMinute, remaining: null, resetAt: 0, blockedUntil: 0, inFlight: 0 };
  let restorePromise, persistPromise = Promise.resolve();
  const snapshotPath = cacheDirectory ? join(cacheDirectory, 'cache.json') : null;
  async function restore() {
    if (!snapshotPath) return;
    if (!restorePromise) restorePromise = (async () => {
      try {
        const stat = await lstat(snapshotPath);
        if (!stat.isFile() || stat.size > maxEntries * MAX_RESPONSE_BYTES + 65_536) return;
        const saved = JSON.parse(await readFile(snapshotPath, 'utf8'));
        if (!record(saved) || saved.version !== 1 || !Array.isArray(saved.entries) || saved.entries.length > maxEntries) return;
        const restored = [];
        for (const row of saved.entries) {
          if (!record(row) || typeof row.key !== 'string' || !Number.isFinite(row.checkedAt) || row.checkedAt < 0 || row.checkedAt > now() || (row.etag !== undefined && !validETag(row.etag)) || Buffer.byteLength(JSON.stringify(row.body)) > MAX_RESPONSE_BYTES) return;
          let body;
          const shard = /^(research|opportunities):([123]):([1-9][0-9]{0,11})$/.exec(row.key);
          if (/^index:(research|opportunities)$/.test(row.key)) body = validateIndex(row.body);
          else if (shard) body = (shard[1] === 'research' ? validateShard : validateOpportunitiesShard)(row.body, Number(shard[2]), Number(shard[3]));
          else return;
          restored.push([row.key, { body, etag: row.etag, checkedAt: row.checkedAt }]);
        }
        for (const [key, value] of restored) cache.set(key, value);
      } catch { /* Missing, corrupt or inaccessible cache is a cold start. */ }
    })();
    await restorePromise;
  }
  async function persist() {
    if (!snapshotPath) return;
    // Serialize writes so an older network completion cannot overwrite newer
    // state. Only sanitized bodies, validators and timestamps are persisted.
    const snapshot = JSON.stringify({ version: 1, entries: [...cache].map(([key, value]) => ({ key, ...value })) });
    persistPromise = persistPromise.then(async () => {
      const temporary = `${snapshotPath}.${randomUUID()}.tmp`;
      try {
        await mkdir(cacheDirectory, { recursive: true, mode: 0o700 });
        await writeFile(temporary, snapshot, { mode: 0o600, flag: 'wx' });
        await rename(temporary, snapshotPath);
      } catch { try { await unlink(temporary); } catch { /* Best-effort cache. */ } }
    });
    await persistPromise;
  }
  const validETag = value => typeof value === 'string' && value.length > 0 && value.length <= 512 && !/[\r\n]/.test(value);
  function upstreamBlocked(until) {
    return new APIError(503, 'upstream_rate_limited', 'The Beta request budget is temporarily exhausted. Please retry later.', Math.max(1, Math.ceil((until - now()) / 1000)));
  }
  function reserveUpstream() {
    const time = now();
    if (time < upstreamRate.window || time >= upstreamRate.window + 60_000) { upstreamRate.window = Math.floor(time / 60_000) * 60_000; upstreamRate.used = 0; }
    if (time >= upstreamRate.resetAt) { upstreamRate.remaining = null; upstreamRate.resetAt = 0; }
    if (time < upstreamRate.blockedUntil) throw upstreamBlocked(upstreamRate.blockedUntil);
    if (upstreamRate.remaining === 0) throw upstreamBlocked(upstreamRate.resetAt);
    if (upstreamRate.used >= upstreamRate.limit) throw upstreamBlocked(upstreamRate.window + 60_000);
    upstreamRate.used++;
    upstreamRate.inFlight++;
    if (upstreamRate.remaining !== null) upstreamRate.remaining = Math.max(0, upstreamRate.remaining - 1);
  }
  function observeUpstream(response) {
    const number = name => { const value = response.headers.get(name); return /^[0-9]{1,6}$/.test(value ?? '') ? Number(value) : null; };
    const limit = number('X-RateLimit-Limit'), remaining = number('X-RateLimit-Remaining'), reset = number('X-RateLimit-Reset');
    if (limit !== null && limit > 0) upstreamRate.limit = Math.min(maxUpstreamRequestsPerMinute, limit);
    if (remaining !== null || (limit !== null && limit > 0 && reset !== null)) {
      // Other in-flight calls may consume slots after this response snapshot.
      // Never increase an already observed allowance within the same window.
      const available = remaining !== null ? Math.max(0, Math.min(120, remaining) - Math.max(0, upstreamRate.inFlight - 1)) : Math.max(0, Math.min(120, limit) - upstreamRate.used);
      upstreamRate.remaining = upstreamRate.remaining === null ? available : Math.min(upstreamRate.remaining, available);
      upstreamRate.resetAt = Math.max(upstreamRate.resetAt, reset !== null ? now() + Math.max(1, Math.min(3600, reset)) * 1000 : upstreamRate.window + 60_000);
    }
    if ([429, 503].includes(response.status)) upstreamRate.blockedUntil = Math.max(upstreamRate.blockedUntil, now() + retrySeconds(response.headers.get('Retry-After')) * 1000);
  }
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
  async function loadRemote(key, kind, url, validate, previous) {
    const opportunities = kind === 'opportunities';
    const label = opportunities ? 'market insights' : 'research';
    const time = now();
    const blocked = cooldown.get(key);
    if (blocked && time < blocked.until) throw blocked.error;
    if (blocked) cooldown.delete(key);
    if (pending.has(key)) return pending.get(key);
    if (pending.size >= maxPending) throw new APIError(503, 'server_busy', 'The research service is busy. Please retry shortly.', 2);
    const task = (async () => {
      const headers = { Accept: 'application/json', 'X-Shipper-Id': String(shipperID), 'X-Api-Key': apiKey };
      if (previous?.etag) headers['If-None-Match'] = previous.etag;
      try {
        reserveUpstream();
        let response;
        try {
          response = await fetchImpl(url, { method: 'GET', headers, redirect: 'error', signal: AbortSignal.timeout(15_000) });
          if (!response.url || response.url === url) observeUpstream(response);
        } finally { upstreamRate.inFlight--; }
        if (response.status !== 200 || (response.url && response.url !== url)) {
          try { await response.body?.cancel(); } catch { /* Retain the safe status error. */ }
        }
        if (response.url && response.url !== url) throw invalid();
        if (response.status === 304) {
          if (!previous) throw invalid();
          remember(key, { ...previous, checkedAt: now() }); await persist(); return previous.body;
        }
        if (response.status === 404) { cache.delete(key); await persist(); throw new APIError(404, 'not_covered', opportunities ? 'Market insights are not available for this set.' : 'Research is not available for this set.'); }
        if ([401, 403].includes(response.status)) throw new APIError(502, `${kind}_access_denied`, opportunities ? 'The Beta provider rejected server access. Check the server’s credentials, Beta access, and IP allowlist.' : 'The research provider rejected server access. Check the server’s credentials, subscription, and IP allowlist.');
        if (response.status === 429 || response.status === 503) throw new APIError(503, `${kind}_temporarily_unavailable`, `The ${label} provider is temporarily unavailable. Please retry later.`, retrySeconds(response.headers.get('Retry-After')));
        if (response.status !== 200) throw new APIError(502, `${kind}_unavailable`, `The ${label} provider could not complete this request.`);
        const body = validate(await boundedJSON(response));
        const etag = response.headers.get('ETag');
        remember(key, { body, etag: validETag(etag) ? etag : undefined, checkedAt: now() });
        await persist();
        return body;
      } catch (error) {
        const safe = error instanceof APIError ? error : new APIError(error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 504 : 502, `${kind}_unavailable`, `The ${label} provider could not complete this request.`);
        const delay = safe.retryAfter ?? (safe.code === `${kind}_access_denied` ? 60 : safe.code === 'not_covered' ? 60 : 2);
        cooldown.delete(key); cooldown.set(key, { until: now() + delay * 1000, error: safe });
        while (cooldown.size > maxEntries) cooldown.delete(cooldown.keys().next().value);
        throw safe;
      }
    })();
    pending.set(key, task);
    try { return await task; } finally { if (pending.get(key) === task) pending.delete(key); }
  }
  async function loadIndex(kind, force) {
    const key = `index:${kind}`, previous = cache.get(key), time = now();
    if (!force && previous && time >= previous.checkedAt && time < previous.checkedAt + indexTTLms) { remember(key, previous); return previous.body; }
    const url = `${UPSTREAM}/v1/${kind === 'research' ? 'research/' : ''}meta`;
    return loadRemote(key, kind, url, validateIndex, previous);
  }
  async function loadSet(category, group, kind = 'research', force = false) {
    if (!researchConfigured) throw new APIError(503, `${kind}_not_configured`, kind === 'opportunities' ? 'Configure Beta API credentials on the server before requesting market insights.' : 'Configure Research API credentials on the server before requesting research.');
    await restore();
    const index = syncIndex ? await loadIndex(kind, force) : null;
    const key = `${kind}:${category}:${group}`, previous = cache.get(key), time = now();
    const dataHash = index?.categories?.[category]?.sets?.[group]?.etag;
    // The data hash is only a comparison token. HTTP If-None-Match always
    // comes from the matching endpoint's stored HTTP ETag header.
    if (previous && dataHash && previous.body.meta.etag === dataHash) { remember(key, previous); return previous.body; }
    const changed = dataHash && previous && previous.body.meta.etag !== dataHash;
    if (!force && !changed && previous && time >= previous.checkedAt && time < previous.checkedAt + ttlMs) { remember(key, previous); return previous.body; }
    const url = `${UPSTREAM}/v1/${category}/sets/${group}${kind === 'opportunities' ? '' : '/research'}`;
    return loadRemote(key, kind, url, body => (kind === 'opportunities' ? validateOpportunitiesShard : validateShard)(body, category, group), previous);
  }
  return async function handle(request, { clientIP = 'unknown' } = {}) {
    try {
      const url = new URL(request.url);
      if (request.method !== 'GET') return json(405, { error: { code: 'method_not_allowed', message: 'Use GET for this endpoint.' } }, { Allow: 'GET' });
      if (url.search || url.hash || url.username || url.password) throw new APIError(400, 'invalid_request', 'Use an exact endpoint without query parameters.');
      const health = () => json(200, { status: 'ok', service: 'card-show-research', version: 1, researchConfigured, opportunitiesConfigured: researchConfigured, psaConfigured: typeof psaLookup === 'function' });
      if (url.pathname === '/health') return health();
      rateLimit(clientIP);
      const authorization = request.headers.get('Authorization') ?? '';
      const supplied = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
      if (supplied.length > 512 || !timingSafeEqual(digest(supplied), expectedToken)) throw new APIError(401, 'unauthorized', 'The research server requires a valid device token.');
      if (url.pathname === '/api/v1/health') return health();
      const force = /(?:^|,)\s*no-cache\s*(?:,|$)/i.test(request.headers.get('Cache-Control') ?? '');
      const route = /^\/api\/v1\/research\/([123])\/([1-9][0-9]{0,11})\/([1-9][0-9]{0,11})$/.exec(url.pathname);
      if (route) {
        const [, cat, group, product] = route;
        const body = await loadSet(Number(cat), Number(group), 'research', force);
        if (!Object.hasOwn(body.products, product)) throw new APIError(404, 'product_not_covered', 'Research is not available for this product in the selected set.');
        return json(200, { meta: body.meta, product: body.products[product] });
      }
      const opportunityRoute = /^\/api\/v1\/opportunities\/([123])\/([1-9][0-9]{0,11})\/([1-9][0-9]{0,11})$/.exec(url.pathname);
      if (opportunityRoute) {
        const [, category, group, product] = opportunityRoute;
        const body = await loadSet(Number(category), Number(group), 'opportunities', force);
        if (!Object.hasOwn(body.products, product)) throw new APIError(404, 'product_not_covered', 'Market insights are not available for this product in the selected set.');
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
      if (url.pathname.startsWith('/api/v1/research/') || url.pathname.startsWith('/api/v1/opportunities/')) throw new APIError(400, 'invalid_identity', 'Choose supported category, set, and product identifiers.');
      throw new APIError(404, 'not_found', 'This endpoint does not exist.');
    } catch (error) { return errorResponse(error); }
  };
}
