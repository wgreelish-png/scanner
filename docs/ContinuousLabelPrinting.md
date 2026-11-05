# Continuous label printing — build 69

Build 72 supersedes the unacknowledged-row transfer optimization described
below: [print transfer recovery](PrintTransferRecovery.md) restores the verified
acknowledged D110-M write path while keeping continuous print tasks.

Opening **Show → Price Tags** now starts foreground printer discovery. The first
visit shows nearby D110/D110-M printers for selection. Later visits connect only
to the last peripheral that completed model/head/protocol verification. Bluetooth
permission is requested from this entry point if needed. Scanning stops after
15 seconds; Search remains available. There is no background connection or
automatic printing, and no arbitrary nearby printer is selected automatically.

The last physical size chosen in inventory or custom labels is remembered for
both preparation screens, including after relaunch. Supported sizes remain
30 × 14, 40 × 12 and 50 × 14 mm. The “Last used” caption asks you to check the
loaded roll. Saved queue dimensions/rasters remain unchanged when this
preference changes. Gap/Transparent remains separate. The current D110-M
reference does not establish reliable physical-roll detection; print-head width
alone cannot identify a roll, so no additional printer query is sent.

The supplied diagnostic file 12 shows build 68 successfully identifying model
2320, protocol 4, then completing physical labels. It does not record per-label
start or transfer timings. Previously each copy started and ended a separate
printer task. Supported D110-M generations now declare the batch count once,
send pages within that task and end it once. One-way bitmap packets use
CoreBluetooth's unacknowledged writes with transmit backpressure and the pinned
reference's 10 ms packet spacing. Control commands keep acknowledged writes
where supported. The older standard D110 retains its established workflow.

Each page is still saved as sending before its first physical command. The app
checks the bounded cumulative physical completion counter at a 300 ms cadence,
then durably saves that copy before sending the next. At most one copy can be
unconfirmed; Stop, disconnect, changed approvals and storage errors stop further
sends. Finished labels retain their receipts, future copies stay pending and
uncertain output requires explicit review before retrying. There is no unsafe
multi-page buffering or automatic retry. Per-page start/completion diagnostics
contain only indices, totals and elapsed milliseconds.

The packet layout and transport follow the pinned MIT reference documented in
[inventory label printing](InventoryLabelPrinting.md). No reference scripts are
executed or shipped as a runtime dependency. Inventory quantities, costs, show
balances, approvals and existing saved queue formats are unchanged.

## Phone checks

1. Turn on the printer, release it from the NIIMBOT app and open Price Tags.
   Select it once; leave and reopen to check automatic reconnection. Opening
   the page must never print a saved job.
2. Choose 40 × 12 mm for custom labels, prepare three copies and print them.
   Check the pause/feed between copies and compare with the previous build.
   Check alignment and the final feed. Physical timing is not yet verified.
3. Choose a different size for a new batch. Confirm the previous saved queue
   keeps its original size, and the new choice appears in both custom and
   inventory preparation after relaunch.
4. Stop or power off mid-batch. Completed copies must stay completed, only the
   active unconfirmed copy may need checking, and future copies stay pending.
   Reopening/reconnecting must not resume printing.

## Validation

All implementation was completed before checks. Twenty-four new native cases cover
declared-count M tasks, bounded counters, all-page preflight, durable ordering,
partial failures, cancellation, stale callbacks, recovery and remembered-size
preferences. An offline UI case covers shared size selection, saved queue
dimensions and relaunch. Offline fixtures explicitly disable Bluetooth
auto-connect. Portable checks passed Swift grammar parsing for all 192 files,
Xcode source/resource membership, build 69 property-list metadata and
`git diff --check`. Native/UI execution and physical D110-M speed require Xcode
and the phone; this Linux workspace cannot establish those results.
