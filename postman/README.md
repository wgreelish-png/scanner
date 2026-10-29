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
