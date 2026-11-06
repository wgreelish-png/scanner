# Direct inventory label preparation — build 74

Label preparation uses the selected inventory sticker price without a separate
repricing or warning-approval step. The screen focuses on price, copies, style,
physical paper and the actual print preview. **Prepare Labels** replaces
Approve & Prepare Labels. **Review Details** remains optional.

An existing saved sticker price/category takes precedence, including a manual
price, individual $0, or bulk category. Printing does not apply new quote
snapshots or turn an existing individual tag into bulk when market changes.
For a new inventory lot with no saved sticker, its positive saved inventory
value uses the existing rounding and bulk rules. Unavailable or zero values
prepare a write-in label with an empty price area. A saved individual $0 also
prints an empty price area without changing its stored value.
**Print Price Changed** selects new cards and saved tags that still need labels,
not market-only proposals. It does not silently replace saved sticker prices.

Use Suggested Prices, per-card Use Suggested Price, cost/profit review panels,
pricing settings and the warning acknowledgement checkbox are removed from
printing screens. Optional edits allow a different price or copy count when
needed. An explicit Keep Existing Sticker choice still skips that requested
replacement; it is not a warning-approval requirement.

Preparation binds the chosen price to its saved revision so outdated queued
labels cannot print after a real price change. Preparing an unchanged price
leaves all saved pricing history, dates, manual flags and physical completion
receipts untouched and does not rewrite the price file. New/changed choices
save atomically before the queue is created. Only printer completion or explicit
Keep Existing Sticker records physical labeling.

Invalid nonempty prices, non-whole-dollar tags, invalid copy counts, oversized
batches, unavailable saved data and unfinished queues still need correction.
These are operational validation checks, not profit or market warning approvals.
The Print button, continuous D110-M batching, Clear Print Queue and interrupted
label checks remain. Preparing does not start printing or modify stock, actual
costs, show balances or transaction history.

## Phone checks

1. Choose inventory cards with known prices and an unknown or unfavorable cost.
   Confirm Prepare Labels works without a warning checkbox or suggested-price
   action. Check the preview and pending queue prices/copies.
2. Leave the price empty or enter 0 and prepare a write-in label. Confirm the
   logo and frame remain, with no price printed. Nonempty malformed prices,
   cents on individual tags and out-of-range copies still require correction.
3. Prepare the same price again after a completed job. Saved label history must
   remain intact until the replacement physically completes.
4. With an unfinished saved queue, review or clear it explicitly before
   preparation. Existing pending/uncertain work must never be overwritten.

## Validation

Implementation completes before checks. Native cases cover saved-price handling
and atomic, revision-preserving preparation. UI coverage checks direct known-price
preparation without suggestions/approvals, optional editing, validation and
unchanged inventory/balances. Native execution and physical output require
Xcode and the phone. Portable checks passed grammar parsing for all 192 Swift
files, Xcode source/resource membership, build 74 property-list metadata and
`git diff --check`.
