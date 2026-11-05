# Buffered label printing — build 73

The earlier batch task declared one job but waited for each physical label to
finish before uploading the next. That wait caused stop-start output. D110-M
printing now keeps a bounded window of label groups supplied to the printer.
There is no physical-completion wait between the first two groups or before
refilling a freed group slot.

Identical consecutive rasters use the documented firmware quantity in the
6-byte/13-byte page-size request. For example, eight identical $1 labels send
the image once with a copy count of eight. Different artwork is kept in its
original order. A group has at most eight copies, and at most two groups are
unconfirmed at once. The total declared job count remains the requested number
of physical copies, with one final PrintEnd. No extra labels are added.

This uses the pinned NIIMBOT protocol reference from
[inventory label printing](InventoryLabelPrinting.md). The successful build-72
acknowledged Bluetooth write path, packet pacing and supported 96-dot geometry
remain. It does not restore the mixed unacknowledged-row optimization. Standard
D110 models retain the existing per-label method; a verified D110-M shows
**Continuous batch ready** in printer settings.

For multi-label D110-M jobs, page-start, page-size and page-end replies use the
reference's ten-second per-packet timeout, allowing firmware backpressure.
Single-label and legacy requests keep their existing deadlines. The reference
does not specify a firmware buffer capacity; the two-group limit is the app's
bounded submission window and still requires the phone check below.

Each group's full set of copies is atomically saved as sending before any
physical command for that group. Cumulative printer counters confirm ordered
prefixes, potentially several copies from both groups together. All newly
confirmed entries are saved in one atomic update before further upload. Every
single-copy receipt remains independently visible in the queue.

Pause stops new submissions immediately. The printer may finish labels already
buffered. Confirmed copies stay completed; all other handed-off copies become
Check label after an interrupted connection, including up to 16 unconfirmed
copies. Future unsubmitted copies stay pending. Reload, reconnect and retry
never restart a job automatically. Check physical output before selecting only
the copies that need another print.

Failed group-marker saves send none of that group. Failed completion saves
retain all observed completed entries in memory and block further work; durable
sending markers protect recovery. Task/session guards reject stale callbacks,
and Stop or cancellation does not discard an already received cumulative
completion proof. Approval, label-count, pricing and inventory rules are
unchanged. New submission and physical progress each refresh the bounded job
deadline so long, healthy batches can continue.

## Phone checks

1. Print three identical $1 labels, then eight. Confirm the printer produces
   the exact quantity as a continuous run, with one completed entry per copy.
2. Print more than eight copies, then a batch with several prices. Check the
   feed between groups, requested order, quantity and final feed. Actual speed
   remains subject to the printer's firmware and acknowledged transfer rate.
3. Print a single label and check that its output is unchanged. Its command
   bytes and order match the earlier one-label workflow.
4. Pause or power off during a larger batch. Inspect buffered output and retry
   only copies still needed. Completed entries must stay completed, and pending
   future copies must not become automatic retries.

## Validation

All implementation completes before checks. Eleven new protocol cases cover
quantity grouping, the bounded window, partial/cross-group physical counters,
single-label wire compatibility, legacy fallback, failures and cancellation.
Fifteen queue cases cover durable grouped markers, cumulative receipts, storage
failures, stale callbacks, approval rejection and interrupted recovery. Native
execution and physical D110-M timing require Xcode and the phone. Portable
checks passed grammar parsing for all 192 Swift files, Xcode source/resource
membership, build 73 property-list metadata and `git diff --check`.
