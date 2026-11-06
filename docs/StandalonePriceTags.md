# Standalone Custom Price Tag — build 52

Show → Price Tags → Custom Price Tag accepts a whole-dollar price, 1–100 copies
and the loaded paper size. It previews a price-only sticker and saves it to the
existing durable queue. There is no card picker, inventory prerequisite,
pricing lookup, profit claim or approval write. Entering 0 prepares a write-in
label with an empty price area; cents are rejected under the existing
whole-dollar tag rule. Check a card's cost before applying a manually entered
sticker.

Prepare never starts Bluetooth or prints. Print Queued Labels, interrupted-copy
checks, foreground-only transport and saved-queue review/discard remain the
existing flow. Double-tapping preparation reopens the same saved job. A failed
save retains the price and copies for retry after reloading the queue; existing
queue progress is never overwritten automatically.

Custom queue entries explicitly carry source=custom, no inventory identity and
no approval revision. Priced inventory entries keep their approval checks;
write-in inventory labels have no printed price to approve or acknowledge.
Missing source remains legacy inventory. Contradictory custom identity/revision,
non-price-only style, cents and unknown source values fail validation. Completed
custom labels cannot mark an inventory sticker as printed. Existing queue files
remain readable, including legacy cents-priced snapshots.

The prior inventory selector remains under Choose Inventory Cards, with its
bulk selection, price edits, profit protection and approvals unchanged. Print
All and Print Price Changed retain their existing behavior.

## Validation

Implementation completes before checks. Native cases cover manual input,
zero/cents and copy boundaries, unchanged price-only raster output, idempotent
preparation, failed-save retry, custom queue reopening, legacy decoding, invalid
source/identity combinations and unchanged inventory approval enforcement. A UI
scenario enters $5 and three copies, previews, prepares an unstarted queue, and
checks inventory and budget remain unchanged. Xcode/native/UI execution and
physical iPhone/D110 printing are reported separately from local checks.

Local checks passed after implementation: Swift grammar for all 187 files,
target membership for 105 app / 68 native-test / 14 UI-test files, all 47 pinned
recognition assets/dependencies, build-52/portrait/foreground metadata and
whitespace. Twelve new native cases and the new UI scenario are registered;
they have not executed in this Linux workspace. Xcode CI and physical printing
remain pending after push; no simulator runner wait is required to finish.
