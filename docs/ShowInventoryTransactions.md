# Local show inventory and transactions

Build 35 makes **Show** the home for Inventory, Budget, Record Transaction and Transaction History. Working inventory persists across show dates, show deletion and app restarts. Lists retains scanned lists, physical scan order, offers and CSV export. No transaction writes to TCGTracking.

## Recording a deal

Select an active show, choose the transaction type and review the cards and amounts before tapping **Record Transaction**. Sell/trade selections support multiple stock rows and an explicit quantity from each row. Each acquisition retains a separate lot and card snapshot; identical cards are not silently merged. Incoming scanned lists remain available as historical records.

| Type | Stock movements | Cash and buying funds |
| --- | --- | --- |
| Sale | Selected quantities leave available stock. | Starts with each selected copy’s market value rounded to the nearest dollar; edit the actual proceeds if needed. The show’s sale split defaults to 65% buying / 35% saved. |
| Purchase | The whole selected scanned list enters stock. | Defaults to that list’s calculated Cash Offer, including its percentages and overrides. Cash paid reduces buying funds in full. |
| Trade | Incoming scanned list enters stock; selected stock leaves. | Equal agreed values exchange no cash. Explicit Make Even Trade permits an unequal exchange and records its concession. |
| Trade + Pay Customer | Incoming list enters; selected stock leaves. | $35 incoming / $5 outgoing pays $30. |
| Trade + Receive Cash | Incoming list enters; selected stock leaves. | $5 incoming / $30 outgoing receives $25. All $25 returns to buying funds. |

Trades start with the incoming list’s calculated **Trade Offer**, editable before recording. The outgoing value starts from selected cards’ saved market references rounded to the nearest dollar per copy and is also editable. These agreed values determine the cash difference directly. A partial/unpriced list has no automatic full-list offer; an explicitly entered agreed total is required. A known zero remains zero.

For $32 incoming versus $35 outgoing, **Make Even Trade** records $0 cash and a $3 concession. It preserves the card’s $35 market reference. The difference is not reported as realized loss or profit: reliable acquisition-cost accounting is not available for this stock. Receipts retain the original agreed amounts, market reference snapshots, cash split and quantities after prices or source lists change.

The list review Record Transaction action opens the same stock-aware checkout with that list selected. Completed lists link to their receipt; Nothing Happened and Clear Outcome cannot independently reverse its cash. Existing legacy outcomes, manually linked cash and undecodable nonempty legacy markers prevent a second acquisition. Undo/review the prior transaction or deliberately clear its legacy outcome before using that list again. Offer calculations and card edits alone never record a deal.

## Checkout corrections in build 36

**Record Transaction** stays in a fixed top bar with the cash total. **Select Inventory Cards** opens a separate searchable inventory with thumbnails, available quantities, selection markers and quantity controls. Done returns to checkout; its selected cards stay in a compact expandable summary. Search keyboard Done dismisses the keyboard while retaining the query, both here and in Show Inventory. No stock or money changes during selection.

Sales automatically sum the selected copies’ market prices rounded to whole dollars individually: two $8.28 cards and one $6.77 card start at $23. Standard nearest-dollar rounding applies ($0.49 becomes $0 and $0.50 becomes $1); missing prices require an explicit total. Changing the total retains that amount when the selection changes. **Use Rounded Market Total** restores automatic updates.

If the received amount differs from the rounded suggestion, all cards share one percentage of their original market value. A $100 card and two $25 cards sold for $120 use 80%: $80 and $40 for those rows. Cent remainders are allocated deterministically so row totals equal the actual proceeds exactly. Checkout and the saved receipt show the percentage and an expandable allocation breakdown. The default rounded suggestion keeps its individually rounded card amounts. Unknown prices or a zero market total cannot support a proportional nonzero allocation. Original market references remain unchanged; the existing show cash split still uses the actual total received.

**Review / Edit Selected List** opens the existing list editor from checkout. Done returns to the same deal and reloads saved card, quantity, name and offer changes. Automatic incoming amounts recalculate; a manually negotiated amount is retained with a review message. Changed inputs clear a previous Make Even Trade confirmation. Other selections, the selected show and the note stay in place. The editor hides transaction/outcome actions to avoid starting another checkout. Returning from editing never records the transaction.

Sale allocations derive from the immutable receipt card references and its actual cash total, so they remain available across relaunches without changing financial format v3 or rewriting any historical cash/stock entries.

## Sale cash editing in build 37

Tap **Actual cash received** to open a dedicated **Sale Amount** editor. Its text and keyboard focus are local to the editor; typing does not update the checkout's stock validation, price allocations or layout. Clear removes the current entry; Done applies a valid USD amount once and returns to checkout. Empty or invalid input disables Done. Cancel or dismiss keeps the previous amount. Accepting an unchanged amount keeps automatic whole-dollar pricing active. An explicitly changed amount remains fixed when the selection changes until Use Rounded Market Total restores automatic pricing. Only Record Transaction commits inventory and budget changes.

The pinned checkout summary stays present for incomplete drafts. Checkout calculates its preview once per render, validates selected quantities using an inventory index instead of scanning every inventory row for every selected card, and computes detailed allocation rows only when their disclosure is expanded. The sale-percentage display and existing exact-cent allocation math remain unchanged. No financial schema, existing data, signing configuration or scanner-engine change is included.

The uploaded build-36 log contains two invalid-frame warnings, eleven UIKit keyboard constraint conflicts and nine RTI keyboard session warnings, but no app crash, main-thread stack trace, sale interaction breadcrumb or measured hang duration. These warnings do not prove a specific root cause. The changes remove identified keyboard/layout coupling and avoidable computation; resolution of the reported hang still requires an iPhone check. New `show_transaction.cash_edit` breadcrumbs record only fixed phases (requested, presented, focused/unfocused, applied/cancelled, closed, dismissed) and bounded elapsed time. They never record the entered amount, card/account identifiers or credentials.

After implementation, UI regressions cover repeated open/edit/close, invalid input, cancellation, unchanged acceptance retaining automatic pricing, discounted totals, manual amounts surviving selection changes, reset restoring automatic pricing, and preserved stock/budget. Existing sale/relaunch/Undo tests use the new editor. These cases run in the existing transaction UI job; no new simulator job is added. On the phone, repeatedly open cash entry, clear and replace the amount, cancel once, apply a discounted total, change selections, reset, record and undo. Check that typing, Done and reopening remain responsive and upload a new log if a pause remains.

Build-37 local checks passed Swift grammar parsing of all 143 files, Xcode app/native/UI source and resource membership, all 47 pinned scanner assets/dependencies, and whitespace validation. Two UI regressions were added and existing sale cases were adapted. No native/UI tests or Xcode build ran here because this Linux workspace has no Swift/Xcode installation. The unchanged JavaScript/Python suites were not rerun. Physical-iPhone resolution of the reported hang remains unverified.

## Import and source snapshots

The existing TCGTracking location importer remains a read-only snapshot in SwiftData. The first complete saved snapshot seeds working inventory once. Refreshing or removing that source snapshot cannot restock locally sold cards, change local quantities or delete newly acquired cards. The source page labels this distinction, and remains available under Show → Inventory → TCGTracking Source Snapshot. Subsequent website reconciliation and outbound synchronization are deferred; new/changed website rows are not automatically applied to an already established working inventory.

## Undo and deleting shows

Transaction History includes stock-aware receipts and older cash-only receipts, including those associated with deleted shows. **Undo Transaction** previews and atomically reverses card movements and the original cash allocation. A repeated undo has no additional effect. If an acquired lot was used in a later sale/trade, that later transaction must be undone first. An unrelated identical card cannot substitute for that lot. Cash linked to stock cannot be voided independently through the older cash-only screen.

**Show Budget → Show Options → Delete Show** removes the show from the selector and clears its active selection. A tombstone retains its settings and receipts; working inventory and completed deals stay unchanged. Undo remains available after show deletion or after its dates have ended. Normal new transactions still require an applicable show at save time.

## Persistence and migration

Budget format v3 stores working stock, transaction receipts and cash entries together in the existing Application Support file, using one validated atomic write. A write failure publishes no partial stock/cash change, preserves the form and allows retry with the same operation identity. Repeated confirmed commands return their original receipt even if the show or source list has subsequently changed. A changed payload cannot reuse a committed ID.

Existing financial v1/v2 files migrate in memory and retain their cash, dates, list-outcome journal and historical splits. They are written as v3 on the next explicit mutation. Existing trade receipts retain their recorded split; newly recorded trade cash uses 100% reinvestment. Earlier apps reject v3 instead of silently dropping stock/history. The SwiftData schema, existing scanned lists/sessions/offers, signing configuration and scanner engine are unchanged.

The file is bounded to 32 MiB; import and per-transaction inputs to 10,000 rows; retained stock lots to 50,000; receipts to 20,000; visible shows to 100 and retained show records to 1,000. Sold/undone lots remain available for audit and dependency validation. Capacity failures retain the prior file and explain that no change was saved. Deleting a show frees a visible-show slot without erasing receipts.

## Verification

All implementation finishes before checks run. Native cases cover exact cash/concession math, market-reference preservation, atomic failure/retry, duplicate list/operation protection, persisted order/lots, undo dependencies, deleted/past shows, migration, 10,000-row import capacity, corrupt financial data, offer defaults, changed/deleted sources, corrupt legacy markers and refresh preservation. UI cases cover transaction review cancellation, multi-card sale/relaunch/undo, even-trade confirmation, and the new Show navigation. They use isolated synthetic fixtures and no real provider account.

Xcode/native execution and physical-iPhone acceptance remain separate from portable source/resource checks. On the phone, compare stock and budget before/after each type in the table, including the exact $32/$35, $35/$5 and $5/$30 examples. Sell only one copy from a multi-copy row, relaunch and confirm its remaining quantity. Undo each transaction and verify its original show’s cash split and stock return once. Try undoing a purchase whose acquired card was later sold. Delete a disposable show and verify stock/history remain. Refresh the website snapshot after a local sale and verify that sold copies stay unavailable. Repeat basic transaction/history use offline. Preserve the current installation while checking migration.

After implementation completed, local checks passed 151 JavaScript tests, 27 Python helper tests, grammar parsing of 141 Swift files, Xcode membership for 80 app / 49 native-test / 12 UI-test sources, all 47 pinned scanner assets/dependencies, and shell/whitespace validation. Twenty-five new native cases and two transaction UI cases are registered; existing navigation/outcome UI tests were adapted to explicit transaction review. These native/UI cases and the unsigned Xcode build have not run in this Linux workspace. They use the existing CI jobs; no additional simulator job was added. Actual iPhone transactions, v1/v2 financial migration, and offline/relaunch behavior still need device acceptance.

Build 36 adds native regression coverage for whole-dollar defaults, common market percentages, exact/repeatable cent allocation, missing versus zero prices, receipt allocations after relaunch/undo, and editing incoming list snapshots. UI regressions cover the separate selector, search keyboard dismissal, the pinned automatic checkout and returning from list edits while retaining negotiated cash. These tests are registered for Xcode; native/UI execution and phone acceptance remain pending until run on macOS/device.

Build-36 local verification passed grammar parsing of 143 Swift files, Xcode target membership (81 app / 50 native-test / 12 UI-test sources), all 47 pinned scanner assets/dependencies, and shell/whitespace checks. Six native cases and two UI cases were added; the existing two transaction UI cases now use the separate selector. Xcode/native/UI execution and physical-iPhone behavior remain unverified for build 36. The unchanged JavaScript/Python suites were not rerun for this Swift-only change; their build-35 results above remain historical.
