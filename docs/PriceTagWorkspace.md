# Show Price Tags — build 50

The dedicated Show page has three entry points: Print All, Print Price Changed,
and Custom Price Tags. All/changed batches bypass individual selection and use
available stock quantities. Custom batches keep search and selection and add
Select All Results, Clear and a shared whole-dollar price editor. Draft edits
never change inventory, market values, costs, sales or budgets.

Changed selection uses the existing approval baseline and repricing thresholds,
includes new/unprinted stock, and preserves manual prices. Reviews still save a
new baseline only after explicit approval. Known zero and missing market prices
remain distinct. The bulk 2 for $1 category receives no individual tags.

Print All explicitly includes unchanged approved individual stickers. Other
modes suppress those reprints. The label count and actual queue generation share
one eligibility rule. Saved approval revisions still protect against printing
an outdated queue. Existing queue review/discard, interrupted-label recovery,
100-copies-per-entry and 250-label batch limits stay in force. No selection is
silently truncated. Printing still requires the separate Print Queued Labels
action and runs only while the app is open.

For larger batches the details editor starts collapsed and review uses compact
rows. Expand a card to see its actual bitmap, warnings, negotiation details and
individual editor. Actions remain pinned to the bottom, and missing prices can
be explicitly skipped without opening every card.

## Validation

All implementation completes before checks run. Native cases cover large-batch
selection, physical copy counts, threshold edges, current quote snapshots,
unknown/zero values, manual category preservation, unchanged versus explicit
reprints, profit warnings and back-navigation defaults. UI scenarios use the
new Show route and cover Print All, custom selection/shared prices, cancellation
and preserved financial/inventory values without sending Bluetooth data.

Local validation passed after implementation: all 40 portable Python helper
tests; Swift grammar for 183 files; source membership for 103 app, 66 native-test
and 14 UI-test files; all 47 pinned scanner assets/dependencies; build-50,
portrait-only and foreground-only metadata; shell syntax; and whitespace checks.
Nine new native cases and two new UI scenarios are authored and registered,
but have not executed here. Xcode/native/UI tests require macOS; CI is reported
as pending after push without waiting for a runner. Physical iPhone/D110 behavior
remains unverified here.

On the phone: open Show → Price Tags, try All and Price Changed without tapping
each row, check copy totals and loaded paper, expand a preview, and cancel. In
Custom, search, Select All Results, set one price, and confirm cost/profit
warnings still appear. Prepare a small queue, explicitly connect the D110, print
one label, then a small batch. Check unchanged-tag suppression in changed/custom
mode and explicit replacement tags in All. Confirm stock and budget never change
from label preparation/printing, and interruption never starts a retry by itself.
