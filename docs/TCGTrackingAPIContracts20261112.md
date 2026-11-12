# TCGTracking API coding reference — November 12, 2026

This records provider documentation and Postman responses reviewed with the user.
It is a coding/test reference, not a claim that the changes below are implemented.
No credentials, raw provider snapshots, screenshots or inventory are stored here.

The user authorized assuming the documented contracts work for other games. Treat
that as an implementation assumption; the live card examples were Pokémon.
Existing native/server Beta request guards still restrict categories to 1/2/3.

## Beta routes verified in Postman

| Method and route | Evidence reviewed |
| --- | --- |
| `GET /v1/meta` | Opportunities index; missing credentials returned 401, supplied credentials returned 200, HTTP ETag revalidation returned 304. |
| `GET /v1/categories` | Category array with IDs, names, counts and per-game set URLs. |
| `GET /v1/3/sets` | Pokémon index with 215 sets and matching category/set links. |
| `GET /v1/3/sets/22872` | Opportunities shard with exact-SKU pricing, listings, sales windows and chart fields. |
| `GET /v1/research/meta` | Experimental index covering seven categories and 262 sets. |
| `GET /v1/3/sets/{group}/research` | Groups 22872 and 23237: six products and 60 grade rows total. |

Counts are observations, not constants. A later index changed the promo set from
98 to 96 SKUs with a new data ETag. Earlier repeated Research-shaped uploads did
not verify Opportunities; the later distinct Opportunities responses did.

Use `X-Shipper-Id`, `X-Api-Key` and `Accept: application/json` at the fixed Beta
HTTPS origin. Keep credentials in device-only Keychain/server secrets, outside
source and logs. Postman's successful network does not establish iPhone IP access.

## Cache, budget and failure contract

- Share 120 authenticated requests per fixed 60-second window per Shipper ID
  across Research/Opps, including HEAD and 304. Observe rate-limit headers and
  Retry-After. Test throttling with fixtures rather than exhausting live limits.
- Check metadata every 10–15 minutes while active; fetch only needed sets whose
  data hash changed. Hourly provider changes are not a mandatory one-hour client
  waiting period when a new hash is already advertised.
- Compare index `categories[c].sets[g].etag` with cached shard `meta.etag`.
  Separately persist the HTTP ETag with its body; only that HTTP value, preserving
  weak validators/quotes, goes into If-None-Match. A 304 reuses the cached body.
- A 404 removes that set's body and HTTP validator. Do not automatically retry
  401/403; distinguish any cached data from successful fresh data.
- Network/5xx: bounded 1/2/4/8-second exponential backoff plus jitter, honor
  Retry-After, then fall back to valid cached data. Preserve cancellation.
- Provider guidance: 5-second connection/30-second read timeouts, sequential or
  low-concurrency fetching (2–4), disk persistence and visible generation times.
  A URLSession total/request timeout is not a separate connection timeout.
- Cache needed sets, not the whole catalog. Keep Research/Opps identities separate
  while sharing their budget. Missing coverage is unavailable, never zero.

## Opportunities: semantics and current gaps

Select `products[product_id].skus[sku_id]` by exact language, full printing and
condition. The reviewed public shard had 1,400 SKUs versus 98 in Beta: retain
public pricing for missing Beta SKUs. Production scanner/inventory prices still
use public OpenAPI; this document does not switch their source.

- `market_sku` is exact-SKU; `market_product` is finish-level product pricing.
  `avg_30d` can fall back to market average; only explicitly named sold-average
  fields establish an actual sold average. Keep card/shipping/landed costs separate.
- All 98 reviewed SKUs contain `marketplaces.manapool: null`. The native
  `[String: OpportunitiesMarketplace]` decoder rejects those null values; fix it
  to omit null entries while retaining valid marketplaces. My Server preserves
  the null and reaches the same native issue. This fix is not implemented here.
- Current native metadata lifetime is 24 hours; documented cadence, bounded
  retries and stale-cache fallback need implementation review.
- Native models omit opportunities, weekly series and chart buckets, plus most
  DoubleHolo fields. Server sanitization drops chart buckets and DoubleHolo.
- The 30/90/365-day windows support aggregate comparisons, not three chronological
  observations on a price-history line. V3 chart arrays (`d`/`t`, `p/q/dl/dh/lo/hi`)
  have unconfirmed units/encoding: raw `q` sums disagreed with explicit sales
  windows. Do not graph them as literal sales until clarified. Confirm 52-week
  bucket ordering/dates before assigning calendar dates.

## Experimental Research contract

No per-SKU Research route is documented. Cache a set, then select
`products[product_id].variants["language:fullPrinting"].grades[]` by exact grader
and full grade text. Preserve `9.5`, `10 Pristine`, `10 Black Label`, etc.
Population, guide estimates, market values and sales counts are distinct. RAW has
no NM/LP/MP/HP/DMG identity and cannot replace an exact-condition SKU quote.

Both live samples have only `daily_history: null` (25 + 35 grade rows); current
optional decoding supports this. Population/value charts can use grade fields;
daily charts/history-derived statistics remain unavailable for those responses.

The provided example defines optional future/non-null fields for coding and
clearly synthetic fixtures: `daily_history.updated_at`, `stats` (value, confidence,
market, high_all, last_sale {price,date}, change {week,month,quarter,year},
month/year {sales,avg,low,high}) and `series` rows `[YYYY-MM-DD, sold_count, avg_price]`.
Do not present example/generated points as live data. A populated live response
is still needed to verify history compatibility; preserve missing values/gaps.
Keep shard generation, variant update, grade sync, history update and last-sale
dates separate: a recent sync does not establish a recent sale or valuation.

## OpenAPI response inventory

Cache values below are provider guidance from the supplied screenshot, not the
app's implemented lifetimes. Public OpenAPI requests use no Beta credentials.

| Method and route | Provider cache | Live response evidence |
| --- | --- | --- |
| `GET /v1/meta` | 5 minutes | Actual response reviewed: version 1.1, catalog/pricing timestamps, counts, file types and last-export statistics. |
| `GET /v1/categories` | 7 days | Actual public response reviewed: `categories` array containing 64 entries with `id`, `name`, `display_name`, counts and relative `api_url`. |
| `GET /v1/{cat}/sets` | 7 days | Actual category 3 response reviewed: `sets` array with 288 unique positive `id` values, names, modification timestamps, counts and per-format relative URLs. |
| `GET /v1/{cat}/sets/{set}` | 7 days | Actual 3/23237 response reviewed: 249 products in a `products` array, including card and sealed-product examples, with set metadata and relative per-format URLs. |
| `GET /v1/{cat}/sets/{set}/cards` | 7 days | Actual 3/23237 response reviewed: `product_type: "cards"`, 215 unique products, all present in the reviewed full set. |
| `GET /v1/{cat}/sets/{set}/sealed` | 7 days | Actual 3/23237 response reviewed: `product_type: "sealed"`, 34 products, exactly the full-set entries absent from the cards-only response. |
| `GET /v1/{cat}/sets/{set}/product-detail` | 7 days | Actual returned hyphenated route 3/23237 verified: `success: true`, empty `errors`, `totalItems: 249` and matching `results` IDs. Screenshot's underscore alias remains unverified. |
| `GET /v1/{cat}/sets/{set}/pricing` | 1 day | Actual 3/23237 response reviewed: `set_id`, offset-bearing `updated`, and 249 product entries in `prices[productID].tcg[printing]` with `low`/`market`. |
| `GET /v1/{cat}/sets/{set}/skus` | 1 day | Actual 3/22872 and 3/23237 responses reviewed. The latter contains 1,874 unique SKUs across all 249 full-set product IDs; earlier exact promo SKU matched Beta's market reference. |
| `GET /v1/products/{product_id}` | 7 days | Earlier real 512035 fixture plus current 517045 response reviewed: matching root/nested product identity, set/category mapping, five SKU rows, dimensions and sync status. |
| `POST /v1/scan` | No store | Not tested; need the upload/body schema rather than guessing fields. |
| `GET /v1/{cat}/search?q={query}` | 5 minutes | Not yet verified; documented as set-name/abbreviation search. |

The reviewed public metadata snapshot reports 64 categories, 3,943 sets and
493,861 products. `last_updated` and `pricing_updated` are distinct fields, not
exact-SKU observation timestamps. `last_export_stats` describes one export run;
zero updated/exported counts do not establish an empty catalog or individual
SKU freshness.

The public category array identifies Pokémon as `id: 3`, with 218 sets and
33,099 products in the reviewed snapshot. Its `api_url` is `/v1/3/sets`.
Magic, Yu-Gi-Oh! and Pokémon Japan use IDs 1, 2 and 85. Preserve numeric IDs;
the public `id`/`name` fields differ from the Beta category response's field
names. Resolve relative API paths against the fixed public origin.

The actual public Pokémon set list contains 288 unique entries, although the
category summary reports 218 sets. Its summed product count is 33,099, matching
the category's product count. Preserve the count discrepancy without inferring
its cause; enumerate actual valid set IDs rather than treating the summary
count as an exact completion target. All reviewed `product_detail_url` values
end in `/product-detail` (hyphen), while the endpoint screenshot uses
`/product_detail` (underscore). Verify the returned route before choosing an
alias. Keep `products_modified`, `pricing_modified` and `skus_modified` separate;
the plain `modified_on` string has no explicit time-zone offset.

The full-set response uses `set_id`, `set_name`, `set_abbr`, `set_released`,
`product_count`, `data_modified`, `file_generated` and a `products` array. Its
products use `id`, `name`, `clean_name`, nullable `number`/`rarity`, `ext_data`,
image and marketplace links/IDs, plus optional `cardtrader` mappings. No explicit
top-level per-product card/sealed flag was present in this sample; use the
dedicated cards/sealed responses instead of guessing from names or null numbers.
Nested CardTrader game/category IDs belong to that marketplace, not the outer
TCGTracking category namespace. Catalog language/finish availability alone does
not establish price availability. Static `data_modified`/`file_generated` times
are separate from pricing/SKU freshness.

The reviewed cards-only response has the same product field vocabulary as the
full-set response, including collector `number` and `rarity`. Its 215 IDs form
a strict subset of the full set's 249 IDs. The sealed response independently
confirms the remaining 34 IDs, with zero card overlap and an exact union equal
to all 249 full-set products. Its product records also equal their full-set
counterparts. The cards
response does not include `product_detail_url`; cross-format URLs must be
optional. Its static modification/generation timestamps differ from the
full-set response and do not establish current pricing.

The verified product-detail response uses a separate TCGplayer-style envelope
(`totalItems`, `success`, `errors`, `results`) and camelCase product fields:
`productId`, `categoryId`, `groupId`, `cleanName`, `imageUrl`, `imageCount`,
`modifiedOn`, `presaleInfo` and `extendedData`. All 249 IDs match the full set;
all category/group IDs are 3/23237. `presaleInfo` includes `isPresale` and
nullable `releasedOn`/`note`. `extendedData` is an array of
`{name, displayName, value}` rather than the full-set `ext_data` dictionary.
Values can include HTML line breaks. `modifiedOn` examples lack an explicit
time-zone offset; preserve that distinction. This route supplies product
metadata, not an exact-condition SKU quote.

The reviewed pricing response covers all 249 full-set product IDs but groups
prices by product and printing only. It contains neither condition nor language
identity, so these values cannot substitute for exact-condition/language SKU
quotes. Its Pokémon sample has only `tcg` source blocks; the documented Magic
`mp` extension remains an assumed provider contract rather than a reviewed live
response. Preserve product-price and exact-SKU price provenance separately.

The 151 SKU response is a product-ID to SKU-ID object map with `cnd`, `var`,
`var_a`, `vid`, `lng`, `mkt`, `low`, `hi` and `cnt`. Its snapshot contains only
`EN`, five condition codes (NM/LP/MP/HP/DMG), and Normal/Reverse Holofoil/Holofoil
printings. There are 501 null `mkt` values and no zero markets; retain unavailable
prices rather than substituting zero or a different condition. Preserve reported
prices even when different conditions are not monotonically priced. Public
sealed-product examples use NM condition, so do not invent an Unopened identity.
Do not interpret `cnt` as sold volume or owned stock without a documented
definition. The SKU `updated` timestamp is November 11, while the separately
reviewed product-pricing `updated` is November 12: those payloads have independent
freshness, so a price difference cannot be attributed solely to identity/finish.

The current single-product response uses `success`, `product_id`, `product`,
`prices`, a `skus` array, `sku_count`, `sku_dimensions`, `sku_sync_status` and
CardTrader mappings. Root/nested product IDs match 517045, category 3 and group
23237. Detailed SKU rows use full condition/variant/language names and numeric
IDs, decimal-string prices, and separate price/checked/sync timestamps. These
are not the compact fields/object maps used by set-level `/skus`.

This sample demonstrates stale per-product price data: exact SKU 7436747 reports
306.49 with an October 22 price timestamp, while the set-level SKU snapshot
reports 294 with a November 11 update. Do not replace newer exact-SKU set prices
with these older product-response prices. The app's existing product lookup
recovers catalog mapping only; preserve that separation. Nullable Manapool,
presale and cross-marketplace mapping fields remain optional.

Documentation and mocked tests do not prove live contracts. Continue missing
response checks one at a time with HTTP status. These notes change no inventory,
settings, pricing provenance, camera behavior or UI.
