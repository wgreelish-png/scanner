# TCGTracking Research diagnostics in Postman

These three read-only requests reproduce the app's Direct Research path and the public set-list check. They do not scan cards, alter inventory, change prices, or resolve PSA certificate numbers.

## Import and run

1. In the Postman desktop app, choose **Import** and select both JSON files in this directory:
   - `TCGTracking-Research.postman_collection.json`
   - `TCGTracking-Local.postman_environment.json`
2. Select **TCGTracking Research - Local Credentials** as the active environment.
3. Enter your credentials as **local values** for `tcgt_shipper_id` and `tcgt_beta_key`. If your version has Initial and Current columns, use Current. The supplied environment contains no credentials.
4. Use a network whose public outbound IP is on the provider's allowlist. Use the desktop app or Desktop Agent; the Cloud Agent uses a different outbound IP.
5. Choose **Run collection**, leave all three requests selected in order, and run **one iteration**.
6. Open the collection's **Variables** tab and copy the generated `tcgt_research_summary` value. It is also printed in the Postman Console. You can share that summary without sharing your request headers or populated credential environment.

To see a formatted summary, send request **03** individually after a successful request **01**, then open **Visualize** in its response pane. Running request 01 again clears the previous derived set and result before discovery.

## What is automatic

The default target is **Charmander, SV: Scarlet & Violet Promo Cards, 044**, catalog product **512035**, **EN:Holofoil**, **PSA 9**. The set ID is not hard-coded: request 01 discovers it by exact set name from `/v1/research/meta`. The user's supplied index resolved it to **22872**, with **one product** and **25 grade records**. Those totals do not establish coverage for this particular card.

1. **Research index and automatic set discovery** tests authenticated Research access, finds the exact set, and stores its group ID and coverage counts. A failed/ambiguous discovery stops the collection run.
2. **Public Pokemon set list** downloads the independent public catalog list without Beta credentials. A public catalog entry does not establish Research coverage. Its response is retained for comparison; its undocumented wrapper is not guessed.
3. **Exact card, printing and grade Research** requests that set and verifies metadata identity, numeric product key and product ID, exact language/printing, and a unique exact grader/grade row. It shows the returned product sample, available variants and grades, and the selected grade's population/sales/valuation/history statistics when available. Nulls and zeroes remain distinct.

No HTTP ETag condition is sent, so these diagnostic requests obtain a response body rather than an HTTP 304. This does not force the provider to regenerate its hourly dataset. Redirect following is disabled. Beta credentials are added only for the fixed Research endpoints, and never to the public set list. The scripts never log credentials or request headers.

## Test another card

Edit these **collection variables**, then run all three requests again:

| Variable | Default | Meaning |
| --- | --- | --- |
| `tcgt_category_id` | `3` | Pokémon category ID |
| `tcgt_set_name` | `SV: Scarlet & Violet Promo Cards` | Exact set name in the Research index |
| `tcgt_card_name` | `Charmander` | Label in the diagnostic summary |
| `tcgt_product_id` | `512035` | Numeric TCGplayer product ID; omit `p:` |
| `tcgt_language` | `EN` | Exact returned language code |
| `tcgt_printing` | `Holofoil` | Exact full returned printing |
| `tcgt_grader` | `PSA` | Exact grading company |
| `tcgt_grade` | `9` | Exact grade text, including qualifiers if applicable |

Derived variables named `tcgt_resolved_*`, `tcgt_index_*`, `tcgt_public_sets_status` and `tcgt_research_summary` are managed by the scripts. Credentials are read from the active environment, not from collection variables.

## Interpret the results

- **HTTP 401/403**: inspect credentials, Research entitlement and the caller's public IP allowlist. The response body in Postman may give the provider's exact reason.
- **HTTP 200 + `product_missing`**: the set responded, but the requested numeric product key is absent. Check provider coverage and the selected set; this result alone does not establish why that product is missing.
- **`unexpected_product_keys`, `identity_mismatch`, `invalid_response`, `invalid_product` or `invalid_variant`**: the returned identity or shape differs from the documented contract. Preserve the response for investigation.
- **`variant_missing`, `grade_missing` or `grade_ambiguous`**: no unique exact selection is available. Another printing, grade or RAW is never substituted.
- **`available`**: the exact row exists. Individual valuations or statistics can still be null.

Coverage failures intentionally appear as failed Postman tests even when the HTTP test passes. Check the generated summary to distinguish coverage from connection failure.

## Local validation

Run `node --test postman/test_research_collection.mjs` from the repository root. The tests execute the actual collection scripts with mocked Postman APIs and provider fixtures, including the structure/counts in the supplied Research index. They cover automatic discovery, missing/malformed responses, credentials and fixed origins, stale-result clearing, exact product/variant/grade matching, duplicate grade rows, and null/zero values.

Fixture checks do not establish live API coverage or execution in the Postman desktop app. No app build or signing changes are included.

## Public price and Opportunities diagnostics

Import the separate `TCGTracking-Market.postman_collection.json` and reuse the same **TCGTracking Research - Local Credentials** environment above. Choose **Run collection**, keep its three requests selected in order, and run one iteration:

1. **Public exact SKU price and listing context** calls the credential-free `/v1/{category}/sets/{group}/skus` endpoint first. It selects one exact language, full printing and condition SKU and retains its market/low/high/listing-count context.
2. **Beta opportunities index** calls `/v1/meta`. It reports coverage and a unique exact-set-name hint when present. It never changes the requested group or stops the remaining requests.
3. **Beta exact SKU pricing, listings and sales windows** calls `/v1/{category}/sets/{group}` and selects the same public SKU plus its full variant. If public coverage is missing, it requires one unique exact variant. Open this response's **Visualize** tab, or copy the `tcgt_market_summary` collection variable to share the combined result.

The default target is Charmander SV Promo 044, product **512035**, category **3**, known group **22872**, **EN / Holofoil / Near Mint**. The group came from the supplied Research index; it does not establish public SKU or Opportunities coverage for this product. A real run may report `product_missing` or `sku_missing`. These statuses preserve HTTP success separately and do not imply zero sales or stock. Research is not requested or required by this collection. Public pricing remains in the summary when Beta authentication, subscription/IP access or coverage fails. Without valid local Beta credentials, requests 02/03 are sent without private headers so request 03 can still display its response summary.

Edit these **collection variables** to test another exact card:

| Variable | Default |
| --- | --- |
| `tcgt_market_category_id` | `3` |
| `tcgt_market_group_id` | `22872` |
| `tcgt_market_product_id` | `512035` |
| `tcgt_market_card_name` | `Charmander` (display label) |
| `tcgt_market_set_name` | `SV: Scarlet & Violet Promo Cards` (exact index hint) |
| `tcgt_market_language` | `EN` (the script matches Beta's full `English` value) |
| `tcgt_market_printing` | `Holofoil` (full returned printing) |
| `tcgt_market_condition` | `NM` (`NM`, `LP`, `MP`, `HP`, `DMG` or `Unopened`) |

Group selection is explicit: change it yourself and rerun all three requests if the index suggests another set. A changed target clears the prior comparison, and request 01 clears all prior derived results. Another SKU, language, printing or condition is never substituted. The public schema identifies the set with `set_id`; category identity is bound to the fixed request path and checked when returned. Beta responses additionally require matching metadata category/group and exact numeric product ID.

The summary preserves zero/null/missing values, explicit `trends.windows.*.tcg_sold_avg` and `tcg_sold_avg_with_sh`, marketplace listing totals/shipping, quantities and provider timestamps. **`pricing.avg_30d` is not a guaranteed sold average**: it may fall back to market average. Only allowlisted fields enter the summary; raw provider errors, private headers and credentials are excluded. Redirect following is disabled and Beta headers are added only to fixed Beta endpoints. No ETag is sent, which obtains a response body without forcing a newer provider dataset.

Run `node --test postman/test_market_collection.mjs` for synthetic checks of the actual collection scripts. These checks make no network requests and do not establish live account access or desktop Postman execution. The existing Research collection and its tests are independent.
