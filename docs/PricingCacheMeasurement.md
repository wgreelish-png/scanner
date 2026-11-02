# Measure a Pokémon pricing cache with Postman

Import [TCGTracking-Pricing-Cache-Measurement.postman_collection.json](../postman/TCGTracking-Pricing-Cache-Measurement.postman_collection.json). It measures the public OpenAPI responses needed to cache card metadata and condition/printing/language SKU prices. It does not change the app, import inventory, or call Beta/Research endpoints. No API key, account, or environment is required.

The collection has not been used to measure live provider data as part of this change. Its output will establish actual sizes; no total storage figure is assumed here.

## Quick sample run

1. Import the collection into Postman and select **No environment**.
2. Open its **Variables** tab. Keep the defaults below for a Pokémon sample.
3. Click **Run collection**. Select all four requests, **one iteration**, and start with **01 Categories and reset**. Disable saving/persisting response bodies if your Runner offers that option; measurement does not need them. Leave **Keep variable values** enabled if that option is available so you can copy the summary afterward.
4. Open **Postman Console** to see progress. The collection itself waits one second before each request. An additional Runner delay is safe but makes the run slower.
5. At the end, copy the JSON value of collection variable **`tcgt_cache_summary`** into a file and share that file. The final response's **Visualize** view also shows the summary when the Postman client supports it.

Run the collection in Collection Runner, not by clicking **Send** on one request. `setNextRequest` controls the loop only during a collection run. There are no downloaded response files to upload, and the summary does not contain account credentials or raw provider response bodies.

| Collection variable | Default | Purpose |
| --- | --- | --- |
| `tcgt_cache_category_id` | `3` | Documented Pokémon category. A different known numeric category can be measured separately. |
| `tcgt_cache_mode` | `sample` | `sample` measures selected sets; `full` measures every discovered set. |
| `tcgt_cache_sample_size` | `12` | Sample size, from 1 to 100; ignored in full mode. |
| `tcgt_cache_delay_ms` | `1000` | Delay before each request, from 1000 to 10000 ms. The minimum keeps this run at 60 requests/minute or fewer. |
| `tcgt_cache_max_retries` | `2` | Maximum additional attempts per endpoint after HTTP 429/503, from 0 to 2; each requires explicit resume. |
| `tcgt_cache_resume` | `false` | Set to `true` only to resume a paused run after `retry_not_before`; resets automatically when the paused request resumes. |
| `tcgt_cache_summary` | generated | Results to copy/share. |
| `tcgt_cache_state` | generated | Internal loop state; do not edit during a run. |
| `tcgt_cache_set_id` | generated | Current discovered set; do not edit during a run. |

Request names, in order:

1. **01 Categories and reset** — `GET /v1/categories`
2. **02 Discover sets** — `GET /v1/3/sets`
3. **03 Measure card metadata** — `GET /v1/3/sets/{set_id}/cards`
4. **04 Measure SKU pricing** — `GET /v1/3/sets/{set_id}/skus`

Requests 03–04 repeat for each selected set. The sample sorts numeric set IDs and spaces selections evenly across that list; it does not assume set ID order represents release date, size, or popularity. A one-set sample selects the midpoint. A normal 12-set sample makes 26 requests before any retries.

## Measure the entire category

After the sample succeeds, change **`tcgt_cache_mode`** to **`full`** and run all four requests again, with **one iteration**. With `tcgt_cache_resume=false`, request 01 starts a fresh measurement and clears prior derived results. A full run needs `2 + 2 × discovered set count` requests before retries, so allow at least that many seconds at the default delay, plus response time.

A full result is exact for the validated responses downloaded during that run only when **`coverage_complete` is true**. A partial run reports failed endpoints and does not extrapolate missing payloads. Provider data can change during a long run; this is a measurement of fetched responses, not a simultaneous database snapshot.

For an unattended command-line run with Newman installed:

```sh
newman run postman/TCGTracking-Pricing-Cache-Measurement.postman_collection.json \
  --iteration-count 1 --collection-var tcgt_cache_mode=full \
  --export-collection /tmp/TCGTracking-cache-measurement-results.json
```

The exported collection contains the `tcgt_cache_summary` variable. Newman is optional; it is not installed or invoked by this collection.

## Read the results

The most useful fields are:

- **`measured.static_cards_decoded_bytes`**: validated `/cards` bodies actually fetched. Static metadata can normally be retained for at least seven days.
- **`measured.initial_cards_and_skus_decoded_bytes`**: the initial metadata plus pricing download for the measured sets. Later pricing-only refreshes use `daily_skus_decoded_bytes`.
- **`measured.daily_skus_decoded_bytes`**: validated `/skus` bodies actually fetched. These include exact condition/printing/language prices; the provider recommends daily updates, around 9:35 AM ET.
- **`full_category_planning`**: full-run measured totals or explicitly labeled sample extrapolation. Sample estimates are exploratory averages, not a confidence interval or a storage guarantee. The estimate is withheld if any selected set fails.
- **`measured.sku_count`**, **`card_product_count`**, and **`card_matched_sku_count`**: actual row counts. SKU payloads may include sealed products. The card-matched count joins SKU product IDs to the corresponding `/cards` IDs, while byte measurements always include the entire `/skus` download.
- **`known_market_quote_count`**, **`zero_market_quote_count`**, and **`missing_market_quote_count`**: a known zero price is counted as a quote; missing/null prices are counted separately.
- **`measurements`**: each set's HTTP status, size, counts, response time, and provider `updated` timestamp when present. A card response without an outer set ID is labeled `fixed_request_path_only`; it is not represented as an identity-verified envelope.
- **`current_app_cache_limits`**: comparison against the existing app's four-set / 32 MiB total / 8 MiB single-body bounds. The comparison measures the existing limits; this collection does not enlarge them.

**Bytes have different meanings.** `decoded_body_bytes` is the exact UTF-8 length of the decoded response text, including non-ASCII names. It is not compressed wire transfer or SQLite database size. `content_length_bytes`, when present, records the server's body length and the accompanying `content_encoding`; it excludes HTTP/TLS overhead and can be absent for chunked responses. Postman's `responseSize` is recorded separately when exposed by the runtime, without assuming what its compression accounting means.

`decoded_response_bytes_all_attempts` includes discovery, failed responses, and retries; validated cache payload totals include successful final set responses only. `content_length_bytes_where_present` covers recorded final set responses with that header, not missing lengths or all retry traffic. Summed response milliseconds exclude deliberate delays; elapsed seconds include the run's time between responses.

The two-snapshot staging number is **2 × decoded payload**, a planning allowance for replacing saved JSON while retaining the previous snapshot. It is not a measured database footprint. Images, recognition hashes/runtime, filesystem overhead, SQLite indexes, compression savings, and iPhone memory pressure require separate measurements. This collection does not verify offline iPhone behavior.

`/pricing` is deliberately omitted: `/skus` already supplies the condition-specific market quotes needed by the app. Fetching both on every refresh would add a separate payload. `/cards` excludes sealed metadata, but there is no assumed undocumented `/cards/skus` route.

## Errors, throttling and safety

The default one-second delay stays around 60 requests per minute or fewer before network time. Do not run several collections in parallel under the same allowance. Every attempt is counted in the results, including retry requests.

HTTP 429/503 stops the Runner immediately with `status=retry_waiting`, `resume_request`, `retry_after_seconds`, and `retry_not_before`. `Retry-After` can be seconds or an HTTP date; a missing/invalid header defaults to five seconds. There is no automatic retry or long script sleep.

To resume, wait until `retry_not_before`, set **`tcgt_cache_resume=true`**, and run **all four requests from 01 with one iteration**, retaining the generated state. Earlier requests are skipped without downloading them. The paused request then runs again, the flag resets to `false`, and the loop continues with its prior counts and current set. Starting early is blocked before sending a request. At most two additional attempts per endpoint are allowed across resumes. A fresh run with `tcgt_cache_resume=false` discards prior progress; an active provider wait still blocks it until `retry_not_before`. Resume is through collection variables, so retain/export those variables if closing Postman; no raw-body files are needed.

After retry exhaustion the failed endpoint is recorded and the run halts. Start a new run after `retry_not_before`; stopping also prevents a subsequent endpoint from ignoring the provider wait. A different HTTP error is recorded once, then the run continues. An unrepresentable `Retry-After` date stops with a clear reason rather than sending an early retry.

The public `/cards.products` array and `/skus.products` product→SKU map follow the supplied public documentation and app parser. `/sets` must return a `sets` array with positive numeric `id`, `group_id`, or `set_id` fields; aliases must agree if several are present. An unknown set wrapper, conflicting IDs, or more than 2000 sets stops with a clear summary rather than guessing. The optional categories response is accepted only as a `categories` array with `id`/`category_id`. An unrecognized category wrapper produces a warning and uses the explicitly configured numeric category 3; it does not infer categories from names or Beta contracts. A live run is still needed to verify the provider's current discovery wrappers.

Only fixed-host HTTPS GET URLs are permitted. Requests explicitly use **No Auth**, remove credential/conditional headers, disable redirects, and request cookie-jar disabling. If your Postman version does not honor the exported cookie setting, open each request's **Settings** and turn on **Disable cookie jar**. Use no environment and do not add authorization headers. The collection does not clear your existing cookies. It never prints provider response bodies; progress logs and results contain public measurement metadata only.

The transient join contains only the current set's card IDs and is removed after its SKU request. Saved state is bounded to 2 MiB and discovery to 2000 sets. Response validation rejects decoded bodies over 64 MiB after they have been downloaded; this is not a network transfer or runtime memory cap. State overflow halts the Runner and clears stale loop state. A bound failure means the run is incomplete, not that the provider has no data. Request order is enforced so repeating an endpoint cannot double-count it.

## Local verification

The companion test file executes the exported Postman scripts in a mocked sandbox, without network access:

```sh
node --test postman/test_pricing_cache_collection.mjs
```

Those checks cover UTF-8 sizing, verified schemas and zero/missing prices, sample/full loops, partial failures, explicit bounded retry/resume, fixed URLs, auth stripping, request order, reset behavior, and metadata-only saved state. They do not substitute for running the collection against the live provider or testing an actual offline cache on an iPhone.

After implementation completed, all 24 synthetic measurement-script tests passed. No live dataset size was measured in this workspace.
