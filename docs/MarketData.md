# Public pricing and OppsV2 market activity

Build 19 adds **Market Details & Sales Activity** in the saved-card editor and scanner confirmation screen. It uses public OpenAPI prices and the independent OppsV2 market-activity API. Graded Research remains a separate experimental feature with its own product coverage.

## Using Market Details

Open a saved list, edit a card, then choose **Market Details & Sales Activity**. The scanner confirmation screen offers the same link for its current selected card. The screen shows the captured card's product, full printing, language and condition. It does not change the inventory draft, apply a quote, save a card, alter scan order or recalculate saved offers. Each service loads independently, so a missing/denied OppsV2 response leaves public pricing available. Each section can be retried independently. Leaving the screen cancels pending work and older responses cannot replace a newer lookup.

Public details include the selected SKU's market, low/high listing prices and active listing count, where returned. Provider update time and retrieval time are separate. Listing prices/counts are not completed sales. The existing **Existing TCGTracking / Open API** price selector still controls inventory/scanner market-price lookups; opening the supplemental public-details screen does not switch that setting.

OppsV2 details include the selected SKU's reported quantities and explicitly reported sold averages for the documented 30/90/365-day windows, comparable listing card prices/shipping/totals, quantities and source timestamps. Missing fields remain unavailable and returned zeroes remain zero. `pricing.avg_30d` can include a market-price average fallback; it is not labeled as a sold average. Only `trends.windows.*.tcg_sold_avg` supplies a TCGplayer sold average. Reported activity does not establish future demand or guaranteed profit. Opportunities are a partial dataset centered on active opportunities; a missing card is not evidence of zero sales or stock.

Provider percentage trends are also shown as signed values from `trend_30d_vs_90d_pct`, `trend_90d_pct` and `tcg_mp_trend_30d_pct`. The last retains the provider's unexpanded **TCG MP** label because the shared documentation does not define that abbreviation. No demand or profit score is inferred from these values.

## Connections

Settings → **TCGTracking API Connection** reuses existing device-only Keychain credentials and the saved Direct/My Server access method. **Test Market Activity** checks OppsV2 using `/v1/meta`, while **Test Graded Research** checks `/v1/research/meta`. Tests use entered drafts; **Save Connection** applies the values. Valid credentials can be saved without passing a Research test. Existing saved credentials and signing configuration are retained.

- **Direct TCGTracking:** uses the fixed `https://beta.tcgtracking.com` origin, `X-Shipper-Id` and `X-Api-Key`. The subscription must permit Opportunities access and the phone's current public outbound IP must be allowlisted. Moving between Wi-Fi/cellular/VPN can change that IP.
- **My Server:** uses the saved HTTPS server origin and separate device bearer token. Deploy the updated [server adapter](../server/research/README.md) to expose `/api/v1/opportunities/{category}/{group}/{product}`. Its upstream Beta keys stay on the server. The server's `opportunitiesConfigured` health flag reports configuration, not verified provider entitlement or exact-card coverage. An older server that omits the flag is reported as not supporting that check.

Research and OppsV2 use separate shard/cache namespaces; Research access failures cannot populate an OppsV2 response. Direct OppsV2 retains at most four hourly set bodies in memory, separated by credentials. ETags revalidate expired bodies, HTTP 404 removes a shard, and 429/503 cooldowns honor bounded Retry-After values. No background bulk polling or automatic repeated authentication attempts are introduced. The server shares bounded cache, queue and rate budgets across the two services.

## Previously downloaded OpenAPI prices offline

Selecting **Open API** now retains up to four recently fetched, validated public SKU set responses on disk, with a 32 MiB total cap. Successful online lookups populate the cache automatically. Disk data is separate from recognition packs, website cookies, Beta credentials and saved offers.

On a genuine connectivity failure, an available cached set can supply the exact product/printing/language/condition quote. It is labeled **cached / offline**, keeps its original provider/retrieval timestamps, and does not become a fresh online response. A missing condition, ambiguous SKU or missing market value remains unavailable. Authentication/HTTP errors, malformed responses and canceled requests do not silently return cached data. The selected pricing provider is never switched as a fallback.

This is a bounded recent-price cache, not an offline copy of every inventory price or an offline Research/Opportunities database. Looking up a set outside the retained four still needs internet. Public prices are documented as daily data, so current internet access does not imply a real-time sale quote. Existing offline recognition behavior is unchanged and needs its own physical-device acceptance.

## Endpoints used

| Purpose | Endpoint |
| --- | --- |
| Public exact-condition SKU prices/context | `GET https://openapi.tcgtracking.com/v1/{category}/sets/{group}/skus` |
| Beta Opportunities connection check | `GET https://beta.tcgtracking.com/v1/meta` |
| Direct Beta Opportunities set | `GET https://beta.tcgtracking.com/v1/{category}/sets/{group}` |
| Own-server exact product activity | `GET {configured-origin}/api/v1/opportunities/{category}/{group}/{product}` |

Set IDs come from exact product references in the downloaded native v2 recognition metadata. Card names or collector numbers never guess a set, and a price for another printing/condition/language is never substituted. The single-product OpenAPI route is not a fallback until its actual response contract and mapping fields have been verified. It is not necessary for the existing SKU or documented OppsV2 paths above.

## Validation and device acceptance

The feature includes native fixtures for price-cache persistence, exact SKU context, missing/zero values, cancellation, independent service completion and failure, read-only inventory/offers behavior, and OppsV2 identity/cache/HTTP handling. The server has synthetic route, sanitization, isolation and bounded-cache/queue/rate tests. Postman checks provide independent requests with the same catalog identifiers. Fixture success does not establish live provider coverage or physical-iPhone behavior.

Import [`postman/TCGTracking-Market.postman_collection.json`](../postman/TCGTracking-Market.postman_collection.json) with the existing empty local-credential environment to check public SKU prices and OppsV2 independently of Research. It defaults to the confirmed category/set/product IDs `3 / 22872 / 512035` and the exact EN/Holofoil/Near Mint selection. Run once, then share `tcgt_market_summary`; it omits credentials and request headers. See the [Postman instructions](../postman/README.md).

On an updated physical iPhone, check a known covered exact SKU; change printing, condition and language; verify public prices remain usable when OppsV2 is missing/denied; compare reported values to the raw provider response; navigate back to confirm the saved price/offers are unchanged; verify direct and deployed-server access separately; fetch public quotes online, restart with poor reception/Airplane Mode and verify cached/offline labels plus original times; test a condition not present in the saved set; and confirm scan → select → next-card behavior remains reliable.
