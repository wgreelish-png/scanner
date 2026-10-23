# Offers and trade transactions

Offer review uses the list's existing scanned prices, quantities, per-card overrides and session percentages. Editing **My Card Price** recalculates locally; it never starts a price lookup. Market value, trade credit and calculated cash value remain separate. The final card clearly shows who pays whom.

Choose **Cash Only** to buy the collector's entire list. The existing custom whole-list cash amount still overrides the calculated cash offer in this mode. Choose **Trade + Cash** to apply their trade credit to your selling price and buy the unused portion at the calculated cash valuation. Choose **Trade Credit Only** to leave unused credit visible without paying cash; the app does not create or store a credit balance for future visits.

For market value M, trade fraction t and cash fraction c, with no per-card overrides, total trade credit T = M × t and cash value C = M × c. Your selling price is P:

- Trade applied = min(P, T).
- Customer pays = max(0, P − T).
- Unused trade credit = max(0, T − P).
- Remaining market value = unused trade credit ÷ t.
- Cash payout = remaining market value × c.

The implementation allocates the unused fraction of the combined trade valuation proportionally across the combined market and cash valuations: remaining market = M × unused/T; cash payout = C × unused/T. This preserves existing per-card overrides and per-line rounding, and matches the formulas above for uniform rates. It does not choose specific physical cards from the collector's list. A custom whole-list cash offer applies only to Cash Only, so it never silently changes the rate used to buy remaining value.

| Mode | Market | Trade value | Cash value | My Card Price | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Trade + Cash | $5.38 | $4.30 | Configured | $10.00 | Customer Pays You $5.70 |
| Trade + Cash | $20.00 | $16.00 | $15.00 | $16.00 | Even Trade $0.00 |
| Trade + Cash | $20.00 | $16.00 | $15.00 | $10.00 | You Pay Customer $5.63 |
| Cash Only | $20.00 | $16.00 | $15.00 | Blank | Cash Offer $15.00 |
| Trade Credit Only | $20.00 | $16.00 | $15.00 | $10.00 | $6.00 unused credit, no cash payout |

All arithmetic uses Decimal. Final currency values round to cents using the existing half-up currency helper. Empty prices, known zero, invalid/negative amounts, zero trade credit and unpriced cards have distinct handling. With no available trade credit, the customer owes the full selling price and no conversion divides by zero; choose Cash Only to make a cash offer for those cards. Unpriced copies remain excluded and clearly mark the result as partial.

Saved offer estimates retain immutable transaction inputs and results in an optional field in their existing JSON. Older estimates decode without that field; no SwiftData schema or migration change is introduced. Saving an estimate does not record a completed purchase or a future credit liability.

On an iPhone, check numeric keyboard dismissal, immediate recalculation, large text, long amounts, custom cash, all five scenarios and saved-estimate reopening. The native layout also adapts to wide windows; a separate desktop app target is not introduced.
