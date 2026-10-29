# Research, sales activity and PSA slabs

Build 17 adds a read-only Research screen and a separate **Research a PSA Slab** flow on Home. Ordinary card recognition, list identity, scan order, offers, selectable market-price sources and personal signing retain their existing paths. Research does not add a slab to inventory or replace an ungraded card's market price with a graded guide estimate.

## Choose how Research connects

Settings → Research & demand → Research Connection offers **Direct TCGTracking** and **My Server**. This is separate from the existing market-price source picker. Both Research methods require the provider's BetaSupporter Research access and IP allowlist; neither silently switches to the other after a failure. New installations default to Direct TCGTracking; an existing server-only configuration keeps My Server until you choose otherwise.

**Direct TCGTracking** lets you enter your shipper ID and API key in the app and save them in device-only Keychain storage. Requests go to the fixed HTTPS Beta Research API with `X-Shipper-Id` and `X-Api-Key`; the key is not embedded in source code, URLs, defaults or diagnostics. The provider must allowlist the phone's current **public outbound IP**. Switching between Wi-Fi and cellular, a VPN or a changed network address can break access until that address is allowed. This mode needs no Node service for Research. Test Connection requests the fixed `/v1/research/meta` endpoint to check reachability/authentication. It does not establish coverage for a particular product/variant/grade, which needs a real lookup.

**My Server** uses the supplied [Node.js 22 service](../server/research/README.md) to keep upstream keys on your server. Deploy it behind your HTTPS reverse proxy and enter its HTTPS **origin** and separate generated device token. The app stores that pair in device-only Keychain storage. Changing the loaded server address clears the old token; forgetting the connection removes it. The server's fixed public IP is the allowlisted upstream caller, which makes this method preferable when the phone changes networks. Its connection check reports configured adapters, not verified upstream credentials, subscription access, IP authorization or product coverage.

Use only the credential fields for the selected method: direct mode takes Beta credentials, while My Server takes a separate device token. PSA provider credentials still belong in your authorized server adapter. Do not share any keys or tokens in chat. Live direct requests and server deployment have not been verified with the user's account; the server's actual runtime/address and an authorized certification provider remain deployment details to supply.

## Research for a catalog card

Open a saved list, edit a card and choose **Research**. The app resolves the catalog product's set ID and requests that exact product through the selected access method. Language/full printing and grader/full grade are separate selectors; selecting PSA never silently substitutes RAW or a different grade. An unavailable combination stays unavailable. A later response cannot replace a newer card selection.

The screen reports returned data rather than deriving a demand score:

- Historical sales, the documented 30-day sales count/average/low/high, and last sale/date.
- Grading-company population and the provider's confidence level, when available.
- Separately labeled guide estimate and market value, with provider timestamps and the API's **in testing** status.
- An interactive chart of returned daily sales counts and sold-price averages. These are daily aggregates; gaps are not filled with invented zero sales, and the line does not bridge missing days.

Missing prices and counts differ from returned zeroes. A guide estimate is not an actual sale. Population is not the total surviving supply, historical sales are not active demand, and confidence is not an authenticity guarantee. Research does not have condition-specific RAW pricing semantics. Saved prices, quantities, transaction labels and offer snapshots are not changed by browsing it.

Both methods cache set-level Research for one hour and then revalidate with the HTTP ETag. Refresh does not bypass a fresh one-hour cache, and expired data is not silently returned as a successful refresh after provider failure. The direct client retains at most four set responses in memory, separated by credentials and set identity; it does not add a persistent offline Research database. Coverage and freshness depend on the upstream Research dataset, not the downloaded recognition database. Internet access is required for Research; this does not add offline market pricing.

## Research a PSA slab

1. On Home, choose **Research a PSA Slab**. Scan a supported PSA QR/Code 128 label or type the certification number. The camera holds the first valid candidate until **Use This Certification**; it does not automatically look up every frame. Typed entry remains available when camera permission is denied or no camera is available.
2. If a My Server connection and authorized certification adapter are saved, they can return the card's metadata independently of the selected Research access method. The app preserves the complete card grade and qualifiers; a separate autograph grade stays separate. Changing the typed certificate clears the old record and grade. Without that server adapter, use manual catalog search.
3. Confirm the card by searching the selected game's downloaded catalog. Five live artwork previews narrow as you type the name, set or collector number. Confirm the exact catalog card, printing and language before opening its Research screen.
4. Select a returned PSA grade if the certificate lookup was unavailable. There is no assumed PSA 10 result and no automatic RAW substitution.

The Research API does **not** resolve certificate numbers. The server's optional PSA route is a bridge to an **authorized normalized certification service**, not a verified implementation of a particular official PSA endpoint. Its deployment instructions define the response that such an adapter must supply. Direct Research does not resolve certificates. A retained My Server connection can still provide certification metadata while Research uses Direct TCGTracking. If no authorized adapter is configured, the app explains this and offers manual catalog/grade selection; Research for that confirmed match uses your selected access method.

Code 128/typed entry accepts a 6–12 digit candidate, retaining leading zeroes. QR support currently accepts an HTTPS `psacard.com` or `www.psacard.com` URL with the exact path `/cert/{digits}` and optional trailing slash; other QR shapes require typed entry until verified. Reading a barcode or finding a certificate record does not authenticate a physical slab. Real label formats, optical readability and authorized metadata coverage still need iPhone acceptance.

The PSA camera is a separate Home flow. It pauses on backgrounding and requires an explicit resume. It does not run concurrently with the live card scanner. No mock capture is used as a fallback.

## Validation status

The branch includes native fixtures for Research identity, exact variant/grade selection, missing/zero values, sparse history, stale replies, certificate validation, Keychain connection storage and safe HTTP transport. Direct-mode fixtures additionally exercise fixed-host authentication and set/product response handling. UI checks cover connection validation and reaching typed certificate/catalog fallback without opening the camera. The backend has synthetic mocked contract tests for authentication, bounds, caching, errors and the optional certification bridge. Fixture success does not prove live account access, a real sale or a physical PSA label scan.

The new Swift files belong to the app target, native tests to the native test target and UI tests to the UI test target. CI keeps native tests, the complete UI suite and the unsigned Personal Release compile separate; a dedicated Research UI job also runs the new screens independently. The earlier pricing-base UI run failed the swipe-delete case and timed out, while its native tests and Release compile passed; this feature does not claim to resolve or bypass that existing UI failure.

Local checks passed all 40 app, 26 native-test and 5 UI-test source memberships; 47 pinned runtime assets and dependency closure; grammar parsing of all 71 Swift files; 30 backend contract tests; and 27 Python helper tests. Eleven additional direct-client native tests are supplied but have not run on Linux. Linux checks do not compile or run Swift. Xcode compilation/native execution and simulator UI results must be recorded from macOS CI after these changes. Live direct or server Research/PSA access and physical-iPhone behavior remain unverified.

For acceptance, keep the existing app data installed and check: one covered catalog product with known language/printing/grade through each configured method; a missing combination and returned zero; account/IP rejection and retry; direct credential save/forget and Wi-Fi/cellular changes; server-token change/forget; switching methods while a request is pending; a real PSA QR and Code 128 label; typed leading-zero certificate; retained server certification lookup while Research uses direct mode, unavailable certification service and manual fallback; changing a certificate during a slow request; grade qualifiers/autographs; background/resume and camera denial; return to existing lists with original prices/offers unchanged. Record the build, device/iOS, selected product/variant/grade and server/provider timestamps without exporting keys or tokens.
