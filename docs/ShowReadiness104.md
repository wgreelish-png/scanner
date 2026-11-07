# Show readiness — build 104

Revision: `show-list-inventory-queue-fixes`.

## Diagnostic 20 findings

The report is from build 102, before build 103's workload reduction. It contains
seven print jobs with 22 of 22 labels confirmed, including six custom batches
totalling 19 labels. Each job reaches its final print-end acknowledgement. The
latest custom label finished November 6 at 10:29:57 p.m. Eastern. There is no
transport failure or uncertain output in those jobs. Queue cleanup was not
logged, so successful physical output did not establish successful navigation
or removal of completed custom entries.

The loaded roll repeatedly resolves to product `03032380`, 30 × 12 mm. All 82
health samples report zero memory warnings and heartbeat-lag counts. The older
retained scan run includes the previously investigated heat event; the fresh
print-only run stays nominal. These native samples exclude WebKit and camera
work. One local scanner connection failure recovers in 14 ms. Five market
activity requests fail while card pricing succeeds; a missing activity response
must remain unavailable rather than a fabricated price/history.

There are no working-stock acquisition commits in this report. Scan/manual
`inventory.insert` events mean additions to a scanned list, not to show stock.

## Changes

- Confirmed custom labels are removed after successful progress dismissal.
  Cleanup matches the exact completed job, preserves unrelated/inventory
  receipts, and keeps failed or uncertain output for review. A save failure
  retains the completed receipts rather than inviting a duplicate print.
- The saved-list Cards screen has a search field in its fixed summary. Filtering
  searches the existing list; the toolbar magnifier still opens Search & Add.
  Clear restores the list, and Cards/Offer switches preserve the query.
- Add to Inventory is for cards already owned. It preserves every physical
  source row as a separate local stock lot, with unknown acquisition cost.
  No purchase, trade, show payment, offer result or zero-cost assumption is made.
  The list stays intact. Repeated adds skip exact rows already imported, even
  after sale, relaunch or website adoption. New scan rows can be added later.
  Changing an already-added row requires review instead of silently adding it
  twice. A list cannot also be recorded as a purchase after owned-stock intake.
- Owned-stock intake participates in the existing audited inventory/cost ledger.
  Merge preserves its unmatched stock and can adopt matching copies when website
  counts grow; Replace remains the explicit website-source-of-truth operation.
  Version 6 reads existing versions 1–5 without rewriting on load, and requires
  its new acquisition journal when saving. Failed writes publish no partial stock.

## Phone checks before the show

1. Print a custom tag, including multiple copies. After progress closes, verify
   the queue is empty and a new custom price can be prepared immediately. Repeat
   with a bulk and blank-price label. Restart once to check durable cleanup.
2. Disconnect or cancel during a separate test print. Confirm uncertain/failed
   entries remain available for review and nothing prints again automatically.
3. Open a long saved list on Cards, scroll down, and use the fixed search field.
   Clear it and switch Cards/Offer to check search, scrolling and fixed actions.
4. Scan or manually add cards already owned into a small new list. Use Add to
   Inventory, check the count and exact game/printing/condition/language, and
   verify the original list and show cash are unchanged. View Inventory opens
   All Games for that visit so a previous filter cannot hide the new stock;
   the saved game preference remains intact.
5. Relaunch and revisit that list. Existing rows must not be added twice. Add a
   new scan row, import it once, and verify only the new copies enter inventory.
6. On a copy of test data, check sale/undo and Merge versus Replace. Unknown cost
   must stay unknown until explicitly set; printer history must stay attached to
   the exact inventory lot.
7. Exercise scanning/manual return normally on build 104, which includes build
   103's workload changes. Export diagnostics after the session for workload,
   thermal state, queue-cleanup and acquisition results. Do not intentionally
   heat the phone to test the protection threshold.

Native iPhone compilation, simulator suites and physical printing remain
separate from portable checks. GitHub checks start after implementation; their
results are not inferred from a queued workflow.

## Local validation

Passed: 182 app JavaScript tests, 59 research-server tests, 49 Postman tests and
42 Python tooling tests (332 total), both scalar/SIMD OpenCV smoke tests, the 47
pinned recognition assets, Swift grammar for 215 files, Xcode source membership,
workflow/test selectors, plist metadata, shell syntax and whitespace checks.
Printer transport, image rendering and saved transfer preferences are unchanged.

The `show_readiness` dispatch runs 13 focused native classes and three UI
regressions for custom printing, long-list lookup and owned-stock intake. Normal
pushes retain the complete existing iOS matrix and Release build. These iOS
results and the physical-phone checks remain pending until executed.
