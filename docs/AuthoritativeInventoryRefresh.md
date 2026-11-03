# Website-authoritative inventory refresh — build 44

An explicit Card Show import now reconciles available working stock to the website’s current quantities. It no longer stops after refreshing the read-only source list. Opening inventory does not download or reapply an acknowledged snapshot.

The supplied November 3 diagnostic contains three successful downloads of **74 rows / 80 physical cards**. Working inventory was seeded from an earlier **80 rows / 86 physical cards** snapshot and never refreshed. Build 44 fixes that handoff. Source rows, physical quantities and acquisition lots are separate counts: several copies can occupy a row, and financial lots can retain separate cost histories.

## Data preservation

- Exact game/product/SKU/printing/language/condition groups are reconciled to the complete website snapshot, including removing available copies absent from the website. Local transactions are not uploaded; bring the website up to date before importing again.
- Existing lot identities, immutable card/receipt snapshots, known acquisition costs, tag approvals, show cash and saved profits are retained. Excess copies are removed from unknown-cost lots first, then newer lots. Sold-out/removed lots remain archived in history. Additions become separate unknown-cost lots; they do not dilute a known-cost lot.
- Import differences are audited stock adjustments, not sales, expenses or realized profits. Imports do not change the cash budget. Undo of an older transaction is blocked if a later import changed that same complete card group, preventing the restored transaction from duplicating imported stock. Unchanged or unrelated imports do not block Undo.
- Financial schema 5 preserves v1–v4 migration and requires a valid reconciliation journal. An established legacy source snapshot is not automatically used to overwrite inventory on upgrade; perform a fresh explicit Refresh Inventory.

## Interrupted updates

The complete source rows and a new pending snapshot token commit together in SwiftData. The financial store atomically reconciles and records that token, then the source marks it acknowledged. Repeating a token never reapplies its quantities, even after subsequent local sales. A failed financial save or acknowledgement leaves a visible **Retry Inventory Update** action that uses the saved download. Reloading the durable financial file before retry handles a write that completed before its caller reported failure.

The importer rejects late downloads when the source snapshot or working stock changed during the request. Pending first-time updates also check the working revision so a later sale cannot be undone by an old downloaded snapshot; a fresh website refresh is required instead. Sign-in, incomplete downloads, cancellation, invalid responses and dirty draft contexts do not replace stock. Removing the imported source list still preserves working stock and history.

## Validation and phone acceptance

Tests are authored for quantity replacement, immutable history/costs, schema migration, exact SKU groups, failed writes, pending handoffs, token deduplication, local activity during download and safe Undo. The existing import UI fixture now checks both source and working quantities. All implementation completes before checks run; execution results are recorded separately.

Local verification after implementation passed Swift grammar parsing for all 171 files, correct Xcode membership for 96 app / 62 native-test / 13 UI-test sources, all 47 pinned scanner assets and dependency closure, build-44 metadata, portrait/foreground-only configuration and whitespace checks. These are structural checks, not native execution. This Linux workspace has no Xcode; native/UI tests and the Release iPhone build use the existing GitHub workflow. The JavaScript and Python code is unchanged and its suites are not rerun locally for this Swift-only fix.

Install build 44 over the existing app using the same signing team and bundle ID. Open Show → Inventory → Source, tap Refresh Inventory and verify **74 rows / 80 physical cards** if the website snapshot is unchanged. Open working inventory and check **80 cards available**. Reopen and relaunch to ensure it remains 80. Record and undo a small sale before any further refresh; check stock, cost and budget once. Try a failed/offline refresh: existing stock should remain usable. A fresh successful website refresh deliberately replaces local quantities with current website quantities. This requires iPhone validation; source/grammar checks alone cannot establish the behavior.
