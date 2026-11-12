# TCGTracking API coding reference — November 12, 2026

This records the provider documentation and Postman responses reviewed with the
user. It is a contract reference for implementation and tests, not a claim that
the app changes below have already been implemented or that every game/SKU has
been tested. No credentials, raw provider snapshots, screenshots or inventory
are stored here.

The user authorized assuming the documented contracts work for other games.
Use that as an implementation assumption; the live examples below are Pokémon.
Keep category support tied to registered catalog identities rather than card
names. Existing native/server Beta guards still restrict requests to categories
1/2/3 and need review before claiming broader implemented support.

## Beta endpoints verified in Postman

| Method and route | Evidence reviewed |
| --- | --- |
| `GET /v1/meta` | Opportunities index with 63 categories, per-set data ETags and set URLs; missing credentials returned 401, supplied credentials returned 200, HTTP ETag revalidation returned 304. |
| `GET /v1/categories` | Category array with category IDs, names, counts and per-category set URLs. |
| `GET /v1/3/sets` | Pokémon index with 215 sets and matching category/set links. |
| `GET /v1/3/sets/22872` | Opportunities shard with exact SKU pricing, listings, opportunities, sales windows and chart fields. |
| `GET /v1/research/meta` | Experimental Research index covering seven categories and 262 sets. |
| `GET /v1/3/sets/{group}/research` | Reviewed groups 22872 and 23237: six products and 60 grade rows in total. |

Counts are snapshot observations, not constants. A later Pokémon set index
changed the promo set from 98 to 96 SKUs and supplied a different data ETag.
The earlier repeated Research-shaped bodies did not verify the Opportunities
routes; the later distinct Opportunities responses did.

Requests use `X-Shipper-Id`, `X-Api-Key` and `Accept: application/json` against the
fixed Beta HTTPS origin. Keep credentials in device-only Keychain or the
selected server's secret storage, outside source, logs and exported summaries.
These live checks used Postman's network and do not establish the iPhone's
current IP allowlist state.

## Cache, request budget and failure contract

- Share the 120-request fixed 60-second budget per Shipper ID across Research
  and Opportunities. Every authenticated request counts, including HEAD and 304.
  Observe `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` and
  `Retry-After`; do not deliberately exhaust the live limit for testing.
- Check relevant metadata approximately every 10–15 minutes while active. Set
  content changes at most hourly; that is not a mandatory one-hour client
  waiting period when the index already advertises a changed hash.
- Compare the index's `categories[c].sets[g].etag` with the cached shard's
  `meta.etag` to decide whether a download is needed.
- Separately store the HTTP `ETag` header with its body. Preserve weak validators
  and quotes. Only that HTTP value goes into `If-None-Match`; never send the
  index/shard data hash as the HTTP validator.
- Persist validated bodies and their HTTP validators together. A 304 reuses the
  stored body. A 404 removes the corresponding set body and validator.
- Do not automatically retry 401/403. Report the access problem and distinguish
  any available cached data from a successful fresh response.
- For network/5xx failures, use bounded exponential backoff with jitter
  (documented sequence 1/2/4/8 seconds), honor Retry-After, and then use the last
  valid cached copy when available. Respect cancellation throughout.
- The provider recommends 5-second connection and 30-second read timeouts and
  sequential or low-concurrency set fetching (2–4). Do not describe a URLSession
  total/request timeout as an independently enforced connection timeout.
- Show provider generation/update times and cached/stale state. A recent cache
  retrieval or synchronization date does not establish a recent sale or price.

Only download needed sets and reuse them for local selection of products/SKUs or
Research variants/grades. The API does not require caching its entire catalog.
Keep Research and Opportunities cache identities separate while sharing their
rate budget. Missing coverage is unavailable, not a zero price or sales count.

## Opportunities: confirmed semantics and implementation gaps

Select `products[product_id].skus[sku_id]` using exact language, full printing and
condition. The reviewed public response contained 1,400 SKUs, while its Beta
counterpart contained 98 at that time. Beta opportunity coverage is a subset;
retain public pricing for missing exact SKUs. Existing production scanner and
inventory quotes still use public OpenAPI. No change of default price source is
recorded by this document.

- `pricing.market_sku` is the exact-SKU market reference.
- `pricing.market_product` is a finish-level product reference and cannot replace
  a missing exact-condition quote.
- `pricing.avg_30d` can fall back to a market average. Only explicit sold-average
  fields such as `trends.windows["30d"].tcg_sold_avg` establish that meaning.
- Preserve card-only, shipping-inclusive and landed-cost comparisons as distinct
  measures. A discount against card price is not a landed-price discount.
- The actual shard includes `marketplaces.manapool: null` in every reviewed SKU.
  The current native dictionary decoder requires non-null marketplace objects
  and would reject that product. A compatibility fix must omit null entries
  while retaining valid marketplaces. The own-server path preserves the null
  and reaches the same native issue.
- The current native metadata lifetime is 24 hours, rather than the supplied
  10–15-minute refresh guidance. Retry/stale-cache behavior also needs work;
  current successful-response caching alone is not the documented outage policy.
- Native models currently omit opportunity objects, weekly series and chart
  buckets; most DoubleHolo fields are also omitted. The server strips chart
  buckets and DoubleHolo through its existing sanitization rules.

The documented 30/90/365-day windows support comparisons of reported sales
volumes and available sold averages. They are overlapping aggregation windows,
not three chronological observations of a price-history line.

The reviewed shard has version-2 and version-3 `chart_buckets_90d` objects. V3
uses `d`/`t` blocks and arrays including `p/q/dl/dh/lo/hi`. Their units and
encoding are not fully documented. For the reviewed target, summing raw `q`
values produced totals inconsistent with the explicit sales windows. Do not
graph these arrays as literal sold quantities until the provider confirms the
encoding/aggregation. The supplied 52-week series is a separate field; confirm
bucket order/date semantics before assigning calendar dates.

## Experimental Research coding contract

Research has no documented per-SKU endpoint. Cache a set shard and select:

```text
products[product_id]
  → variants[language + ":" + fullPrinting]
  → grades[] matching exact grader and full grade text
```

Preserve grade labels such as `9.5`, `10 Pristine` and `10 Black Label`; do not
merge them into a numeric grade. Population, guide estimates, market values and
reported historical sales are distinct measures. RAW has no exact NM/LP/MP/HP/
DMG condition identity and cannot substitute for an exact-condition SKU quote.

Both live Research samples have every `daily_history` explicitly null: 25 rows
in the promo set and 35 in Scarlet & Violet 151. Current optional decoding
supports those nulls. Population and valuation comparisons can use the supplied
grade fields; daily-history graphs and history-derived statistics remain
unavailable for those responses.

The provider's example documents a future/non-null history contract:

```text
daily_history.updated_at
daily_history.stats:
  value, confidence, market, high_all, last_sale {price, date},
  change {week, month, quarter, year},
  month/year {sales, avg, low, high}
daily_history.series:
  [date (YYYY-MM-DD), sold_count, average_price]
```

Use that example to define optional models and clearly synthetic test fixtures.
Do not present example prices or generated points as live results. A real,
populated history response is still needed for live compatibility verification.
Preserve missing values and gaps rather than replacing them with zero.

Keep shard `generated_at`, variant `updated_at`, grade `synced_on`, history
`updated_at` and `last_sold_at` separate. The reviewed data demonstrates that a
recent sync can coexist with a much older last recorded sale.

## OpenAPI response inventory

The cache column below is provider guidance from the supplied endpoint screenshot,
not a statement of the app's currently implemented lifetime. Public OpenAPI
requests use no Beta credential headers.

| Method and route | Provider cache | Reviewed live response evidence |
| --- | --- | --- |
| `GET /v1/meta` | 5 minutes | Not yet captured/verified in this review. |
| `GET /v1/categories` | 7 days | Not yet captured/verified; the Beta categories response is a different API. |
| `GET /v1/{cat}/sets` | 7 days | Documented/used by diagnostic tooling; no confirmed live response retained for this review. |
| `GET /v1/{cat}/sets/{set}` | 7 days | Not yet captured/verified. |
| `GET /v1/{cat}/sets/{set}/cards` | 7 days | Documented in pricing-cache tooling; no confirmed live response retained for this review. |
| `GET /v1/{cat}/sets/{set}/sealed` | 7 days | Not yet captured/verified. |
| `GET /v1/{cat}/sets/{set}/product_detail` | 7 days | Not yet captured/verified. |
| `GET /v1/{cat}/sets/{set}/pricing` | 1 day | Not yet captured/verified; distinct from exact-SKU quotes. |
| `GET /v1/{cat}/sets/{set}/skus` | 1 day | Actual set 3/22872 response reviewed; exact SKU matched the Beta example's market price. |
| `GET /v1/products/{product_id}` | 7 days | Earlier real product 512035 response retained as `Tests/Fixtures/OpenAPICharmanderProduct.json`. |
| `POST /v1/scan` | No store | Not tested. Request-body/upload schema is needed; do not guess JSON fields or multipart field names. |
| `GET /v1/{cat}/search?q={query}` | 5 minutes | Not yet captured/verified; documentation describes set-name/abbreviation search. |

Documentation, mocked tests and an endpoint screenshot do not establish a live
response contract. Continue gathering missing responses one request at a time,
including the actual HTTP status. These observations do not change saved
inventory, settings, price provenance, camera behavior or UI design.
