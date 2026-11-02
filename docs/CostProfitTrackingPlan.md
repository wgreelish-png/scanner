# Cost and profit tracking plan

Status: proposed design only. No application changes are implemented by this document. CSV upload to TCGTracking is deferred. The trade-recognition choice is awaiting user input; the recommendation below is to carry original cost forward.

## User-facing behavior

Keep Market Value, Cost and Profit separate. Market Value is a reference quote; Cost is the amount actually invested; sale profit is actual proceeds minus selling fees and the cost of the copies sold. The show buying budget remains cash accounting: gross sales use the selected reinvest/save split (default 65/35), trade cash received is 100% reinvested, and fees reduce buying funds once. Selling a card does not debit its acquisition cost from cash again.

Show Inventory card details gain a compact Cost section. Allow actual total cost for a lot or actual cost per copy, with a reviewable total. Existing imported stock starts at Cost unknown; explicitly entered zero is distinct from missing. Keep lots from different acquisitions separate and respect the exact lots/quantities selected in checkout.

Purchase checkout assigns the confirmed actual cash paid to incoming cards. Start with calculated per-card cash offers, retaining explicit per-card overrides; if the whole-list price is negotiated, scale those amounts proportionally. Show a compact expandable cost breakdown and allow corrections before recording. If usable weights are absent or total zero with a positive payment, require a reviewed allocation rather than inventing equal costs. A known all-zero purchase remains zero. Acquisition charges already included in actual cash paid are included once.

Sale checkout retains build 36 whole-dollar suggestions and negotiated sale allocations. Add optional selling fees (default zero) and a compact Profit preview. Example: receive $100, pay $5 fees, sell copies costing $60 => $35 profit. The cash budget receives $65 buying/$35 saved and spends $5 fees from buying, so net buying funds increase $60. A negative sale profit is shown as a loss; it is never clamped to zero. The $60 cost is not charged a second time.

Receipts gain the recorded cost, fees, allocated proceeds and profit for each selected row. Show home gains Sales and Profit details with sales, selling fees, cost of sold cards and known profit; include by-show and all-time summaries. If any costs are missing, label profit incomplete and show the number/quantity excluded; never imply that the known subtotal is the full result. Separate any estimated costs/profits from actual known costs/profits.

## Recommended trade rule (pending user choice)

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

The alternative is to recognize a trade gain/loss at agreed exchange values and assign those values as incoming costs. This changes the timing of reported profit and needs a consistent valuation for make-even differences. Do not implement or mix both methods without an explicit decision. The first release should use one method, stored on each receipt; switching later must not silently recalculate history.

## Persistence and corrections

Extend the existing atomic stock/cash/receipt ledger rather than creating a second independent financial store. Store remaining total lot cost in integer cents, with unknown represented explicitly. Snapshot consumed cost, gross proceeds, allocated fees and signed profit on receipt lines when recording. Allocate cent remainders deterministically so partial-copy sales and the final copy consume exactly the original lot cost, and every receipt breakdown matches its actual totals. Sale allocations must be persisted rather than depending only on future rendering rules. Total transaction profit can still be known when market quotes are unavailable if actual proceeds, fees and all consumed costs are known; per-card proceeds need a reviewed allocation. No live quote is required to calculate known total profit offline.

Fees require coordinated changes to the stock transaction draft, receipt, linked cash entry and validators: the current stock-linked path requires feeCents == 0. Preserve gross-sale splitting and charge the fee only once. Budget-only historical entries must not be presented as costed card sales when no card/cost link exists.

Use financial file format v4, migrating existing v1-v3 without changing cash, quantities, receipts, show dates, saved lists or signing configuration. Old stock/historical receipt cost fields stay unknown; do not manufacture historical costs from current market values. Known historical purchase totals can support an explicit future backfill preview, but the first release should not silently reconstruct past trade chains.

Cost edits for remaining unsold inventory must not rewrite completed receipt snapshots. Corrections require an auditable cost adjustment; retrospective profit correction/backfill is a separate, explicit operation with a preview and dependent-trade handling. Keep the original recorded figures available.

Recording commits quantity, remaining cost, receipt, fee and cash effects together. Failed writes preserve the complete draft for retry. Repeated confirmations remain idempotent. Undo restores the exact original quantities and consumed costs, reverses original fees/cash/profit once, and retains existing dependent-transaction guards. Reversed receipts are excluded from active totals; deleting a show retains its history.

## Delivery sequence

1. Cost storage/migration, inventory cost entry, purchase cost allocations and exact partial-lot consumption.
2. Sale fees, immutable per-line proceeds/cost/profit allocations, compact checkout/receipt views and known/unknown summaries.
3. The chosen trade policy, carrying cost through trade chains and existing even-trade handling.
4. Audited corrections, historical backfill and optional financial reporting exports after the first release is validated. TCGTracking CSV upload remains deferred.

Finish the selected implementation scope before running checks. Validate known/zero/missing costs; purchases/overrides/negotiated totals; partial lots and final-cent recovery; discounted sales and fees; every trade direction including cash greater than cost; unknown-cost trade chains; failed-write retry/double taps; exact Undo/dependencies; deleted shows; v1-v3 migration; relaunch/offline behavior; and preservation of existing 65/35 gross-sale and 100% trade-cash rules. Run focused native/UI and portable checks, then distinguish actual Xcode results from phone behavior still pending. No additional simulator job is needed.
