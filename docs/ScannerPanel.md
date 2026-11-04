# Collapsible scanner details — build 56

The scanner footer has a 44-point up/down arrow beside the scanned-card count
and market total. Minimize hides last-card metadata and detailed guidance.
Totals, the unpriced/partial warning, next-card readiness, Undo Last Add,
Add Another Copy, manual search, View List and Finish remain in the footer
under their existing availability rules. Pause and scanner options remain in
the header. Compact action labels retain their full accessibility names.

The layout preference is saved for subsequent sessions. The transition respects
Reduce Motion; larger text stacks the navigation controls. Toggling only changes
footer content and layout. It does not replace the camera WebView/provider,
reset recognition, release a held result or save a card. Finish confirmation and
all existing action guards remain unchanged.

Implementation finishes before validation. The existing scanner UI scenario
now checks collapse/expand, retained totals and visible manual/list controls
before Mock is explicitly selected, avoiding a race with its sample timer.
Its existing confirmation, Undo/copy availability and persisted export checks
remain. Physical camera behavior is reported separately from local checks.

Local checks passed for changed Swift grammar, Xcode source/target membership,
build-56/foreground-only metadata and whitespace. The extended UI scenario has
not executed in this Linux workspace. Xcode CI and physical-iPhone validation
remain pending after push, without waiting for queued simulator jobs.
