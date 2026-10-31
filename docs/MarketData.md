# Public pricing and OppsV2 market activity

Build 22 includes **Market Details & Sales Activity** in the saved-card editor and scanner confirmation screen, with [evidence summaries and native charts](EvidenceVisualizations.md). It uses public OpenAPI prices and the separate OppsV2 market-activity API. Graded Research remains an experimental feature with its own product coverage. Both services use TCGTracking data and are not independent price checks.

## Using Market Details

Open a saved list, edit a card, then choose **Market Details & Sales Activity**. The scanner confirmation screen offers the same link for its current selected card. The screen shows the captured card's product, full printing, language and condition. It does not change the inventory draft, apply a quote, save a card, alter scan order or recalculate saved offers. Each service loads independently, so a missing/denied OppsV2 response leaves public pricing available. Each section can be retried independently. Leaving the screen cancels pending work and older responses cannot replace a newer lookup.

Public details include the selected SKU's market, low/high listing prices and active listing count, where returned. Provider update time and retrieval time are separate. Listing prices/counts are not completed sales. Build 27 uses Open API for all inventory/scanner market-price lookups, with no provider selector. Opening supplemental market activity never replaces an inventory quote or saves a new price.

OppsV2 details include the selected SKU's reported quantities and explicitly reported sold averages for the documented 30/90/365-day windows, comparable listing card prices/shipping/totals, quantities and source timestamps. Missing fields remain unavailable and returned zeroes remain zero. `pricing.avg_30d` can include a market-price average fallback; it is not labeled as a sold average. Only `trends.windows.*.tcg_sold_avg` supplies a TCGplayer sold average. Reported activity does not establish future demand or guaranteed profit. Opportunities are a partial dataset centered on active opportunities; a missing card is not evidence of zero sales or stock.

Provider percentage trends are also shown as signed values from `trend_30d_vs_90d_pct`, `trend_90d_pct` and `tcg_mp_trend_30d_pct`. The last retains the provider's unexpanded **TCG MP** label because the shared documentation does not define that abbreviation. No demand or profit score is inferred from these values.

## Connections

Settings → **TCGTracking API Connection** reuses existing device-only Keychain credentials and the saved Direct/My Server access method. **Test Market Activity** checks OppsV2 using `/v1/meta`, while **Test Graded Research** checks `/v1/research/meta`. Tests use entered drafts; **Save Connection** applies the values. Valid credentials can be saved without passing a Research test. Existing saved credentials and signing configuration are retained.

- **Direct TCGTracking:** uses the fixed `https://beta.tcgtracking.com` origin, `X-Shipper-Id` and `X-Api-Key`. The subscription must permit Opportunities access and the phone's current public outbound IP must be allowlisted. Moving between Wi-Fi/cellular/VPN can change that IP.
- **My Server:** uses the saved HTTPS server origin and separate device bearer token. Deploy the updated [server adapter](../server/research/README.md) to expose `/api/v1/opportunities/{category}/{group}/{product}`. Its upstream Beta keys stay on the server. The server's `opportunitiesConfigured` health flag reports configuration, not verified provider entitlement or exact-card coverage. An older server that omits the flag is reported as not supporting that check.

Research and OppsV2 use separate shard/cache namespaces. Following the user’s daily-refresh preference, their indices are checked on demand at most once every 24 hours. Each needed shard contains all available products/SKUs for its set; changing cards in that set reuses the same body. The index data hash is compared to the cached shard meta.etag: an unchanged hash skips the shard request entirely, while a changed hash fetches that needed shard. Index and shard HTTP ETags are stored separately and only those HTTP validators are sent as If-None-Match. Manual refresh revalidates the index sooner; it does not force provider regeneration. No background polling or bulk download of all games is introduced.

A shared native coordinator proactively caps authenticated Research/Opps requests at 120 per fixed 60-second window per shipper, including metadata, HEAD and 304 attempts. It respects provider Limit/Remaining/Reset headers and Retry-After on 429/503. Cache keys include credential identity, while the request budget remains shipper-specific even after key rotation. The updated server likewise shares its own upstream budget across both families and separately limits incoming device requests. Independent external apps/processes are outside these local budgets, so provider response headers remain authoritative. Cancellation interrupts queued waits.

Validated, account-isolated native snapshots persist across app launches, with up to four combined Beta shard bodies within 32 MiB and an 8 MiB index pool; the bounded in-memory caches remain separate from saved inventory and offers. A full/evicted/missing cache can require another request for a needed set. The server optionally persists its bounded snapshots on a configured writable volume. Old data timestamps are preserved and a provider/auth failure is not presented as a newly refreshed response.

## Previously downloaded OpenAPI prices offline

Standard Open API pricing retains up to four recently fetched, validated public SKU set responses on disk, with a 32 MiB total cap. Successful online lookups populate the cache automatically. Fresh bodies are reused for 24 hours, including after a restart, and labeled cached without claiming an offline connection. Refresh Market Price can revalidate sooner. Disk data is separate from recognition packs, website cookies, Beta credentials and saved offers.

On a genuine connectivity failure, an available cached set can supply the exact product/printing/language/condition quote. It is labeled **cached / offline**, keeps its original provider/retrieval timestamps, and does not become a fresh online response. A missing condition, ambiguous SKU or missing market value remains unavailable. Authentication/HTTP errors, malformed responses and canceled requests do not silently return cached data. Pricing never switches to a website quote as a fallback.

These are bounded recent-data caches, not complete offline copies of every inventory card or provider dataset. Beta views require a usable cached index and shard, or connectivity to refresh them. Looking up a set outside the retained four still needs internet. Public prices are documented as daily data, so current internet access does not imply a real-time sale quote. Existing offline recognition behavior is unchanged and needs its own physical-device acceptance.

## Endpoints used

| Purpose | Endpoint |
| --- | --- |
| Public exact-condition SKU prices/context | `GET https://openapi.tcgtracking.com/v1/{category}/sets/{group}/skus` |
| Recover an exact product's category/set metadata | `GET https://openapi.tcgtracking.com/v1/products/{product}` |
| Beta Opportunities connection check | `GET https://beta.tcgtracking.com/v1/meta` |
| Direct Beta Opportunities set | `GET https://beta.tcgtracking.com/v1/{category}/sets/{group}` |
| Own-server exact product activity | `GET {configured-origin}/api/v1/opportunities/{category}/{group}/{product}` |

Set IDs first come from exact product references in the downloaded native v2 recognition metadata. If that lookup cannot resolve a set, public pricing and OppsV2 can recover the exact product's mapping from `/v1/products/{product}`. Both the outer and nested product IDs, category and positive set/group ID must match before it is used. Card names or collector numbers never guess a set, and the captured card's identity is not rewritten.

The single-product response contract was verified against the user's successful Charmander response, retained as `Tests/Fixtures/OpenAPICharmanderProduct.json`. Its product-level market value was **68.63**, while its exact Near Mint Holofoil SKU was **47.55** and Lightly Played was **42.70**. These are historical fixture values, not current price claims. The product lookup recovers metadata only: its aggregate or finish-level prices never replace the exact-condition quote from the SKU pricing route.

Recovered metadata is retained for seven days in a separate bounded cache of at most 128 small records. It stores only validated IDs, names and image metadata, not the endpoint's raw prices or account data. On a connectivity failure, an older verified mapping can support the separate cached-SKU lookup. HTTP/malformed responses and cancellation remain failures. Normal native catalog resolution remains an offline-only reader and is preferred whenever it supplies an exact mapping. This does not change the weekly recognition-database update policy.

## Validation and device acceptance

The feature includes native fixtures for price-cache persistence, exact SKU context, missing/zero values, cancellation, independent service completion and failure, read-only inventory/offers behavior, and OppsV2 identity/cache/HTTP handling. The server has synthetic route, sanitization, isolation and bounded-cache/queue/rate tests. Postman checks provide independent requests with the same catalog identifiers. Fixture success does not establish live provider coverage or physical-iPhone behavior.

Import [`postman/TCGTracking-Market.postman_collection.json`](../postman/TCGTracking-Market.postman_collection.json) with the existing empty local-credential environment to check public SKU prices and OppsV2 independently of Research. It defaults to the confirmed category/set/product IDs `3 / 22872 / 512035` and the exact EN/Holofoil/Near Mint selection. Run once, then share `tcgt_market_summary`; it omits credentials and request headers. See the [Postman instructions](../postman/README.md).

On an updated physical iPhone, check a known covered exact SKU; change printing, condition and language; verify public prices remain usable when OppsV2 is missing/denied; compare reported values to the raw provider response; navigate back to confirm the saved price/offers are unchanged; verify direct and deployed-server access separately; fetch public quotes online, restart with poor reception/Airplane Mode and verify cached/offline labels plus original times; test a condition not present in the saved set; and confirm scan → select → next-card behavior remains reliable.
