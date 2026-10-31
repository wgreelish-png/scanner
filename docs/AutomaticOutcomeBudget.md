# Automatic outcome cash and show dates

Build 32 uses the calculated cash automatically when an outcome is explicitly recorded in list review. It does not require a second Record Cash action or a confirmation of a custom amount.

| Outcome | Budget effect |
| --- | --- |
| Purchase | Subtract the full calculated cash offer, including per-card overrides and normal cent rounding. |
| Trade + Purchase | Use the valid Trade + Cash calculation: subtract cash paid to the customer or allocate cash received from the customer. |
| Trade | No cash movement. |
| Nothing Happened / Clear List Outcome | Remove this list's previous automatic contribution. |

Gross cash received still splits 65% toward buying and 35% saved, using the show's saved reinvestment rate. Prices, quantities and percentage edits alone do not post money; recording the outcome is the posting action. Repeated identical actions reuse the original contribution. A changed outcome updates the existing automatic contribution rather than adding another full payment. Manual receipts are retained and a conflicting manual cash receipt prevents a second automatic charge. Partial/unpriced lots cannot silently post known-only values as actual cash. Trade + Purchase requires My Card Price and a valid Trade + Cash result; empty lists may still record zero-cash status labels.

An applicable selected show budget is required for new cash. Scheduled shows apply only on their inclusive local start/end dates, including multi-day ranges. Future/ended shows stay available for review and editing, with new cash controls disabled. Undated legacy budgets remain manually applicable. Actual write-time date checks protect an old open form crossing midnight. Corrections/voids and exact already-committed retries remain possible outside the original dates. A changed cash amount cannot silently move an old list's receipt from one show to another.

Without an applicable show, a new outcome may be recorded as status-only, with a message that no funds changed. Opening the app on a later date never posts that old cash automatically. If replacing existing automatic cash cannot find an applicable show, the existing receipt is retained. Choose the intended show and record the correction deliberately.

## Durable saves

The financial JSON file commits both the cash change and a pending desired list outcome atomically. SwiftData then mirrors the outcome; acknowledgment follows only after that save succeeds. An interruption or list-save failure leaves a visible pending sync that retries on app/list foreground or through Retry Outcome Sync. Recovery only mirrors/acknowledges the saved operation and never posts its cash again. Deleting a list does not recreate it during recovery or reverse actual cash already spent/received.

Budget format v2 adds the durable outcome journal and automatic-entry markers. Existing v1 files migrate in memory and are saved as v2 only on the next explicit write. Entries, prior splits, dates and manual receipts remain intact. Older app versions reject the new financial format rather than dropping its journal on rewrite. SwiftData remains on its existing schema; no inventory migration is added for this feature.

## Navigation and deletion

**Show** is a dedicated bottom tab for show selection, dates, budget and cash history. Lists and Scan no longer share a budget navigation route. **Open Existing List** always goes to **My Lists**, while ordinary tab switches keep their current navigation depth.

In Lists, choose **Select**, select individual lists or **Select All** for visible results, then **Delete Selected**. One confirmation shows counts before deleting. The operation commits all resolved selected IDs in one save, retaining sessions, saved offers and financial receipts. Failed deletion keeps the selection for retry. Imported inventory deletion removes only the local copy. Individual swipe deletion remains available outside selection mode.

## Verification

Native cases cover local date boundaries/DST, scheduled/undated budgets, calculated cash mapping, gross allocation, repeated taps, corrections, no-show behavior, manual conflicts, partial valuations, cross-show protection, financial/list/ack failures and recovery across reopening. Bulk deletion cases cover multiple IDs, missing IDs, history, rollback/retry and unrelated drafts. UI checks cover the Show tab, explicit list navigation, schedule status and selection/deletion. All implementation finishes before checks run.

On iPhone, test a future show, today's show and an ended show; record a priced Purchase and Trade + Purchase and compare Show balances; record Nothing Happened and verify reversal; tap/reopen repeatedly and check for duplicates. Change tabs, leave Show on a nested page, and use Open Existing List. Select/cancel/delete several disposable lists and verify other lists, historical receipts and swipe deletion remain intact. Offline budget use needs no market API call. Inventory import remains unresolved until the precise rejection events from the latest build are provided.

After implementation completed, local checks passed 27 Python helpers, grammar parsing of 131 Swift files, target membership for 74 app/46 native-test/11 UI-test files, all 47 pinned recognition assets and shell/whitespace checks. The native financial/migration/recovery cases and UI cases are assigned to the existing macOS CI jobs; no simulator job was added. Xcode and physical-device outcomes must be reported separately from these Linux checks.
