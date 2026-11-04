# Inventory selection and Merge/Replace — build 64

Show → Inventory → Record Transaction now switches the same inventory screen
into selection mode. Search and remembered sorting remain available, each lot
has a checkmark and selected quantity, and the fixed action becomes Confirm
Transaction. Clear and Cancel change only this draft selection. Confirmation
opens the existing Sale/Trade/Purchase editor with the chosen cards expanded.

Swipe Remove deletes a card only from the transaction draft. Add Cards chooses
more existing inventory, including copies removed from the draft. Selection
changes survive returning to inventory, automatic suggestions update, and
manually agreed cash stays intact. Actual quantities and funds change only
after Record Transaction succeeds; successful recording clears the selection.
Purchase-only transactions can continue without outgoing cards.

Inventory rows show TCGTracking or Acquired locally. Recorded purchases and
trades remain available in working stock until sold, traded or explicitly
replaced. Import now has two explicit modes in a fixed action bar:

- Merge is the default. It updates website-managed stock and preserves local
  acquisitions missing from TCGTracking. New matching website copies take over
  local copies without duplicating them, using exact card identity and bounded
  quantities. Existing website copies alone are not proof of a newly uploaded
  local acquisition.
- Replace explicitly confirms that all available stock should match TCGTracking
  exactly, including removing local cards absent from the website. Surviving
  matching local copies become website-managed so a later Merge does not count
  them again.

Source takeover retains the original acquisition lot and receipt as history,
transfers the adopted copies' actual remaining cost, and identifies the new
website-managed lot's original local lot. Card details can still open the
original purchase/trade receipt. Partial matches adopt only matched copies.
Source quantities, acquisition costs, transactions and cash remain distinct.

The selected import mode is captured with the pending download and survives
retry and acknowledgement. An interrupted Replace cannot silently run when a
new Merge was requested. Old imported links and reconciliation events retain
their original Replace semantics; journal replay does not rewrite historical
financial effects. Existing markers, revision guards, atomic writes, cost
validation and Undo protections remain enforced.

The first Merge after an older Replace also recognizes local copies that the
older import already counted as website stock. Only those surviving copies
are converted or retired; purchases made afterward remain local.

Old sticker approvals stay recorded. A newly adopted lot does not inherit a
live price from remaining local copies. If the old copies had approved tags,
checkout requires actual cash or an explicit approval for the new lot instead
of silently substituting a different suggested price.

This prepares provenance for future TCGTracking synchronization. Current imports
remain reads; uploading acquisitions is a future operation that must identify
acknowledged copies and avoid duplicates.

All implementation finishes before checks. Coverage includes inline selection,
draft removal/addition/cancellation, final recording and relaunch; Merge versus
Replace; later matching/partial adoption; costs, retries, legacy replay and Undo.
Native/UI execution and physical iPhone acceptance are separate from portable
source checks. Queued CI jobs are not awaited after pushing.

Validation: Swift grammar passed for all 192 Swift files, Xcode source membership
passed, build 64 metadata passed, and `git diff --check` passed. This change adds
20 native regression methods and two UI regression methods. Native compilation,
native/UI execution and phone acceptance remain pending because this Linux
workspace has no Xcode.
