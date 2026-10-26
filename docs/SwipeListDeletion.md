# Build 9: reliable swipe-to-delete

The old swipe button used a destructive role before deletion was confirmed. SwiftUI could animate the row away while the app was still trying to present its confirmation dialog, producing the reported disappear-and-return behavior. Persistence tests alone did not exercise that UI transition.

Swipe-to-delete and the full-swipe gesture remain available. The swipe button is red without a destructive role, and opens a separate confirmation sheet holding the list's UUID/name/count as values. The row is removed only after explicit confirmation and a successful save. Cancel or dismiss leaves it intact. A failed delete keeps the sheet open with an error and Retry Delete; repeat taps cannot commit twice.

Confirmation resolves the target afresh by UUID. Deletion keeps the existing cascade behavior and preserves saved offer estimates/session history. Other lists, physical card order, signing configuration, migrations and scanner behavior are unchanged. Build 9 includes the previously pushed startup recovery and top-loader diagnostic work.

Diagnostic events now distinguish `list.delete_requested`, `list.delete_presented`, `list.delete_confirmed`, `list.delete_cancelled` and `list.delete_dismissed`, in addition to persistence success/failure. Names and card contents do not enter these events. Fetch errors now reach the deletion failure logger too.

## Validation

Six added native coordinator regressions cover no deletion before confirmation, cancellation/dismissal, stable UUID targeting, repeated/reentrant confirmation, already-absent targets and failed-save rollback/retry across a disk reopen while preserving other cards and estimates. The new UI test uses the ordinary app screens to create two lists, swipe/cancel, relaunch, full-swipe/confirm and relaunch again to verify the target stays deleted and the other list remains.

[macOS CI at `df047b3`](https://github.com/wgreelish-png/scanner/actions/runs/40390918546) passed all 130 native tests, the end-to-end simulator UI test and the unsigned Personal Release iPhone build. The 69 JavaScript tests, 20 Python tests, source/resource membership, 34 Swift files and all 47 pinned runtime assets also passed. Physical iPhone swipe/sheet acceptance remains a later device check. Install over the existing app with the same signing configuration; deleting/reinstalling the app is unnecessary.
