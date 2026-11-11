# Build 107: bounded activity trail

Diagnostics now record screen entry/exit, important actions and readiness changes across scanning, manual add, saved lists, card research/editing, Show inventory/transactions and label printing. Printer breadcrumbs include selected/label/queue counts, preview readiness, prepare/print outcomes and fixed reasons a control cannot proceed. An exit means a screen became hidden; only an explicit button action identifies a tap. Navigation during interrupted printing remains governed by the existing printer/queue logic.

The trail is included automatically in the existing copied/exported JSONL diagnostic file while **Record diagnostics** is enabled. It does not transmit anywhere. No card or list names, identities, prices, cash amounts, notes, search text, credentials, screenshots, video or packet contents are added. This is observability only; the printer screen simplifications identified in the prior review are not part of this change.

## Size and workload

- Existing persistent storage cap stays **two files of 256 KiB each: at most 512 KiB total**, shared with other diagnostics. No separate trail database, archive or screen recording is created. Explicit Copy/Export can create a temporary report, as before.
- Memory keeps only one small snapshot per fixed screen enum, counters and timestamps. There is no growing in-memory event list, added polling timer or capture process. Serialization uses short-lived text records; actual phone memory/CPU impact still requires measurement.
- Identical readiness snapshots are suppressed. A safety budget allows at most 120 ordinary activity events per ten-second window and reports how many were suppressed on the next accepted event. Human issue markers bypass this budget. No per-frame, per-Bluetooth-packet or raw text-keystroke trail is added.
- Wall-clock timestamps correlate with existing errors and health samples. Per-run sequence numbers and monotonic uptime/gaps preserve activity ordering. A gap is time since the previous activity event, not an assertion of processing latency; it can include reading, user think time or backgrounding. Gaps above one hour are capped.
- Older events rotate out when the existing files fill. The trail is recent context, not guaranteed retention of an entire card show. Disabling diagnostics stops activity recording too; Clear Diagnostic Log removes the saved logs and resets activity context.

## Reporting an issue

Open **Settings → Diagnostics → Mark Recent Issue**, then Copy or Export Diagnostic Log soon afterward. This adds a timestamped bookmark using the last recorded content-screen snapshot. It does not automatically identify the problem screen, pin a permanent report, or send anything. If returning through another content screen changes that snapshot, the preceding trail still shows the route. Record a video separately for visual defects such as flicker or white bars.

## Validation

Focused native tests cover ordered routes/actions/readiness and monotonic timing, strict storage filtering, duplicate-state suppression, the burst budget, disabled recording, two-file rotation, issue bookmarks and Clear reset. UI instrumentation changes preserve existing action ordering and store/printing operations. Run native `ScannerDiagnosticsTests` with Xcode; the existing GitHub native `printer_transport` scope includes it and relevant printer diagnostic regressions. Linux syntax/static checks do not establish native compilation or phone overhead.

Local checks passed: all 15 changed Swift files parse, the app plist parses, Xcode source/resource membership is complete, all 47 pinned scanner assets match, whitespace checks pass, and all 46 Python helper tests pass. Seven activity regression tests are added to the native diagnostic suite; their execution and native app compilation are delegated to the focused GitHub run. No phone memory/energy benchmark or screen recording was performed here.

The shared branch's concurrent test-runner updates were merged without conflicts or dropped history. All **67** portable Python tests pass on the combined version.
