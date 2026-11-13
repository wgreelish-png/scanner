# Detailed market charts — November 13, 2026

Build 115 adds the documented Opp V2 charts to native Card Research. The existing card controls, public market quote, inventory actions and graded details remain available.

Market Activity starts on 30 days. Its aligned price and volume charts compare the overlapping 30- and 90-day windows; selecting 365D includes annual context. Volume is reported units divided by the number of days, with the original quantities retained in the summary and detailed values. Missing quantities stay unavailable and reported zeroes stay zero.

The price chart follows the provider example's `tcg_sold_avg ?? tcg_market_avg`, explicitly labeling market-average fallback. The sold-average fields retain their original missing state. These charts compare summary windows; they are not dated transaction history. No unverified `chart_buckets_90d` decoder or custom volatility rating is enabled.

Native chart inspection uses chart-confined selection. Sliding across the price or volume chart highlights the same reporting window and exposes prices, basis, original counts, calculated daily rates and the source update time. ManaPool values remain separate when returned. Benchmark bars retain shipping context, and marketplace purchase costs are distinct from customer offers. The detailed view retains all eight references, returned SKU rows, seller snapshots and source dates.

Graded Research shows its existing daily-history evidence charts when the provider actually returns a nonempty series. Both daily charts support date/price/count inspection. Missing dates and prices remain gaps; a missing Research history is not synthesized from Opportunities summaries.

The native decoder now accepts null marketplace entries while preserving valid entries and shape bounds. Optional opportunity references and HTTPS seller links are retained. These are read-only projections; graph interactions do not request new data or save inventory or offer changes.

## Verification

The focused `market_activity` GitHub scope runs portable checks, relevant native domain/model tests and `MarketEvidenceUITests`. Native iOS compilation and gesture checks require the macOS runner; Linux portable checks do not establish those results.

For a device check after installing this build:

1. Open a card with Beta activity coverage and confirm the exact printing, language and condition.
2. Verify 30D is the initial market period. Compare units/day for 30D and 90D, then choose 365D to add annual context. Open the detailed values to compare original counts.
3. Slide horizontally across both charts. Confirm window selection, amounts and units are readable, then scroll the page vertically outside the chart.
4. For a missing sold average with a returned market average, verify the chart says market-average fallback while the sold-average field remains unavailable.
5. Expand reference values, covered SKUs, seller snapshots and source dates. Change card condition and confirm any prior inspected point clears.
6. If a Research grade has actual daily history, inspect both daily charts and change history period. For a grade with no history, verify the app shows that it was not returned.
