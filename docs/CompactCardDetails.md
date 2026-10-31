# Compact card details

> [Build 27](StandardMarketPricing.md) subsequently standardizes all market quotes on Open API; the source-setting references below describe build 26.

Build 26 replaces the long saved-card edit form with a compact Card Details screen. It retains the indigo accents and the existing list sheet, explicit Save/Cancel actions, row identity, scan order, quantities, offer overrides and storage schema.

The first section shows a card thumbnail, name, set, number and game. Tapping the thumbnail opens larger artwork. The market section presents the per-card value, refresh control and NM/LP/MP/HP/DMG buttons. Cached/offline status and the original provider update date are compact; if no update date was returned, the display says Checked instead. Known zero remains $0.00 and missing quotes remain unavailable. Printing and language use menus, and quantity stays directly editable. Larger accessibility text rearranges the header and condition buttons.

Product IDs, SKU IDs, image URLs and the pricing-provider picker are removed from the card form. The existing provider selected in Settings continues to handle quotes; this change does not switch providers or rewrite saved quotes. Manual market-price adjustment and per-card cash/trade/maximum overrides remain in collapsed controls. Existing overrides show an Applied label without requiring expansion. Lookup errors and sign-in actions appear only when relevant.

Find Correct Card uses the existing cached catalog search. Selecting a result replaces the draft's catalog identity and artwork, retains condition/language, retains printing when the new catalog card supports it, and obtains an exact quote. The old price, SKU and metadata are cleared immediately and late responses cannot replace the corrected selection. The same inventory row is edited only after Save; quantity and offer overrides remain in their draft controls. Cancel leaves the saved row untouched. A correction never merges rows or moves the edited card in scan order.

The existing Market Details and Graded Research destinations remain compact links. New charts, history endpoints, a combined research page, Open API-only pricing and Card Show inventory synchronization are outside this screen change. Chart enhancements are deferred until the Beta APIs are fully released.

## Validation

All screen, model, documentation and build-version changes are completed before running checks. Existing native editor tests cover exact-condition/SKU selection, missing and zero quotes, stale replies, cancellation and save isolation. Two additional cases cover catalog correction, unsupported printing replacement, late previous-card responses, preserved quantities/offers/list identity/order, and keeping separate rows when corrected matches become equal. No new UI-test job is introduced.

Physical-iPhone acceptance remains necessary: open an existing card, inspect the thumbnail and required fields, enlarge the image, select every condition and a printing/language, try a manual value and offer override, cancel/reopen, then explicitly save and confirm persistence. Correct a catalog match and check image/identity/price update together while the row remains in place. Check small screens, large text and failed price lookups. Only the previously selected provider should make quote requests. Native and device execution must be reported separately from grammar/resource checks.
