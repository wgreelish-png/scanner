> Build 30 adds optional start/end **Show dates** in New/Edit Show and the budget dashboard. Existing undated shows remain undated. Dates describe the show; individual transaction timestamps and cash calculations are unchanged.

# Show cash budget

Build 24 adds **Show Budget** to Lists and the Scan home screen. Set a show name and starting buying funds, then explicitly record cash purchases, sales and trades. Each show and its ledger remain saved when the app closes; creating another show keeps the previous one available in the show picker.

## Your 65% / 35% gross-sales split

For every cash receipt, **65% of the gross amount is allocated for buying and 35% is reserved for you**. Fees reduce buying funds separately. Purchases reduce available buying funds by their actual total cash cost. A pure card-for-card trade changes neither cash balance; a trade with cash uses only the cash paid or received. Card market values and offer estimates never count as spendable cash.

| Action | Available to buy | Saved for you |
| --- | ---: | ---: |
| Start with $300 | $300 | $0 |
| Sell for $200, no fees | $430 | $70 |
| Buy for $100 | $330 | $70 |
| Pay $50 as part of a trade | $280 | $70 |
| Receive $100 as part of a trade | $345 | $105 |
| Exchange cards without cash | $345 | $105 |

With a $200 sale and $10 fees, buying allocation is still $130 and your allocation is still $70; the net increase in available buying funds is $120. Starting at $300 and then paying $100 for a purchase leaves **$320 available and $70 reserved**. Cash remaining, including savings, is $390.

The dashboard shows starting funds, gross receipts, buying allocation, cash spent, fees, available buying funds and the personal allocation. A negative buying balance stays visible as **Over budget**. Recorded values use integer USD cents; reinvestment is rounded half-up per receipt and the remaining cents go to the personal allocation so no money disappears through rounding. This is a cash-allocation ledger, not a realized-profit calculation or bank transfer.

## Recording and correcting deals

Use **Buy**, **Sell** or **Trade** in Show Budget. For incoming cash, enter the gross amount and optional fees. For purchases, enter total cash paid including purchase fees. Trade lets you choose no cash, cash paid or cash received. Each form previews the allocation and resulting buying balance before you explicitly record it.

List review offers **Record Cash in Show Budget** with that list's ID and name attached as a receipt reference. Purchase/trade status suggests the entry type, but no amount is guessed from an offer or market value. A Trade + Purchase starts with cash paid selected. Merely marking a list outcome or saving an offer does not spend money; confirming the cash entry updates the budget.

You can edit a show's name or starting funds. That changes the starting balance without rewriting past sale allocations. To correct an entry, open it, choose **Void Entry**, and confirm. It remains in history while its effect is removed from totals; then record the correct amount. Deleting an inventory list does not delete its financial receipts.

## Persistence and verification

Budgets use a separate versioned Application Support file, `show-budgets.json`, with atomic writes and file protection. It remains included in device backups. The existing SwiftData schemas, migration path, inventory, signing, credentials and offer snapshots are unchanged. Budget recording needs no network connection.

The app publishes new totals only after persistence succeeds. A failed save retains the form for retry. Stable receipt IDs prevent double counting repeated confirmations; conflicting data under an existing receipt ID is rejected. Unreadable, unsupported or oversized budget files remain preserved and block financial changes until successfully reloaded. The app never silently replaces them with an empty budget.

Native fixtures cover the 300/200 example, gross fees, cash/pure trades, cent rounding, overspending, voiding, file reopening, duplicate saves, failed-write retry, show isolation and invalid-state rejection. The focused UI case creates an isolated real budget file, records $300 starting funds, $200 gross sale/$10 fees and a $100 purchase, then relaunches and checks $320/$70. The explicit Debug fixture cannot read or replace the production budget file and is excluded from Release.

On an iPhone, create a test show, record that example, test all three trade directions, cancel a form, reopen the app, switch between shows and void a mistaken entry. Confirm list outcomes and saved offers remain intact. Native, simulator and device results must be reported separately; fixture coverage does not establish a completed physical-device check.
