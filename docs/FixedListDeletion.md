# Fixed list-delete confirmation — build 63

The multi-select confirmation keeps Delete Selected Lists in a bottom safe-area
bar while the selected list names scroll independently. Cancel stays in the
navigation toolbar. The same pattern now applies to single-list deletion.

Retry Delete and failure messages stay in the fixed bar, so a failed attempt
does not bury the explanation or retry action among the selected rows. The bar
reserves scrolling space above it, respects the home indicator, and uses a
full-width button with a 44-point minimum target and wrapping text. Larger
Dynamic Type can increase its height without moving it into the list content.

The confirmation snapshots, explicit confirmation requirement, atomic delete,
retry/duplicate-tap guards and Cancel behavior are preserved. No lists are
removed merely by opening, scrolling or dismissing confirmation. Session
history, saved offers and recorded financial transactions retain their existing
protection. Only synthetic debug fixtures add a long list of test names.

A long-selection UI regression verifies that rows move while the confirmation
button retains its position and remains hittable, then cancels and verifies all
lists remain. The existing selected-only delete scenario is retained.
Implementation completes before local checks. Native/UI execution and physical
iPhone confirmation remain pending when Xcode is unavailable; queued CI jobs
are not awaited after push.

Local checks passed for all 192 Swift source grammars, source/target membership,
build-63 revision metadata and whitespace. The new UI regression has not run
in this Linux workspace. Xcode CI and iPhone checks at normal and larger text
sizes remain pending after push.
