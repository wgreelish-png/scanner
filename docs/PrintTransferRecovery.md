# Printer transfer recovery — build 72

Diagnostic file 13 identifies build 71 and the D110-M (model 2320, protocol 4).
Connection and identity checks succeed. A one-label job and two three-label
attempts then time out about five seconds after the first page's write-ahead
marker. No page-completion receipt is present. The marker is recorded before
print initialization, so it does not establish which command timed out.

The one-label protocol bytes and order match successful build 68. The shared
transport difference is build 69's switch to unacknowledged image rows while
control commands remained acknowledged. Build 72 restores one negotiated write
type for every packet: the verified D110-M uses acknowledged writes for both
rows and controls. The existing response/acknowledgement gates, chunk size and
packet spacing remain. The mixed-mode optimization is removed;
the log cannot prove it was the exact failed command. Continuous declared-count
jobs, current label artwork and one durable receipt per physical copy remain.

Print control requests now record fixed stage/opcode, expected reply, write mode
and bounded byte/notification counts while connected. Failures capture the
pending request before teardown. They no longer lose this context merely because
the printer was already connected. Per-row success events are omitted; payloads,
label contents, prices, advertised names and device IDs are never logged.

The selected-card queue issue is separate. **Choose Inventory Cards** and a
single card's **Print Price Tag** now treat explicit selection as a request for
the chosen copies, including replacement stickers for already-labeled cards.
Only **Print Price Changed** automatically skips unchanged, already-labeled
stickers. Explicit Keep Existing Sticker, bulk exclusions, price/copy validation,
warnings and approval checks remain. A loaded, fully completed queue can be
replaced by an explicit new preparation. Pending, failed or uncertain jobs still
require review/clearing and are never silently overwritten.

There is no automatic retry of a dispatched label. Check physical output before
retrying any entry marked Check label. New preparation and reconnection still
require a separate Print action.

## Phone checks

1. Reconnect the D110-M and explicitly print one label. Confirm physical output
   and a completed receipt, then try three copies in a continuous job.
2. Select a previously labeled inventory card and prepare one replacement.
   Confirm it reaches the pending queue. Repeat after completing the prior job.
3. Confirm Price Changed still skips unchanged labeled stickers, and Keep
   Existing Sticker explicitly skips the selected replacement.
4. Stop or disconnect during a job. Check any uncertain physical output before
   retrying; completed copies stay completed and future copies stay pending.

## Validation

Implementation completes before checks. Native regression cases cover explicit
selection versus automatic repricing, retention/exclusions and copies; UI
coverage reselects a previously acknowledged sticker across relaunch and checks
the pending replacement with unchanged inventory/balances. Structured diagnostic
export coverage includes connected-print failure fields. Existing durable queue
cases cover explicit replacement of completed work and interrupted-job recovery.
Portable checks passed Swift grammar parsing for all 192 files, Xcode
source/resource membership, build 72 property-list metadata and
`git diff --check`. Native execution and physical D110-M output require Xcode
and the phone.
