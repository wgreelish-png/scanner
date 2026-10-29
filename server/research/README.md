# Card Show Scanner research server

This Node.js 22 service keeps TCGTracking Beta credentials on your server. The iPhone sends a separate device token. It retrieves the documented set-level Research and Opportunities v2 APIs and returns only the requested catalog product. It also accepts an optional **authorized normalized certificate service** for PSA metadata. It does not guess an official PSA endpoint or scrape certificate pages.

The iPhone also offers **Direct TCGTracking** Research requests using user-entered device-only Keychain credentials. This Node component runs only on a server; it is optional for that direct Research mode and remains useful for a stable allowlisted outbound IP. Direct mode does not resolve PSA certificates. A saved server connection can continue to supply the authorized certificate bridge independently of the selected Research method.

The package is dependency-free. From this directory, run `npm test` for the mocked contract tests. Those fixtures are explicitly synthetic; passing tests do not establish live Research/Opportunities coverage, an actual sale, or successful PSA access.

## Configure and run

1. Install Node.js 22 or later on the server, or use the supplied Dockerfile.
2. Copy `.env.example` to a private `.env` outside version control. Generate a new device token, for example with `openssl rand -hex 32`. Set:
   - `RESEARCH_DEVICE_TOKEN`: a unique 32–512 character printable token. This goes in the app's **My Server** Research connection settings; it is **not** a TCGTracking API key.
   - `TCG_BETA_SHIPPER_ID`: your BetaSupporter shipper ID.
   - `TCG_BETA_API_KEY`: your Beta API key, shared by the separate Research and Opportunities adapters.
3. Add this server's public outbound IP to the TCGTracking Beta IP allowlist. The phone's changing IP is not the upstream caller.
4. Run `node --env-file=.env src/server.mjs`. Plain `npm start` reads values already supplied in the process environment. The default listener is `127.0.0.1:8787`; empty device-token configuration refuses startup.
5. Put your existing HTTPS reverse proxy in front of the listener. For example, a Caddy site:

   ```caddy
   research.your-domain.example {
       reverse_proxy 127.0.0.1:8787
   }
   ```

6. In the app's Research Connection settings, choose **My Server** and enter that HTTPS origin and device token. Do not enter Beta or PSA provider credentials in the server device-token field. A connection check confirms your app-to-server connection and configuration flags; the first real research request verifies upstream authorization and coverage. The separate Direct TCGTracking method accepts Beta credentials in its own fields and does not use this server for Research.

The service accepts only GET, with no request body or query parameters. Headers, client rates, connections, pending upstream requests, bodies and caches are bounded. The HTTP wrapper uses the actual socket peer for rate limits and ignores untrusted `X-Forwarded-For`; devices behind one reverse proxy share the rate bucket. Ensure proxy access logs do not record Authorization values. Keep `.env` readable only to the server account. Certificate identifiers appear in request paths, so configure access-log retention appropriately for this personal service.

For Docker, build from this directory, provide the environment at runtime and bind the published port to loopback behind HTTPS. The image copies only package metadata and source, never `.env`. `HOST=0.0.0.0` is set inside the container; do not expose its plain HTTP port directly to the Internet. Docker execution has not been validated in the cloud workspace.

## App API

All `/api/v1/*` requests require `Authorization: Bearer <RESEARCH_DEVICE_TOKEN>`. Public `GET /health` is a minimal liveness/configuration check with no credentials. Authenticated `GET /api/v1/health` returns the same body:

```json
{
  "status": "ok",
  "service": "card-show-research",
  "version": 1,
  "researchConfigured": true,
  "opportunitiesConfigured": true,
  "psaConfigured": false
}
```

These flags report configuration, not verified provider access. Research and Opportunities use the same configured Beta credentials; their coverage and authorization are checked independently on their first real requests. `opportunitiesConfigured` does not assert a Research subscription or successful Beta access.

### Research

`GET /api/v1/research/{category}/{group}/{product}` uses positive numeric catalog IDs. Supported categories are 1 (Magic), 2 (Yu-Gi-Oh!) and 3 (Pokémon). The phone must establish the exact catalog match and set ID first; a card name, collector number or PSA cert is not a product ID.

The response is:

```text
{
  "meta": { documented upstream research metadata },
  "product": { exact requested products[product_id] }
}
```

The product retains its documented `variants["{language}:{finish}"].grades[]`. The app selects language, full printing, grader and full grade string exactly. There is no RAW/Near Mint substitution for a slab, numeric collapse of `10 Pristine`/`10 Black Label`, or condition-discount calculation. Only documented fields are forwarded. Missing values, returned zeroes, provider dates and sparse daily series are preserved. Unknown history dates are not filled with zero sales.

The upstream endpoint is fixed to `https://beta.tcgtracking.com/v1/{category}/sets/{group}/research`, authenticated with server-only `X-Shipper-Id` and `X-Api-Key`. The app's bearer token is never sent upstream. Redirects are rejected. Each set is cached for one hour with conditional HTTP ETag revalidation; the metadata's data hash is not substituted for the HTTP ETag. Research and Opportunities together retain at most four set bodies and four concurrent different-shard loads. A response is limited to 8 MiB and a request to 15 seconds. A phone refresh does not bypass the provider's hourly cadence. Expired data is not silently returned as a successful refresh when the provider fails; Retry-After/cooldowns prevent repeated upstream hits.

Research is documented by the provider as **in testing**. `guide_value` is a blended estimate; `market_value` is a separate provider field. `pop` is a grading-company population count. `sales` is historical sales count. `daily_history.stats.month` is the documented 30-day count/average, and daily series are aggregates rather than individual transactions. These metrics can inform demand; the server does not invent a demand score, sell-through rate, buyer count or certainty of authenticity. Saved inventory prices and offer snapshots are outside this read-only API.

### Opportunities / market insights

`GET /api/v1/opportunities/{category}/{group}/{product}` accepts the same exact supported catalog IDs as Research. It uses the fixed upstream URL `https://beta.tcgtracking.com/v1/{category}/sets/{group}` with the same server-only Beta headers and returns:

```text
{
  "meta": { documented OppsV2 set metadata },
  "product": { exact requested products[product_id], including skus[sku_id] }
}
```

This route can work independently of Research coverage. A Research denial, failure cooldown, cached body or ETag cannot stand in for its Opportunities equivalent. The adapters use separate prefixed shard identities while sharing the service's global rate, cache-size and pending-request limits. Opportunities uses the same one-hour TTL, HTTP ETag/304 revalidation, time/body limits, redirect rejection and Retry-After behavior. The request cannot supply an upstream URL or override the provider cadence.

Each SKU retains its exact `condition_id`, full condition, language and finish, along with documented timestamps, pricing, opportunity comparisons, marketplace listings and trends. SKU dictionaries are limited to 512 rows per product, each marketplace listing array to 20 rows, weekly quantity arrays to 52 elements, and trend windows to the documented `30d`, `90d` and `365d` keys. Oversized arrays are rejected; data is not silently truncated. Missing fields, explicit nulls, zeroes and false values remain distinct. The documented nullable `sku_id` is preserved, with the numeric dictionary key identifying that row. Non-null SKU IDs must equal their dictionary key; a returned product ID must equal its dictionary key.

`pricing.avg_30d` may be a sold average **or a market-average fallback**, so it must not be presented as a guaranteed sold average. Explicitly named `trends.windows[window].tcg_sold_avg` and `tcg_sold_avg_with_sh` are separate from `tcg_market_avg`; `tcg_qty`, `mp_qty` and `combined_qty` retain their provider windows and timestamps. Listings and quantities are provider observations, and an absent product/SKU does not establish zero sales or stock.

Only documented field names are forwarded. Optional navigation links are restricted to HTTPS TCGplayer/Manapool destinations; catalog/image links additionally require the documented provider host and matching catalog/product path. Unknown or unsafe links are omitted. The provider's `chart_buckets_90d` object has no documented child-field contract, so non-null chart objects are omitted; the documented explicit trend windows and weekly arrays are available. Arbitrary nested fields, tokens and upstream error bodies are never forwarded.

### PSA certificate bridge

`GET /api/v1/psa/cert/{certificateNumber}` accepts a 6–12 digit **string**, preserving leading zeros. Without a configured authorized adapter it returns HTTP 501 `psa_not_configured`; the app can fall back to explicit manual catalog/grade selection.

To enable an existing authorized certification service, configure:

```dotenv
PSA_CERT_SERVICE_URL_TEMPLATE=https://your-trusted-cert-service.example/certs/{certificateNumber}
PSA_CERT_SERVICE_TOKEN=
```

The optional bridge token is sent as Authorization Bearer to that service only. The URL must be HTTPS, contain exactly one placeholder in its path, and have no URL credentials, query or fragment. Do not point it back to this same `/api/v1/psa/cert` route. Redirects and changed response URLs are rejected; responses are limited to 256 KiB and requests to 12 seconds. No TCGTracking headers are sent to the certificate service.

The operator's authorized adapter must return this **normalized contract**, not an unmodified proprietary provider response:

```text
{
  "certificateNumber": "exact requested string",
  "grader": "PSA",
  "grade": "complete returned card grade string",
  "name": "card name",
  "source": "name of the authorized metadata provider",
  "year": "optional string",
  "set": "optional string",
  "number": "optional string",
  "language": "optional string",
  "printing": "optional string",
  "imageURL": "optional HTTPS image URL",
  "qualifiers": ["optional complete qualifier strings"],
  "autographGrade": "optional separate autograph grade string"
}
```

The cert must match the exact requested string; the grader must be PSA. A legacy qualifier string is preserved as a single array element, not split or numerically interpreted. Unknown extra fields, catalog IDs and prices are not forwarded. The adapter must implement your provider's documented authorization and response mapping. This package has not verified a particular official PSA API contract or license.

The phone confirms the returned metadata and then lets the user select the correct catalog card, printing/language and research grade. A barcode alone does not establish a card's product ID, grade, value or physical authenticity. PSA metadata does not automatically add inventory or replace an ungraded market quote.

## Error and deployment checks

Error responses contain only `{ "error": { "code": "...", "message": "..." } }`, with safe messages. Device authentication failure is 401 `unauthorized`. Set coverage missing is 404 `not_covered`; a missing product is 404 `product_not_covered`. Upstream credential/IP/license rejection is 502 `research_access_denied`, distinct from app authentication. Other provider/network/schema/size failures return a safe 5xx error. Own rate limits return 429 with Retry-After. A configured certificate service's missing certificate is 404 `certificate_not_found`; denied provider access is 502 `psa_access_denied`. Provider error bodies, keys and IP diagnostics are never returned to the phone.

For Opportunities, missing credentials return 503 `opportunities_not_configured`, upstream credential/IP/access rejection returns 502 `opportunities_access_denied`, and upstream 429/503 returns 503 `opportunities_temporarily_unavailable` with bounded Retry-After. Other transport/provider failures use `opportunities_unavailable`; malformed identity/schema uses `upstream_invalid_response`. Set/product coverage errors use the common 404 codes above. None of these failures is replaced with a successful Research response.

Before enabling the app on a real server, verify your HTTPS certificate, the authenticated health check, one known covered product/variant/grade, a missing product, an unavailable/missing value, and a real authorized PSA certificate if you configure the bridge. Confirm actual returned IDs, population/sales windows and timestamps. This repository supplies the package and mocked tests; it does not deploy or claim live account/API validation.
