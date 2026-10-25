# Offers and trade transactions

Offer review uses the list's existing scanned prices, quantities, per-card overrides and session percentages. Editing **My Card Price** recalculates locally; it never starts a price lookup. Market value, trade credit and calculated cash value remain separate. The final card clearly shows who pays whom.

Choose **Cash Only** to buy the collector's entire list. Choose **Trade + Cash** to apply their trade credit to your selling price and buy the unused portion at the selected cash valuation. **Custom cash offer** sets the cash value for the whole list in both modes: adjusting it immediately changes the cash payout; clearing it restores the calculated offer. Choose **Trade Credit Only** to leave unused credit visible without paying cash; the app does not create or store a credit balance for future visits.

For market value M, trade fraction t and cash fraction c, with no per-card overrides or negotiated amount, total trade credit T = M × t and cash value C = M × c. Your selling price is P:

- Trade applied = min(P, T).
- Customer pays = max(0, P − T).
- Unused trade credit = max(0, T − P).
- Remaining market value = unused trade credit ÷ t.
- Cash payout = remaining market value × c.

The implementation allocates the unused fraction of the combined trade valuation proportionally across the combined market and selected cash valuations: remaining market = M × unused/T; cash payout = C × unused/T. Here C is the negotiated full-list cash amount when supplied, otherwise the calculated cash offer. This preserves existing trade overrides and per-line rounding. It matches the formulas above when the aggregate offers equal market times their rates; existing per-line rounding remains part of the displayed totals. It does not choose specific physical cards from the collector's list.

**Transaction Math** shows the configured cash/trade percentages and the percentages actually applied to the market total. Applied cash percentage = selected C / M × 100; applied trade percentage = T / M × 100. Negotiated amounts, per-card overrides and cent rounding can make these differ from the configured base rates. An incomplete or zero market total cannot establish a whole-list applied percentage and is shown as unavailable. A known zero cash amount against a positive complete market total is 0%.

| Mode | Market | Trade value | Cash value | My Card Price | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Trade + Cash | $5.38 | $4.30 | Configured | $10.00 | Customer Pays You $5.70 |
| Trade + Cash | $20.00 | $16.00 | $15.00 | $16.00 | Even Trade $0.00 |
| Trade + Cash | $20.00 | $16.00 | $15.00 | $10.00 | You Pay Customer $5.63 |
| Trade + Cash, cash adjusted | $20.00 | $16.00 | $16.00 | $10.00 | You Pay Customer $6.00; applied cash 80% |
| Trade + Cash, cash adjusted | $20.00 | $16.00 | $0.00 | $10.00 | You Pay Customer $0.00; applied cash 0% |
| Cash Only | $20.00 | $16.00 | $15.00 | Blank | Cash Offer $15.00 |
| Trade Credit Only | $20.00 | $16.00 | $15.00 | $10.00 | $6.00 unused credit, no cash payout |

All arithmetic uses Decimal. Final currency values round to cents using the existing half-up currency helper. Empty prices, known zero, invalid/negative amounts, zero trade credit and unpriced cards have distinct handling. With no available trade credit, the customer owes the full selling price and no conversion divides by zero; choose Cash Only to make a cash offer for those cards. Unpriced copies remain excluded and clearly mark the result as partial.

Saved offer estimates retain immutable transaction inputs and results in optional fields in their existing JSON. New results also store their selected full-list cash basis. Older mixed estimates used calculated cash even when a custom cash-only alternative was present; their original payout and percentage basis remain unchanged when reopened. No SwiftData schema or migration change is introduced. Saving an estimate does not record a completed purchase or a future credit liability.

On an iPhone, check numeric keyboard dismissal, immediate recalculation, large text, long amounts, custom cash, all five scenarios and saved-estimate reopening. The native layout also adapts to wide windows; a separate desktop app target is not introduced.

Implementation files:

- `CardShowScanner/SessionReviewView.swift`: modern offer cards, price input, transaction controls and immutable saved-estimate presentation.
- `CardShowScanner/TradeTransactionCalculator.swift`: reusable Decimal transaction calculation and validation.
- `CardShowScanner/OfferCalculator.swift` and `CardShowScanner/SessionService.swift`: optional transaction JSON and saved-estimate integration.
- `Tests/TradeTransactionTests.swift`: 11 native tests covering scenarios, boundaries and persistence.
