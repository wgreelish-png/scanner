# Research, sales activity and PSA slabs

Build 17 adds a read-only Research screen and a separate **Research a PSA Slab** flow on Home. Ordinary card recognition, list identity, scan order, offers, selectable market-price sources and personal signing retain their existing paths. Research does not add a slab to inventory or replace an ungraded card's market price with a graded guide estimate.

## Connect your server

The Research API requires a BetaSupporter account with Research access and an IP-allowlisted server. The supplied [Node.js 22 service](../server/research/README.md) keeps its upstream keys on that server. Deploy it behind your HTTPS reverse proxy and enter the HTTPS **origin** and a separate generated device token in Settings → Research & demand → Research Connection. The app stores that pair in device-only Keychain storage. Changing the loaded server address clears the old token; forgetting the connection removes it.

**Test Connection** checks authenticated access to your server and reports which adapters are configured. A configured flag is not proof of working upstream credentials, subscription access, an IP allowlist or product coverage. A real product lookup must verify those separately. No Beta or PSA API key belongs in the app or chat. The server package is prepared for Node.js; a deployed address, the user's actual runtime and a verified certification provider are still needed for deployment acceptance.

## Research for a catalog card

Open a saved list, edit a card and choose **Research**. The app resolves the catalog product's set ID and requests that exact product from the server. Language/full printing and grader/full grade are separate selectors; selecting PSA never silently substitutes RAW or a different grade. An unavailable combination stays unavailable. A later response cannot replace a newer card selection.

The screen reports returned data rather than deriving a demand score:

- Historical sales, the documented 30-day sales count/average/low/high, and last sale/date.
- Grading-company population and the provider's confidence level, when available.
- Separately labeled guide estimate and market value, with provider timestamps and the API's **in testing** status.
- An interactive chart of returned daily sales counts and sold-price averages. These are daily aggregates; gaps are not filled with invented zero sales, and the line does not bridge missing days.

Missing prices and counts differ from returned zeroes. A guide estimate is not an actual sale. Population is not the total surviving supply, historical sales are not active demand, and confidence is not an authenticity guarantee. Research does not have condition-specific RAW pricing semantics. Saved prices, quantities, transaction labels and offer snapshots are not changed by browsing it.

The server caches set-level Research for one hour and then revalidates with the HTTP ETag. Refresh retries the connection but does not bypass that cadence. Coverage and freshness depend on the upstream Research dataset, not the downloaded recognition database.

## Research a PSA slab

1. On Home, choose **Research a PSA Slab**. Scan a supported PSA QR/Code 128 label or type the certification number. The camera holds the first valid candidate until **Use This Certification**; it does not automatically look up every frame. Typed entry remains available when camera permission is denied or no camera is available.
2. If configured, your server asks your authorized certification adapter for the card's metadata. The app preserves the complete card grade and qualifiers; a separate autograph grade stays separate. Changing the typed certificate clears the old record and grade.
3. Confirm the card by searching the selected game's downloaded catalog. Five live artwork previews narrow as you type the name, set or collector number. Confirm the exact catalog card, printing and language before opening its Research screen.
4. Select a returned PSA grade if the certificate lookup was unavailable. There is no assumed PSA 10 result and no automatic RAW substitution.

The Research API does **not** resolve certificate numbers. The server's optional PSA route is a bridge to an **authorized normalized certification service**, not a verified implementation of a particular official PSA endpoint. Its deployment instructions define the response that such an adapter must supply. If no adapter is configured, the app explains this and offers manual catalog/grade selection.

Code 128/typed entry accepts a 6–12 digit candidate, retaining leading zeroes. QR support currently accepts an HTTPS `psacard.com` or `www.psacard.com` URL with the exact path `/cert/{digits}` and optional trailing slash; other QR shapes require typed entry until verified. Reading a barcode or finding a certificate record does not authenticate a physical slab. Real label formats, optical readability and authorized metadata coverage still need iPhone acceptance.

The PSA camera is a separate Home flow. It pauses on backgrounding and requires an explicit resume. It does not run concurrently with the live card scanner. No mock capture is used as a fallback.

## Validation status

The branch includes native fixtures for Research identity, exact variant/grade selection, missing/zero values, sparse history, stale replies, certificate validation, Keychain connection storage and safe HTTP transport. Two UI checks cover connection validation and reaching typed certificate/catalog fallback without opening the camera. The backend has synthetic mocked contract tests for authentication, bounds, caching, errors and the optional certification bridge. Fixture success does not prove live account access, a real sale or a physical PSA label scan.

The new Swift files belong to the app target, native tests to the native test target and UI tests to the UI test target. CI keeps native tests, the complete UI suite and the unsigned Personal Release compile separate; a dedicated Research UI job also runs the new screens independently. The earlier pricing-base UI run failed the swipe-delete case and timed out, while its native tests and Release compile passed; this feature does not claim to resolve or bypass that existing UI failure.

Local checks passed: all 39 app, 25 native-test and 5 UI-test source memberships; 47 pinned runtime assets and dependency closure; grammar parsing of all 69 Swift files; 30 backend contract tests; and 27 Python helper tests. These Linux checks do not compile or run Swift. Xcode compilation/native execution and simulator UI results must be recorded from macOS CI after these changes. Neither the new backend's live Research/PSA access nor physical-iPhone behavior has been verified yet.

For acceptance, keep the existing app data installed and check: one covered catalog product with known language/printing/grade; a missing combination and returned zero; account/IP rejection and retry; server-token change/forget; a real PSA QR and Code 128 label; typed leading-zero certificate; unavailable certification service and manual fallback; changing a certificate during a slow request; grade qualifiers/autographs; background/resume and camera denial; return to existing lists with original prices/offers unchanged. Record the build, device/iOS, selected product/variant/grade and server/provider timestamps without exporting tokens.
