# Card Show inventory

Build 29 adds **Lists → Card Show Inventory**. Import connects to the existing TCGTracking website sign-in, finds the active location named exactly **Card Show** and saves a dedicated list on this iPhone. **Card Show Need To Price** is a different location and is never included by a partial name match. The location ID is discovered from the account rather than hardcoded.

1. Open Card Show Inventory and tap **Import Inventory**.
2. If sign-in is required, choose **Sign In to TCGTracking**, complete the existing account flow and return to inventory. Returning retries the import.
3. Open **Saved Inventory** to browse card details, research and CSV export. The imported rows retain the website's quantities, including multiple copies in one source row.
4. Use **Refresh Inventory** to update the saved copy, or **Make an Editable Copy** to create an ordinary list for scanning, editing and the existing session/offer workflow.

Opening the importer or saved list makes no inventory request. Card data, quantities and last imported prices remain available after closing/reopening the app and with poor reception. Artwork that is not cached and new market/research lookups can need internet. The update label shows the last successful import time and does not claim that old data is current.

## Refresh behavior

Refresh is a one-way read from TCGTracking. Source card fields and quantities are read-only in the imported list; editable copies are independent. CSV export, research, list outcomes and explicit budget receipts remain available. Public price research still uses the standard Open API. The imported `market_price` is the inventory response's last saved value, labeled as imported; it is not relabeled as a fresh Open API quote or replaced with a listing/custom asking price.

All pages are fetched and validated before any saved row changes. Refresh matches each row by the website's stable `inventory_id`, preserves local row/list UUIDs and updates returned fields/quantities. Different inventory IDs remain different rows even for identical cards. Existing row order is retained and new source rows append; **Import Order** describes this order rather than implying an original physical scan sequence. A source row missing from a complete successful snapshot is removed locally. An empty complete snapshot clears source rows.

The entire update, including its timestamp and location link, commits in one SwiftData save. Partial pages, duplicates, changing totals, another location/account, invalid fields, connectivity/authentication errors and save failures retain the previous saved copy. Overlapping taps cannot start duplicate imports; canceled/late replies cannot overwrite a newer refresh. An unrelated unsaved draft prevents import rather than being rolled back.

Swipe **Remove Saved Copy** on the pinned entry to remove the local list. It stays removed until an explicit import. No website inventory is changed. An existing ordinary list named Card Show is never adopted or overwritten. Refresh remains linked to the originally imported location; sign into the original account or remove the local copy before importing a different account's location.

## Endpoints and storage

| Purpose | Read-only request |
| --- | --- |
| Find the exact location | `GET https://tcgtracking.com/dash/controllers/ajax/inventory-locations.php?action=list` |
| Read each location page | `GET https://tcgtracking.com/dash/controllers/ajax/inventory-stock.php?action=list&location_ids={id}&page={page}&limit=500&sort=live_desc` |

These are the website/session endpoints verified from the provided inventory capture, separate from Beta and Seller Connect. The native client copies scoped, unexpired WebKit cookies into an ephemeral HTTP session. It permits only fixed-host HTTPS GET requests, rejects redirects, limits response/page/row sizes and cancels when the importer is left or the app becomes inactive. It does not poll or refresh in the background. Only card fields needed by the app are decoded; source notes, costs, account settings and raw responses are not saved or logged. Initial support is the verified catalog stock format, up to 10,000 rows; custom inventory or changed response contracts fail without replacing the cache.

Schema V4 adds nullable source metadata to lists and an optional source inventory ID to rows. Released V1/V2/V3 schemas remain frozen, with lightweight migration through V4. Existing lists, legacy quantities, scan order, outcomes, sessions, offers and personal signing configuration are retained. No separate sidecar file can recreate a deleted import or link a partial save.

## Verification and phone acceptance

Tests are written for full pagination, wrong accounts/locations, missing versus zero prices, duplicates, cancellation, single-flight refresh, stable row identity, quantity changes, removals, failed-save retry, offline reopening, editable copies and V3 migration. They run only after all implementation is complete. Synthetic fixtures do not prove live website access.

On the iPhone:

1. Keep the existing installation/data. Import the Card Show location and compare the current website row count and total quantity; the provided historical sample contained 92 rows and 99 cards.
2. Refresh twice and verify one list, unchanged row identities and no extra copies. Change a quantity or move a card on the website, refresh, and verify the phone follows that location.
3. Enable Airplane Mode, close/reopen the app and browse saved cards, prices/quantities and export CSV. A failed refresh must keep the previous contents and timestamp.
4. Test an expired sign-in, a canceled refresh, leaving the page and locking/resuming the phone. Check the new diagnostics for safe phase/count/status events; no account cookies or raw inventory are logged.
5. Make an editable copy and test its normal scanning/offers. Remove only the imported saved copy, reopen Lists and confirm it stays removed until Import. Existing scan lists and their offers must remain unchanged.

After implementation completed, local checks passed all 142 JavaScript tests, 27 Python helper tests, grammar parsing of 122 Swift files, target membership for 70 app/43 native-test/9 UI-test files, all 47 pinned scanner assets/dependency closure and shell/whitespace checks. The 36 new native cases and one UI fixture case are registered in the existing CI jobs; no new simulator job was added. Native migration, HTTP cookie/session compatibility, the unsigned Release build and physical-iPhone behavior still require macOS/device validation; Linux checks cannot establish these results.
