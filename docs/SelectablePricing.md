# Selectable market pricing — build 16

Build 21 extends this existing selector with exact-SKU listing context, bounded offline price reuse and verified product-ID set recovery. [Market Details and OppsV2](MarketData.md) documents the supplemental read-only screen and independent API access checks.

Choose **Price source** in Settings → Market pricing, scanner Options, the frozen scan review, Edit Card or manual-card confirmation. **Existing TCGTracking** remains the default and uses the existing website connection. **Open API** requests public condition-level SKU prices directly without website sign-in. The selection persists across launches and applies to subsequent lookups throughout the app. A failed lookup never silently changes providers.

Switching during review preserves the card, printing and condition, clears the previous quote/SKU and refreshes the draft. Canceled or late responses cannot overwrite the current selection. A queued confirmation is canceled when the source changes. Existing saved rows and offer snapshots remain unchanged; saving an edited draft explicitly updates that row. Recognition and the weekly recognition-database schedule are independent of the price source.

## Exact returned quotes

Open API uses `/v1/{category}/sets/{set}/skus`, matching the product ID, full printing name, language and condition. Only `mkt` supplies market value. Missing/null market values remain **Price unavailable**, while a returned zero remains **$0.00**. Listing lows, aggregate product prices and condition discounts are never substitutes. An ambiguous SKU match remains unavailable. Returned printing names populate the dropdowns, including other frozen candidates where available.

The public provider currently supports TCGplayer `p:` products for Pokémon, Magic and Yu-Gi-Oh! A published native V2 recognition database supplies the preferred exact product-to-set mapping. If it cannot resolve a set, the verified public `/v1/products/{product}` response can supply the same exact product/category's set ID. Both failed lookups leave an explicit unavailable result; the app does not infer a set ID from a card name or replace the card's identity. Product-level aggregate prices are not used as condition-specific market prices.

Source and provider update time accompany returned prices. Metadata persists with confirmed cards and survives reopening; manually overriding the market price or SKU clears its provider attribution. Older saved data without metadata still decodes normally. No SwiftData schema or signing changes are required.

## Freshness and request behavior

The public docs describe daily SKU updates. The displayed data update timestamp is the provider's timestamp, not a new sale or a claim of live transaction data. Up to four set responses are reused for 24 hours in memory and across app launches on disk within a 32 MiB cap. Fresh disk data is labeled cached and requires no request; a manual refresh revalidates sooner. **Retry Market Price** forces revalidation, using ETag when available. On connectivity failures only, a previously validated exact-SKU body can supply a visibly cached/offline quote with its original dates. HTTP/authentication errors, malformed data and cancellations do not return cached prices. Condition changes reuse an already-fetched set response, selecting the exact condition SKU locally. Requests for the same set share a pending ordinary lookup; forced requests supersede older responses.

Public requests use a separate credential-free URLSession with bounded response sizes, timeouts and redirects disabled. Existing website cookies and sign-in remain isolated to Existing TCGTracking.

## Validation and phone acceptance

Local JavaScript tests (119), Python tests (27), Swift grammar, target membership and all 47 pinned runtime assets pass. Native and UI execution is tracked in the branch's macOS CI. A user-supplied successful Charmander product response is retained as a fixture for the verified metadata contract. This cloud runtime has not performed live provider queries; fixture tests do not establish live account coverage or end-to-end iPhone behavior.

On the installed iPhone:

1. Leave Existing TCGTracking selected and scan a known card. Change condition and printing, confirm the correct price/SKU, save and reopen it.
2. Choose Open API and repeat on the same product/printing/language/condition. Compare the actual returned SKU and market value; allow for daily source freshness differences. Confirm the source and update timestamp appear.
3. Check an unavailable condition and a genuinely returned zero quote. Neither may inherit another condition's price. Missing data must not trigger website sign-in or silently switch sources.
4. Switch sources during a slow lookup and change condition quickly. The newest selection must win. Switch back to Existing TCGTracking and verify its normal connection and retry behavior.
5. Repeat in Edit Card and Search & Add Card. Cancel an edit and verify the saved row is unchanged; save and reopen another. Confirm list identity, scan order, duplicate rows, existing offers and CSV export remain intact.
6. Relaunch and verify the source preference persists. Confirm the recognition database still reopens from its saved files and follows its separate weekly/manual refresh schedule.

Physical camera recognition, provider payload/coverage and end-to-end iPhone behavior remain unverified by this change until those device checks pass.
