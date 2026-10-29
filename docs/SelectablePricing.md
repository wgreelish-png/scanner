# Selectable market pricing — build 16

Choose **Price source** in Settings → Market pricing, scanner Options, the frozen scan review, Edit Card or manual-card confirmation. **Existing TCGTracking** remains the default and uses the existing website connection. **Open API** requests public condition-level SKU prices directly without website sign-in. The selection persists across launches and applies to subsequent lookups throughout the app. A failed lookup never silently changes providers.

Switching during review preserves the card, printing and condition, clears the previous quote/SKU and refreshes the draft. Canceled or late responses cannot overwrite the current selection. A queued confirmation is canceled when the source changes. Existing saved rows and offer snapshots remain unchanged; saving an edited draft explicitly updates that row. Recognition and the weekly recognition-database schedule are independent of the price source.

## Exact returned quotes

Open API uses `/v1/{category}/sets/{set}/skus`, matching the product ID, full printing name, language and condition. Only `mkt` supplies market value. Missing/null market values remain **Price unavailable**, while a returned zero remains **$0.00**. Listing lows, aggregate product prices and condition discounts are never substitutes. An ambiguous SKU match remains unavailable. Returned printing names populate the dropdowns, including other frozen candidates where available.

The public provider currently supports TCGplayer `p:` products for Pokémon, Magic and Yu-Gi-Oh! A published native V2 recognition database supplies the exact product-to-set mapping. Legacy/missing/inconsistent metadata produces an explicit unavailable message; refresh the recognition database or choose Existing TCGTracking. The app does not infer a set ID from a card name.

Source and provider update time accompany returned prices. Metadata persists with confirmed cards and survives reopening; manually overriding the market price or SKU clears its provider attribution. Older saved data without metadata still decodes normally. No SwiftData schema or signing changes are required.

## Freshness and request behavior

The public docs describe daily SKU updates. The displayed data update timestamp is the provider's timestamp, not a new sale or a claim of live transaction data. Up to four set responses are retained in memory for 15 minutes. **Retry Market Price** forces revalidation, using ETag when available. Expired data is never used as an offline fallback. Condition changes reuse an already-fetched set response, selecting the exact condition SKU locally. Requests for the same set share a pending ordinary lookup; forced requests supersede older responses.

Public requests use a separate credential-free URLSession with bounded response sizes, timeouts and redirects disabled. Existing website cookies and sign-in remain isolated to Existing TCGTracking.

## Validation and phone acceptance

Local JavaScript tests (119), Python tests (27), Swift grammar, target membership and all 47 pinned runtime assets pass. Native and UI execution is tracked in the branch's macOS CI. Live Open API response verification is blocked by this running cloud workspace's network policy; the hostname is already in its saved configuration draft. Fixture tests are not evidence that real endpoint coverage or iPhone prices work.

On the installed iPhone:

1. Leave Existing TCGTracking selected and scan a known card. Change condition and printing, confirm the correct price/SKU, save and reopen it.
2. Choose Open API and repeat on the same product/printing/language/condition. Compare the actual returned SKU and market value; allow for daily source freshness differences. Confirm the source and update timestamp appear.
3. Check an unavailable condition and a genuinely returned zero quote. Neither may inherit another condition's price. Missing data must not trigger website sign-in or silently switch sources.
4. Switch sources during a slow lookup and change condition quickly. The newest selection must win. Switch back to Existing TCGTracking and verify its normal connection and retry behavior.
5. Repeat in Edit Card and Search & Add Card. Cancel an edit and verify the saved row is unchanged; save and reopen another. Confirm list identity, scan order, duplicate rows, existing offers and CSV export remain intact.
6. Relaunch and verify the source preference persists. Confirm the recognition database still reopens from its saved files and follows its separate weekly/manual refresh schedule.

Physical camera recognition, provider payload/coverage and end-to-end iPhone behavior remain unverified by this change until those device checks pass.
