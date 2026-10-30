# Market evidence and sales-history charts

Build 22 adds visual evidence to **Market Details & Sales Activity** and **Research & Demand**. Open a saved list, edit a card and choose Market Details; the same destination is available from scan confirmation. Graded Research is a separate destination with its own coverage.

## Market Details

**Evidence at a glance** shows whether the public and activity services returned the same exact SKU, whether a public market quote exists, provider timestamps, the reported 30-day quantity, and whether an explicit sold average is available. A timestamp within 24 hours describes freshness, not price accuracy. Retrieval time never replaces a missing provider timestamp. An older timestamp can remain unchanged after a successful refresh.

The horizontal USD comparison chart separates market quotes, explicit 30/90-day TCGplayer sold averages and asking prices without shipping. Numeric values remain below the chart. A mismatch or unknown returned public SKU prevents mixed-source comparisons. Saved SKU IDs are not used to manufacture agreement. Both services use TCGTracking data; agreement is not an independent verification.

The sales-volume selector compares reported TCGplayer and Manapool units for 30, 90 or 365 days. These cumulative windows overlap; their quantities are never added together or turned into invented daily buckets. A returned zero is shown as zero, while unknown quantities remain unavailable. Counts are units, not necessarily independent sale-price observations.

Only the explicit `trends.windows.*.tcg_sold_avg` fields supply sold averages. Neither `pricing.avg_30d` (which can fall back to a market average), finish/product market values nor listing prices fill a missing sold value. The app does not infer a confidence percentage, demand score or guaranteed sale price.

## Graded Research

Select the exact language, full printing, grader and grade. Separate charts show daily sold averages in USD and daily recorded sales counts, with 30/90/365-calendar-day or All filters. Periods end on the current UTC day; old observations do not shift a recent window backwards. Tap or drag to inspect a reported day. The daily-values disclosure provides the latest 30 returned days in the selected period as text.

The evidence summary shows returned days, days with known prices/counts, their known sales sum and the latest returned history day. It labels the provider's 1–5 rating as a provider rating rather than a measured probability. Research remains an experimental, partial dataset. Empty recent history stays empty even when an older guide value exists.

Missing dates are not zero sales. Lines connect only consecutive known daily prices. Ambiguous duplicate dates and future-dated rows are excluded, with visible counts; unknown values stay unknown. A sum with missing day counts is explicitly partial. No daily average is promoted to an individual sale, and an all-history total is not relabeled as a 30-day total.

## Scope and checks

The charts use existing validated responses and daily caches. Changing a graph's period is local and makes no additional API call. Endpoints, request pacing, recognition, inventory storage/migrations, signing, offer math and saved price selection are unchanged. No chart writes an inventory quote or transaction.

Native fixtures cover exact-SKU comparison, unavailable/zero values, sold-field provenance, overlapping windows, timestamp validation, calendar boundaries, stale/duplicate/future history, missing-price line breaks and sum overflow. Explicit Debug-only fixture destinations support two focused UI checks for zero versus missing quantities, period selection and separate Research charts; Release excludes those fixture providers. Fixture tests do not establish live coverage or physical-iPhone behavior.

On an iPhone, compare an exact-condition SKU's numeric values with its provider response, switch all three market-volume periods, then switch graded-history periods and inspect a day. Test missing coverage and poor reception; verify that the original provider dates remain visible and that saved prices/offers stay unchanged when returning to the list. Check both normal and accessibility text sizes. Live account coverage and touch/VoiceOver presentation require this device acceptance.
