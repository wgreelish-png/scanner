# Cost and profit tracking plan

Status: implemented in build 40, with native and iPhone validation tracked separately below. Trades use the plan's carry-forward rule. CSV upload to TCGTracking and retrospective historical cost backfill remain deferred.

## User-facing behavior

Keep Market Value, Cost and Profit separate. Market Value is a reference quote; Cost is the amount actually invested; sale profit is actual proceeds minus selling fees and the cost of the copies sold. The show buying budget remains cash accounting: gross sales use the selected reinvest/save split (default 65/35), trade cash received is 100% reinvested, and fees reduce buying funds once. Selling a card does not debit its acquisition cost from cash again.

Open a working-inventory card and tap **Sell This Card**. Checkout opens with that exact lot selected at quantity one. Add more cards or copies in the existing inventory selector for bundles. The action requires available stock and an applicable show; opening it never records a sale.

Inventory card details show **Cost & acquisition** below the thumbnail and quantity. Enter or clear the actual total cost of the remaining lot. Existing imported stock starts at **Cost unknown**; explicitly entered zero is distinct from missing. Lots from different acquisitions stay separate, and checkout consumes the exact selected lots and quantities. Acquired cards link to their original Purchase or Trade receipt; that receipt links back to the retained inventory lots.

Purchase checkout assigns the confirmed actual cash paid to incoming cards. Calculated per-card cash offers, including overrides and quantities, supply allocation weights; a negotiated total scales those amounts proportionally. Review or correct total-lot amounts in the expandable cost breakdown. Entered amounts stay fixed, with the remaining total allocated among unset rows where possible. A single remaining row receives the exact remainder. If several rows lack usable weights for a positive remainder, supply their costs rather than inventing equal costs. A known all-zero purchase remains zero. Acquisition charges already included in actual cash paid are included once.

Sale checkout retains build 36 whole-dollar suggestions and negotiated sale allocations. Add optional selling fees (default zero) and a compact Profit preview. Example: receive $100, pay $5 fees, sell copies costing $60 => $35 profit. The cash budget receives $65 buying/$35 saved and spends $5 fees from buying, so net buying funds increase $60. A negative sale profit is shown as a loss; it is never clamped to zero. The $60 cost is not charged a second time.

Receipts retain recorded costs, fees and available per-row proceeds/profits. Show → **Sales & Profit** displays gross sales, selling fees, known sold cost and known profit, across all shows or one show, including deleted shows. Missing costs produce **Profit incomplete**, with excluded quantities and uncosted legacy transactions. A known subtotal is never described as complete profit. The report makes no estimated acquisition costs.

### The $7 purchase / $10 sale example

Starting with $300 buying funds and no fees:

| Action | Buying funds | Saved cash | Recorded profit |
| --- | ---: | ---: | ---: |
| Buy the card for $7 | $293.00 | $0.00 | $0.00 |
| Sell it for $10 | $299.50 | $3.50 | $3.00 |

The sale adds $6.50 to buying funds and $3.50 to savings, using gross proceeds. It consumes the recorded $7 inventory cost for profit reporting without charging cash again. A $1 selling fee would leave $298.50 buying funds, $3.50 saved and $2 profit. Savings can include recovered capital because the user's split applies to gross sale proceeds, not profit.

## Implemented trade rule

Carry original acquisition cost into incoming inventory, preserving agreed trade values and make-even concessions separately. This avoids recognizing a paper gain on an even trade.

For known outgoing cost B, actual cash paid P, actual cash received R:

- Incoming carried cost = max(B + P - R, 0).
- Trade cash profit recognized now = max(R - B - P, 0).

| Outgoing cards cost $40 | Incoming cost | Profit now |
| --- | ---: | ---: |
| Even trade | $40 | $0 |
| Pay customer $20 | $60 | $0 |
| Receive $20 | $20 | $0 |
| Receive $60 | $0 | $20 |

Allocate incoming carried cost using relative agreed card values; calculated per-card trade offers/overrides provide default weights. Require review where weights are missing. If outgoing cost is unknown, incoming carried cost and trade profit remain unknown; cash, quantities, paid/received amounts and agreed values still record normally.

An even exchange of cards valued at $35 and $32 still records the existing $3 value concession. If the outgoing card cost $20, the incoming card carries $20 cost; neither its market reference nor cash budget changes because of the concession.

Each new receipt records the `carryForwardV1` policy. Later market-price or cost edits cannot silently recalculate completed receipts. If outgoing basis is unknown, record the trade with unknown incoming basis or first correct the remaining outgoing stock cost. Incoming cost overrides cannot manufacture a known cost for an unknown-cost trade.

## Persistence and corrections

Extend the existing atomic stock/cash/receipt ledger rather than creating a second independent financial store. Store remaining total lot cost in integer cents, with unknown represented explicitly. Snapshot consumed cost, gross proceeds, allocated fees and signed profit on receipt lines when recording. Allocate cent remainders deterministically so partial-copy sales and the final copy consume exactly the original lot cost, and every receipt breakdown matches its actual totals. Sale allocations must be persisted rather than depending only on future rendering rules. Total transaction profit can still be known when market quotes are unavailable if actual proceeds, fees and all consumed costs are known; per-card proceeds need a reviewed allocation. No live quote is required to calculate known total profit offline.

Fees require coordinated changes to the stock transaction draft, receipt, linked cash entry and validators: the current stock-linked path requires feeCents == 0. Preserve gross-sale splitting and charge the fee only once. Budget-only historical entries must not be presented as costed card sales when no card/cost link exists.

Financial file format v4 migrates existing v1-v3 without changing cash, quantities, receipt identities, show dates, saved lists or signing configuration. Old stock/historical receipt cost fields stay unknown; current market values never manufacture historical costs. Known historical purchase totals can support a future explicit backfill preview, but this release does not reconstruct past trade chains. Older builds reject v4 rather than silently dropping cost history.

Cost edits affect only remaining unsold stock and create an audit record. Completed receipts and their profits remain unchanged. A v4 checkpoint and mutation journal replay quantity/cost effects, validate receipt accounting and reject missing or inconsistent journal data. Migrated legacy receipts are explicitly identified, including previously undone receipts; removing new accounting cannot disguise a new receipt as historical.

Recording commits quantity, remaining cost, receipt, fee and cash effects together. Failed writes preserve the complete draft for retry. Repeated confirmations remain idempotent. Undo restores the exact original quantities and consumed costs, reverses original fees/cash/profit once, and retains existing dependent-transaction guards. Reversed receipts are excluded from active totals; deleting a show retains its history.

## Validation and phone acceptance

Implementation finishes before checks run. New native cases cover known/zero/missing costs, offer overrides and negotiated totals, partial lots and final-cent recovery, fees/losses, trade directions, unknown-cost chains, atomic failure/retry, duplicate IDs, exact Undo/dependencies, audited edits, deleted shows, migrations and corrupted journals. Two new UI cases cover purchase → Quick Sell → report → relaunch → Undo, and legacy unknown → known-zero → cleared cost → fee-bearing sale → Undo. They use the existing CI targets; no simulator job is added.

After implementation, local checks passed Swift grammar parsing of all 153 files, Xcode source membership (87 app / 54 native-test / 12 UI-test files) and bundled-resource membership, all 47 pinned recognition assets/dependencies, and permission/privacy metadata (portrait-only, foreground-only, existing Bluetooth purpose). The unchanged JavaScript and Python suites were not rerun for this Swift-only feature. Xcode compilation and native/UI execution have not run in this Linux workspace; test definitions and grammar checks are not evidence of a native test pass. Physical-iPhone behavior remains unverified.

On the iPhone, preserve the installed data and check:

1. Buy a one-card list for $7. Verify the $7 cost and Purchase receipt in inventory, and $7 deducted from buying funds.
2. Tap Sell This Card, verify quantity one is preselected, and sell for $10. Verify $3 profit, $6.50 reinvested and $3.50 saved. Repeat with a fee and a discounted sale.
3. Sell one copy from a multi-copy lot, relaunch and inspect remaining cost. Undo and verify exact quantity/cost/cash recovery. Undo dependent deals in reverse order.
4. Check old stock displays Cost unknown, set a remaining-lot cost, and verify no budget movement. Explicit zero must stay distinct from unknown.
5. Trade with and without cash; verify original cost carries into acquired lots, and trade cash returns 100% to buying funds. Unknown outgoing cost must remain unknown downstream.
6. Check all-show and per-show profit, legacy incomplete labels, deleted-show history, bundle checkout and offline report/receipt use.

Historical backfill, financial reporting export and TCGTracking transaction synchronization remain deferred. Scanner recognition, printing, saved lists/offers and personal signing are preserved.
