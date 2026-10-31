# Simpler list review and PokéDen app icon

Build 30 keeps the existing saved-list, session and pricing behavior while reducing the controls visible in list review.

- The top-right **•••** menu contains **Export CSV to Files**, **Share CSV** and, for a scan session, **Offer Percentages**. Export still includes the entire list in persisted scan/import order with original quantities. Search/sorting do not restrict it.
- **Record Transaction** and **Nothing Happened** now belong to the offer tile, with the recorded outcome/status retained. Lists without a scan session show the same controls with their summary. An explicit budget receipt remains a separate financial action.
- Live **Custom cash offer** and **Save Offer Estimate** controls are removed. Cash/trade math uses saved session percentages and per-card overrides. Historical saved estimates and their original valuation inputs remain preserved, with history available through the options menu only when prior estimates exist.
- Card rows include artwork thumbnails and an offline placeholder. Tapping a card retains the compact card details flow; imported inventory stays read-only and has an editable-copy action.
- Numeric keyboard **Done** buttons reserve their full label width in offer, card-edit and budget views.
- Both Market and Graded Research include **View Card on TCGplayer** for the exact catalog product page. The link requires no additional API call and opens listings/history in the browser. Returned activity does not include a verified lowest-listing URL, so no seller link is invented. Select condition/printing on TCGplayer as appropriate; a raw product page does not imply graded or condition-specific history.
- Budgets have optional start/end **Show dates** in New/Edit Show and on the dashboard. Existing undated shows remain undated, and existing transactions, recorded timestamps and gross 65/35 split are preserved.

The supplied PokéDen Collectibles artwork is packaged as an opaque 1024×1024 AppIcon in the application asset catalog. Debug and Release use that same icon; the bundle identifier and personal signing configuration are unchanged. iOS applies its normal icon mask. Installing the new build updates the Home Screen icon without deleting the app or its saved data.

Implementation completes before checks run. Focused native cases cover valid marketplace URLs and backward-compatible date storage/range validation; UI cases cover the menu exports, compact offer controls, Done sizing and show dates. Linux asset/grammar/membership checks cannot establish Xcode compilation or physical-iPhone layout. On the phone, verify the icon after installing, export via •••, adjust percentages and check payouts, record both outcome actions, type My Card Price and tap Done, browse card thumbnails, open TCGplayer from each research mode and save/reopen show dates.

Post-implementation local checks passed all 27 Python helpers, grammar parsing of 126 Swift files, source/resource membership for 72 app/44 native-test/10 UI-test files, 47 pinned recognition assets, the opaque 1024×1024 RGB icon metadata, shell syntax and whitespace checks. The existing CI jobs include the new native/link/date cases and UI fixture; Xcode/native/UI execution and physical-device layout remain unverified until their results are available.
