# Label approval and queue controls — build 70

**Label Details → Approve & Prepare Labels** now saves the approved batch and
opens the queue directly. The previous full review screen is available through
**Review Details**; it is no longer a required stop. Price, cost and profit
warnings appear on Label Details and still require one explicit acknowledgement
when present. Editing a price or selecting a different batch resets that
acknowledgement. Multi-card configuration and optional reviews keep individual
details collapsed. Approval does not start printing.

Approval and explicit “Keep Existing Sticker” confirmations save together in
one atomic update. Existing approval revisions, market baselines, manual prices
and physical completion receipts retain their established meaning. Approval
alone no longer renders a batch that cannot replace an existing saved queue,
and queue preparation uses the raster directly without creating unused preview
images.

**Clear Print Queue** stays in the toolbar on Price Tags, inventory selection,
Label Details, optional review, individual/batch price editors, Custom Price Tag,
printer/pricing settings, the queue, its preview and retry review. It requires one destructive
confirmation and is disabled during printing or printer configuration. It can
also discard an unreadable saved queue. It clears saved print work and progress,
preserving inventory, costs, approved prices and financial records. Draft fields
stay intact. Check uncertain physical labels before preparing another batch.

Printed Card Details titles remove an exact duplicate card code from the source
name before appending the canonical code once. The supplied photo's
`Battle Cage - 116/094 · #116/094` becomes `Battle Cage · #116/094`.
Code boundaries, case differences and metadata wrappers are handled
conservatively; meaningful name numbers and larger-code substrings are retained.
This is display-only. Source card names, inventory and saved queues are not
rewritten. Prepare old queued labels again to apply the new artwork.

## Phone checks

1. Prepare Battle Cage with name `Battle Cage - 116/094` and card code `116/094`.
   Confirm the preview and a newly printed label show the code once. Check a
   normal name and a name with meaningful numbers as well.
2. Open Print All or Choose Inventory Cards. On Label Details, acknowledge any
   displayed warnings, then tap Approve & Prepare Labels. The queue should open
   without another review page or automatic printing. Review Details remains
   available before approval.
3. Prepare labels, return to Price Tags and cancel Clear Print Queue once to
   keep them. Confirm the action to remove them. Repeat from Custom Price Tag,
   an edit sheet and queued preview. Inventory and balances must stay unchanged.
4. While printing, queue clearing must be disabled. After stopping, check any
   uncertain physical output before clearing and preparing another batch.

## Validation

All implementation completes before checks. Native cases cover exact code
deduplication, false-positive boundaries, unchanged raster-only output, and
combined atomic approval/sticker saves. UI cases cover direct approval with
warning gating, clearing from multiple entry points, cancellation, draft and
inventory preservation, and relaunch. Native/UI execution and physical output
require Xcode and the phone. Portable checks passed grammar parsing for all 192
Swift files, Xcode source/resource membership, build 70 property-list metadata
and `git diff --check`; these checks are not native test execution.
