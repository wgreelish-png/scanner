# Local show inventory and transactions

Build 35 makes **Show** the home for Inventory, Budget, Record Transaction and Transaction History. Working inventory persists across show dates, show deletion and app restarts. Lists retains scanned lists, physical scan order, offers and CSV export. No transaction writes to TCGTracking.

## Recording a deal

Select an active show, choose the transaction type and review the cards and amounts before tapping **Record Transaction**. Sell/trade selections support multiple stock rows and an explicit quantity from each row. Each acquisition retains a separate lot and card snapshot; identical cards are not silently merged. Incoming scanned lists remain available as historical records.

| Type | Stock movements | Cash and buying funds |
| --- | --- | --- |
| Sale | Selected quantities leave available stock. | Enter actual proceeds. The show’s sale split defaults to 65% buying / 35% saved. |
| Purchase | The whole selected scanned list enters stock. | Defaults to that list’s calculated Cash Offer, including its percentages and overrides. Cash paid reduces buying funds in full. |
| Trade | Incoming scanned list enters stock; selected stock leaves. | Equal agreed values exchange no cash. Explicit Make Even Trade permits an unequal exchange and records its concession. |
| Trade + Pay Customer | Incoming list enters; selected stock leaves. | $35 incoming / $5 outgoing pays $30. |
| Trade + Receive Cash | Incoming list enters; selected stock leaves. | $5 incoming / $30 outgoing receives $25. All $25 returns to buying funds. |

Trades start with the incoming list’s calculated **Trade Offer**, editable before recording. The outgoing value starts from selected cards’ saved market references and is also editable. These agreed values determine the cash difference directly. A partial/unpriced list has no automatic full-list offer; an explicitly entered agreed total is required. A known zero remains zero.

For $32 incoming versus $35 outgoing, **Make Even Trade** records $0 cash and a $3 concession. It preserves the card’s $35 market reference. The difference is not reported as realized loss or profit: reliable acquisition-cost accounting is not available for this stock. Receipts retain the original agreed amounts, market reference snapshots, cash split and quantities after prices or source lists change.

The list review Record Transaction action opens the same stock-aware checkout with that list selected. Completed lists link to their receipt; Nothing Happened and Clear Outcome cannot independently reverse its cash. Existing legacy outcomes, manually linked cash and undecodable nonempty legacy markers prevent a second acquisition. Undo/review the prior transaction or deliberately clear its legacy outcome before using that list again. Offer calculations and card edits alone never record a deal.

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
