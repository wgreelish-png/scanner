# Final sticker pricing — build 43

The existing label selection, editor, review, renderer and print queue now share one set of pricing calculations. Printing remains an explicit foreground action. Scanner recognition, inventory quantities, import reconciliation and financial receipt validation are outside this change.

## Final sticker tiers

| Current saved market | Proposed sticker/category |
| --- | --- |
| Below $0.75, including a known $0 | **2 for $1** bulk category; no individual tag |
| $0.75–$0.99 | **$1** |
| $1–$99.99 | Round down to a whole dollar |
| $100+ | Round down to a multiple of $5 |

Examples: $0.74 → bulk; $0.75 → $1; $1.85 → $1; $8.40 → $8; $48.50 → $48; $113 → $110; $199 → $195; $347 → $345; $589 → $585. Individual tag generation rejects cents, including manual cents entries. Unknown market is not zero. A low-priced card whose promotional price fails its profit check remains a review item; the app never raises its price automatically to cover costs.

## Approval and repricing

Approved stickers are separate from current market quotes and immutable purchase/sale snapshots. Existing approved prices and manual overrides remain selected until an explicit **Use Suggested Price** or manual edit. Approving saves the new market baseline even when retaining the same sticker. Imports and opening the screen do not move that baseline, so market changes accumulate across refreshes.

| Market at last approval | Decrease | Increase |
| --- | --- | --- |
| Under $5 | Greater of $0.25 or 10% | Greater of $0.50 or 20% |
| $5–$19.99 | Greater of $0.50 or 5% | Greater of $1 or 10% |
| $20+ | Greater of $1 or 5%, capped at $25 | Greater of $2 or 10%, capped at $25 |

Threshold equality triggers review. Fractional-cent thresholds round upward. Separately, a positive approved sticker premium of at least 10% below $5, 8% from $5 to $19.99, or 5% at $20+ is flagged as overpriced. These flags request review and never force a price reduction. Selected review rows prioritize overpriced cards and decreases ahead of increases.

Pricing uses matching quotes from the existing saved source import when available, keyed by product/game/printing/language/condition and exact SKU where possible. A newer saved card quote takes precedence over an older import. A newer missing or conflicting quote stays unavailable rather than silently inheriting an old quote. Working stock and receipt card snapshots are not rewritten.

## Costs and reasonable offers

**Pricing Settings** inside the existing label flow configures minimum desired profit per copy, allocated selling expenses, fixed payment fee and percentage payment fee. Fees default to cash (zero); the preferred profit amount is initially unset. The user can explicitly enter $0 for a break-even target. Missing acquisition cost and an unset preferred target remain unknown and require manual review; neither silently becomes zero.

The minimum gross price is:

`(actual acquisition cost + allocated expenses + desired profit + fixed payment fee) / (1 − percentage payment fee)`

Break-even uses zero desired profit; the preferred floor uses the configured profit amount. Results round up to cents. Per-copy costs follow the ledger's actual selected-copy remainder allocation. The price disclosure shows the proposed sticker, break-even, preferred minimum and suggested offer.

Negotiation targets remain 0–5% below $5, 5% from $5 to $19.99, 5–8% from $20 to $99.99 and 5–10% at $100+. Default targets are 2.5%, 5%, 6.5% and 7.5%. Offers use convenient increments when these fit the discount range and preferred floor; otherwise they retain a valid cent amount or the sticker. Offer amounts may contain cents; individual printed stickers do not. No automatic offer goes below the preferred floor. A manual price can be approved after explicitly acknowledging its cost/profit warning.

## Bundles

The 2 for $1 category is assessed as complete selected pairs. Optional 2 × $5 for $9 and 3 × $5 for $13 promotions can be enabled in Pricing Settings. Reviews show the proposed charge, savings where an individual reference exists, profit floors, exclusions and warnings. Exact selected groups are checked together; unsafe or unknown-cost groups are excluded from automatic eligibility instead of assuming free inventory. Fixed payment fees apply once per payment, and percentage fees apply to the whole charge. Promotion stacking defaults off.

These previews do not record a sale. Existing checkout still records the actual amount received. Approved individual stickers become checkout defaults immediately, with exact per-row allocations. Approved bulk pairs become a default only when the complete group passes its margin checks; an odd or unverified group requires an explicit actual cash amount. Historical market-rounding and receipt math remain intact, preserving old sales, profit, cash splits and Undo.

## Labels and durability

Approval and print history live in the separate bounded, versioned `tag-approvals.json` file, with atomic writes and fixture-isolated test storage. Only approved individual prices that still need labels enter the existing queue; bulk cards do not generate individual labels. **Keep Existing Sticker** explicitly records that the physical sticker already matches. Approving an unchanged retained tag resets its market baseline without reprinting it.

A price revision changes only when its approved tag changes. Completed labels must match that revision before clearing Needs Labels, so an old $10 queue cannot acknowledge a later $10 → $12 → $10 cycle. Before sending each queued copy, the app rejects an outdated price/revision rather than printing it. All matching copies in the queued group must complete. Clearing the queue does not erase approvals/history. Legacy queued rasters and manual prices remain immutable, including pre-update cents labels; new cents tags cannot be generated.

Failed approval writes preserve the saved baseline. Price review can be approved while an older queue waits; that queue must be reviewed/cleared before preparing replacements, and obsolete labels cannot be sent. If approval succeeds but preparing the queue fails, approved prices remain active and Needs Labels remains for retry. No operation automatically prints. Existing queue recovery, explicit uncertain-output acknowledgement and foreground-only Bluetooth behavior are retained.

## Verification

All implementation completes before checks. Focused native tests cover every supplied sticker example, exact boundaries, asymmetrical/capped movement thresholds, competitiveness, cumulative baselines, whole-dollar/manual/bulk behavior, unknown versus zero costs, fee formulas, cent-safe floors, offer ranges, bundle fees/eligibility/stacking, approval failures/relaunch, revision-safe label acknowledgment, current import quote matching, immediate checkout prices and historical receipt/Undo preservation. UI tests cover whole-dollar edits, cents rejection, warning review, bulk exclusion and retaining a sticker without reprinting. Native/Xcode and physical-iPhone results remain separate from grammar/resource checks.

Local verification passed grammar parsing of **168 Swift files**, Xcode membership for **95 app / 60 native-test / 13 UI-test sources**, bundled-resource membership, all **47 pinned scanner assets/dependencies**, build/permission/privacy metadata and whitespace checks. JavaScript and Python implementations are unchanged and their suites were not rerun locally. This Linux workspace has no Swift/Xcode installation; native/UI test execution and iPhone acceptance remain separate from these portable checks.
