# Build 109: count leftover stock

Open **Scan → Count Leftover Stock** or **Show → Count Leftover Stock** to count the cards physically left after a show. The mode compares that count with a complete, read-only download of the exact TCGTracking **Card Show** location. **Card Show Need To Price** is a different location and is excluded.

Starting a count freezes the downloaded location, timestamp, card identities and quantities as its baseline. Returning to the count or reopening the app resumes that baseline and the saved count lists; it does not fetch a newer baseline automatically. Starting over explicitly creates a new baseline. Keep the baseline until the comparison and export have been reviewed.

Choose a game and scan its remaining cards into a separate count list. Switching games preserves each game's count, and the comparison/export combines all linked lists. Identical physical copies contribute to the same exact card/SKU total. Use the source card's manual counted quantity when camera recognition is unavailable for that game, or to correct a total after checking the physical copies. Condition, printing and language identify different stock; verify them before accepting a match.

The comparison includes website cards not yet counted, reduced counts, extra counts and unchanged counts. A missing count means **Not counted**, not an inferred sale. Resolve invalid, missing or conflicting SKU identities and finish the complete physical count before marking it complete. Later count or identity edits require completion again. A missing saved list must be restored or its reference explicitly removed; it cannot silently become a zero count.

Counting and exporting create no sale, purchase, trade, cash, cost or profit entries. They do not change working show stock, the saved imported website inventory, or the website. Count lists and the frozen baseline remain independent of those records.

## CSV files

The replacement-stock CSV contains positive **final counted quantities**, aggregated by exact SKU, with this header:

```csv
tcgplayer_sku,name,set_name,collector_number,condition,foil,language,quantity,location
```

These aliases follow the website's own [API-import CSV generator](https://tcgtracking.com/dash/inventory/inventory-api-import.js), with its supported location field added. `tcgplayer_sku` is the exact positive numeric SKU; `foil` contains the complete printing/finish name, not a boolean. `location` is the location name **Card Show**, not its numeric ID. The file omits zero quantities, deltas and prices. Importing a price column can set a listing price, so saved market quotes are excluded.

Verify or set the website's column mappings explicitly:

| CSV column | Website field |
| --- | --- |
| `tcgplayer_sku` | TCGPlayer SKU |
| `name` | Card Name |
| `set_name` | Set |
| `collector_number` | Number |
| `condition` | Condition |
| `foil` | Variant/Finish |
| `language` | Language |
| `quantity` | Quantity |
| `location` | Location |

Do not map a product ID to TCGPlayer SKU. The separate comparison CSV includes previous quantity, counted quantity, signed delta and status, including website cards with zero counted copies. Keep it as the audit of the requested change; upload the replacement-stock CSV instead.

The public JavaScript header/mapping contract has been verified. Automatic format detection, backend SKU matching, zero-row handling and a complete CSV import round trip remain unverified. Review the actual website mappings and exact matched SKUs before changing website stock; these files do not guarantee importer success.

## Replace only Card Show on the website

Save both CSV files and verify every SKU, condition, printing, language and final quantity **before clearing anything**. Check the upload's column mappings and matched-card preview first. An unresolved or unexpected match must be corrected before continuing.

1. In TCGTracking, clear the stock from **only Card Show**, or delete and recreate that one location using the website's controls. Keep other locations intact. Deletion/clearing is a manual website action.
2. Reopen/reload the import if the location was recreated so the picker has its new ID. Upload the saved replacement-stock CSV and verify the mappings and matches again.
3. Select the current **Card Show** destination and override all row locations to that destination. An unrecognized CSV location can fall into Unassigned, so inspect the location preview.
4. Explicitly choose **Add**, even if the website selects another default. Review the impact summary: Card Show must start empty and the added quantity must equal the completed physical count. Confirm the import only after that review, then compare the resulting Card Show rows and quantities with the saved files.

The website's [Bulk Import code](https://tcgtracking.com/dash/inventory/inventory-bulk-import.js) says **Full Replace** erases all current inventory. It is account-wide and is unsafe for replacing only Card Show. Ordinary **Replace** leaves omitted SKUs untouched and can consolidate overlapping SKUs from multiple locations into the chosen destination. Neither mode performs this location-only reset. Clearing just Card Show, followed by **Add**, gives the intended final counts without relying on zero-row removal.

For an empty completed physical count, clear only Card Show and stop. Do not attempt a header-only or zero-quantity upload; empty-import behavior has not been verified. The app does not upload, clear, delete or recreate website inventory.

## Phone and website checks — November 10, 2026

| Check | Expected result |
| --- | --- |
| Start from Scan and Show | Both entry points open the same saved count. Download selects exact Card Show and displays the captured baseline time. |
| Resume and switch games | Count a few cards in two supported games, background/reopen, and resume. Each game's counts and the original baseline remain; returning does not download again. |
| Quantities and variants | Count two identical copies, leave one source card uncounted, add an extra card, and count a different finish/condition/language. Totals and comparison statuses are correct; distinct variants stay distinct. Manually set a source quantity for a game without camera support. |
| Completion and recovery | An unfinished count or unresolved SKU blocks replacement export. Finish the count, edit a quantity, and verify completion is required again. Missing count lists and save/download errors retain recoverable work and block a misleading export. |
| Files | Save/share both CSVs. Check the exact headers, escaping, positive absolute quantities, combined game totals and Card Show name. Comparison includes zero-count source cards and signed deltas. Replacement CSV has no price or delta column. |
| Website review | Before clearing, inspect upload mappings and all SKU/variant matches. After manually clearing/recreating only Card Show, reselect its current destination, override all locations, choose Add and compare the final result. Verify another location remains unchanged. |
| Empty and financial checks | An empty count calls for clearing Card Show only. Counting/exporting leaves local stock, imported inventory, receipts, costs and cash unchanged. |

Native compilation/tests, physical-phone camera/resume checks and a live website import remain pending until run. Public-source inspection does not establish hardware or importer success.

## Software validation for build 109

Local checks passed: 71 Python runner/workflow tests, 182 scanner JavaScript tests,
59 research-server tests and 49 Postman contract tests. The Xcode source/target
checker, 47 pinned runtime assets, changed Swift grammar, plist, shell syntax and
whitespace checks also passed. This Linux workspace cannot compile UIKit or run
XCTest. The new reconciliation, persistence and workflow XCTest cases and the
focused UI scenario are sent to GitHub's macOS runner; queued or running checks
are not passing results.
