# D110-M image-write experiment — build 90

Branch: `experiment/niimbot-d110m-write-without-response`.
Base: `facaae2`, the current build 87 app. Development uses the isolated
`/workspace/scanner-d110m-experiment` worktree; the daily branch is unchanged.
The diagnostic revision is `experiment-d110m-readiness-recheck`. Build 89 fixes
initial inventory-label navigation so the preview and Prepare button use the
current selection immediately. That preparation fix applies equally to both A/B
modes and preserves the selected artwork and saved queue behavior.

This experiment changes eligible image-data transport only. Existing rendering,
row compression, native identical-copy grouping, card order, page pipelining,
two-group buffer limit, page dimensions and completion checks remain in place.
There is no packet bundling, price regrouping, image-template substitution or
automatic replay. Hardware reliability and speed are **pending**.

## Enable and disable

Build this branch in Xcode using the existing `CardShowScanner Personal` scheme
and install it on the same iPhone. Keep **Record diagnostics** enabled.

Open **Settings → Diagnostics → D110-M transport experiment → Image transport**.

- **Acknowledged (default)** selects the existing transport. This remains the
  default on a fresh installation or after resetting the experiment.
- **Paced without response (experimental)** opts in for eligible image packets
  on a verified, supported D110-M with the required characteristic capability
  and positive negotiated write size. Otherwise the job selects the existing
  transport before any image transmission and logs the fallback reason.
- **Reset to Standard Defaults** disables the experiment and restores only its
  own settings. Existing paper, price-side, inventory and other preferences are
  not reset.

Use the initial settings for the first hardware comparison:

| Setting | Initial value | Available bounds |
| --- | ---: | ---: |
| Image pacing | 10 ms | 10–1,000 ms |
| Writes per burst | 1 | 1–4 |
| Bytes per burst | 64 | 20–256 |
| Pending protocol frames | 1 | Fixed |
| Largest pending encoded frame | 262 bytes | Existing 255-byte payload plus framing |

Pacing is a burst cooldown measured from the last actual submission after the
write or byte budget is exhausted. Larger configured bursts may contain adjacent
fragment writes. The existing 10 ms spacing between NIIMBOT protocol frames also
remains, so an already elapsed cooldown does not add another unconditional delay.
These initial limits are conservative experimental choices, not a measured
printer-buffer capacity. Do not reduce pacing or raise budgets until the initial
comparison prints correctly.

Controls lock while printing or configuring paper. The driver additionally
captures an immutable mode/settings/capability selection at job start, so an
external preference change cannot alter an active job. Settings persist for the
next job; no Xcode launch arguments are required.

## What uses the experimental path

Only existing image row commands `0x83`, `0x84` and `0x85` qualify, and only when
their protocol definition has no expected response, response alternatives or
required-true checkpoint. A command that requires a printer reply retains its
established transport even if it uses an image opcode. Optional RFID handling
also retains its existing separate behavior.

PrintStart, page setup, PageEnd, status queries, errors, PrintEnd and the cleanup
heartbeat preserve their working definitions and order. On the current dual-mode
D110-M characteristic, required control writes still use write-with-response.
Printer notification parsing continues while image data is being submitted.

The same serialized outgoing pump retains one encoded frame and its offset.
Every image fragment is bounded by the current
`maximumWriteValueLength(for: .withoutResponse)` and the remaining byte budget.
The frame is neither truncated nor combined with another frame. The next
protocol request, including PageEnd, cannot begin until every image fragment has
been handed to CoreBluetooth.

Before each experimental fragment, the pump checks
`canSendWriteWithoutResponse`. If false, it waits for
`peripheralIsReady(toSendWriteWithoutResponse:)`. A pacing deadline can also wake
the pump; readiness arriving before pacing, or pacing expiring before readiness,
cannot bypass the other condition. If readiness is false, build 90 also schedules
a deferred readiness recheck every 250 ms, up to eight checks per transfer. This
can resume a ready pump when a delegate wake is absent; it never submits bytes
while `canSendWriteWithoutResponse` is false. The existing five-second transfer
deadline still fails the transfer if readiness never arrives. These rechecks are
readiness waits, not additional intentional pacing. Timer identity, transfer, connection and job
fences prevent a canceled or replaced wake from sending retired data. There is
one drain at a time. Experimental image writes do not wait for
`didWriteValueFor`; acknowledged writes retain their own acknowledgement path.

These are separate states:

1. **Submitted:** bytes were handed to CoreBluetooth. Readiness and submission
   do not establish that the printer's UART consumed them or that paper printed.
2. **Command reply received:** a matching NIIMBOT reply arrived and the existing
   command validation decides whether it is acceptable.
3. **Physical completion:** the existing status counter confirms copies. Those
   receipts still have to be saved, and final PrintEnd acknowledgement is still
   required before a successful return to Price Tags.

Cancellation, disconnect, printer error and timeout retire the pending work and
pacing wakeups. A partially dispatched page remains uncertain unless the
existing physical counter proves its completion. The app does not silently
switch transport mid-page or reprint uncertain copies. Inspect physical output
and use the existing queue review before explicitly retrying a needed label.

## Measurements

Diagnostics remain user-controlled, bounded and local. They contain fixed classifications,
numeric counts and timings, never label text, prices, images, packet payloads,
RFID identifiers, device names or serials. Firmware is reported as its two
available numeric version bytes without assuming a human-readable version format.

| Event/fields | Meaning |
| --- | --- |
| `label.transfer_summary`: `printer_model`, `protocol_version`, `command_path`, `firmware_byte_0/1` | Verified identity/task and available firmware bytes. |
| `transport_requested`, `transport_selected`, `transport_fallback` | Requested experiment policy, effective job selection and typed fallback reason. |
| `max_write_response_bytes`, `max_write_without_response_bytes` | Negotiated single-write limits observed at job start. Each actual write still respects the current limit. |
| `image_pacing_ms`, `image_burst_writes`, `image_burst_bytes`, `pending_packet_limit` | Captured experimental settings and queue bound. |
| `response_write_count`, `without_response_write_count` | Actual CoreBluetooth calls, including fragments, separated by write type. |
| `image_response_bytes`, `image_without_response_bytes` | Dispatched image-command bytes including NIIMBOT framing, separated by actual write type. These are not raw artwork or guaranteed radio-delivery counts. |
| `image_response_write_count`, `image_without_response_write_count` | Actual image-fragment write calls by type. |
| `image_transfer_ms` | Accumulated image-request spans, including their frame pacing and any transport waits. |
| `label.group_transfer.elapsed_ms` | Wall span for one prepared page/image group; includes its setup/end exchanges as documented in the existing timing guide. |
| `wor_readiness_wait_ms`, `wor_pacing_wait_ms` | Observed CoreBluetooth backpressure wait and experimental cooldown wait. These may overlap. |
| `wor_readiness_rechecks`, `wor_readiness_callbacks`, `wor_readiness_blocked_checks` | Deferred readiness checks that elapsed, delegate wakes during an image transfer, and false readiness observations. |
| `readiness_recheck_ms`, `readiness_recheck_limit` | Fixed 250 ms interval and eight-check bound per transfer. |
| `packet_pacing_ms`, `att_ack_wait_ms`, `printer_reply_wait_ms` | Existing frame pacing, remaining write-response waits and additional NIIMBOT reply-only waits after ATT acknowledgement. |
| `label.command_summary` | Bounded job aggregates by request/expected-response opcode: count, transfer span, ATT acknowledgement wait and additional NIIMBOT reply wait. Alternative/actual response identifiers remain in the existing control trace. |
| `status_poll_ms`, `status_backoff_ms` | Accumulated completion-check exchanges and pauses, not the entire physical feed duration. |
| `page_completion_wait_ms` | Accumulated time spent awaiting completion queries and their retry pauses (`status_poll_ms` + `status_backoff_ms`), excluding uploads that overlap physical printing. |
| `transfer_elapsed_ms` | Sending-stage wall span; includes planning, queue callbacks, status waits and final cleanup. |
| `label.job_summary.job_wall_ms` | Accepted driver job entry to exit, including stock/metadata preflight. |
| `expected_labels`, `confirmed_labels`, `uncertain_labels`, `job_outcome` | Expected copies, copies proven by the physical counter, potentially dispatched copies without proof, and job success/failure. Unsent copies are not called uncertain. |

All duration accumulation uses monotonic clocks. Whole milliseconds are emitted
after accumulation; values are bounded. Wall spans contain component waits, and
the readiness/cooldown waits can overlap each other. Do not add these fields to
reconstruct a wall total. Physical printing can overlap uploads. A failed final
job acknowledgement may leave all physical copies confirmed and zero uncertain
copies while `job_outcome` remains `failed`.

Aggregate command summaries are emitted at job end, rather than adding a file
write for every image packet. The existing upload UI remains bounded in update
frequency. A faster transport is not evidence of reliable physical output.

## Hardware A/B procedure

1. **Small baseline:** choose 3–5 inventory tags with known, different prices
   in the desired card order. Write that sequence and copy counts down. Use
   **Select Individual Inventory**, not Price Changed, so the first run cannot
   suppress the second. Keep paper, price position, style, density, phone,
   printer and connection conditions the same. Select **Acknowledged (default)**,
   prepare the batch and explicitly print it. Save an exported diagnostic file
   after completion using **Export Diagnostic Log** or **Copy Diagnostic Log**.
2. **Small experiment:** select the exact same cards/copies with identical
   settings. Choose **Paced without response (experimental)** at **10 ms / 1 /
   64 bytes**. Prepare the replacement labels and explicitly print. Check the
   log says `transport_selected=paced_without_response`; a fallback is not an
   experimental-mode result. Export a second diagnostic file.
3. **Inspect every label:** compare each physical price, artwork edge, logo,
   divider and frame with the baseline; verify the exact order and quantity.
   Look for missing, duplicate, incomplete or shifted tags. The confirmed count
   and successful job completion alone do not establish correct artwork. If
   output is wrong or uncertain, stop the experiment, retain both logs and
   output, and switch back to Acknowledged before any explicit retry.
4. **Original mixed batch:** after the small sequence is correct, repeat the
   original ten-card mixed-price benchmark once in each mode with the exact
   same input, order, copy counts and settings. Compare image groups/packet
   counts and total image-command bytes, not total wire bytes alone: status
   polling counts can legitimately vary as physical progress changes.
5. **Identical-copy regression:** repeat ten identical custom price tags in each
   mode. Retain the existing native-copy grouping (8 + 2), correct quantity,
   complete artwork, order and printer-confirmed finish. Also check Pause and
   reconnect review with a small batch; neither may automatically replay output.

Only after all initial output is correct should pacing/burst values be tuned.
Change one setting at a time and retain a fresh acknowledged-mode comparison.
The original 78 seconds includes acknowledgement/scheduling waits across many
writes; it is not a fully recoverable speed estimate. Mixed designs still need
different image uploads and are not expected to inherit identical-copy reuse.

Send back the baseline and experimental diagnostic **files**, the tested
sequence/copy counts and settings, elapsed time for each run, and whether every
physical label passed content/artwork/order/quantity checks. Include any failure
or interruption and whether the app retained queue review. Photos of defective
output are useful if artwork differs. Hardware reliability and speed remain
pending until these comparisons are performed on the D110-M.

## Software validation

Hardware feedback from build 88: the five-label acknowledged baseline completed
in 62.450 seconds, including 48.791 seconds of accumulated ATT acknowledgement
waiting. Both experimental attempts stopped before the first image write:
zero image bytes/writes, about five seconds of observed readiness waiting, and
zero experimental pacing wait. Setup commands and matching replies succeeded.
Earlier optional RFID reads also succeeded using the existing without-response
path. The logs establish a print-image readiness/wakeup stall; they do not prove
continuous false readiness, printer image rejection or buffer overrun. Build 90
adds the bounded recheck path and counters above without changing the initial
10 ms / 1 write / 64 byte settings. Hardware retesting is pending.

The Linux workspace has no Xcode or Swift compiler. Available checks passed:
322 existing portable tests (172 JavaScript, 59 server, 49 Postman and 42 Python),
Xcode source membership, all 212 Swift files' grammar, 47 pinned runtime assets,
both scalar/SIMD recognition smoke checks and `git diff --check`.

Build 88 introduced 21 native tests: 11 configuration/gate/actual pacing-wakeup tests,
8 protocol/selection/required-reply/measurement tests and 2 diagnostic privacy
tests. The asynchronous tests use the production pacing scheduler with a
controllable sleeper; CoreBluetooth integration and the printer's internal
buffer still require the hardware comparison.

Unsigned iPhone Release compilation passed on `c4271df`. The full native run
built and launched, then passed 357 tests with zero failures before its 20-minute
limit interrupted an existing exhaustive inventory-label rendering test. It had
not reached the new printer tests. Two UI jobs were blocked by simulator-selection
timeouts, and the broad and Research UI jobs timed out during compilation.

The existing workflow now offers a manual `printer_transport` scope to run the
complete transport, protocol and diagnostic test classes directly. Normal
push/PR runs and the default manual scope still run the full selection. This
test scope does not enable the device's experimental transport preference.

```sh
gh workflow run ios.yml \
  --ref experiment/niimbot-d110m-write-without-response \
  -f test_scope=printer_transport
```

The [focused native run](https://github.com/wgreelish-png/scanner/actions/runs/42280340186)
passed on `1830019`: **121 tests, zero failures**, including all 21 added tests.
The class totals were 11 transport, 82 protocol and 28 diagnostic tests. The
[unsigned iPhone Release build](https://github.com/wgreelish-png/scanner/actions/runs/42275977584/job/128094858044)
passed on `c4271df`; subsequent changes affect only CI selection and this guide.
The full native/UI limitations above remain separate from the successful focused
result. Hardware reliability and speed remain pending the physical A/B procedure.

Build 90 adds four native readiness/measurement regressions and three UI checks
for initial inventory-label preparation. The manual `label_preview` scope runs
the focused native suites, those three UI methods and the Release build together:

```sh
gh workflow run ios.yml \
  --ref experiment/niimbot-d110m-write-without-response \
  -f test_scope=label_preview
```

Build 90's [focused validation](https://github.com/wgreelish-png/scanner/actions/runs/42305265828)
passed on `40e977c`: **125 native tests and three UI tests, zero failures**, plus
unsigned iPhone Release compilation. All 25 added native tests executed; the
complete focused classes contain 14 transport, 83 protocol and 28 diagnostic
tests. The UI cases cover initial card selection, returning to change the
selection, and Print All. Each asserts the current preview, label count and
enabled Prepare button before any extra tap or scroll. The selected-card case
also verifies that the first Prepare tap queues the correct card and price.

This is software validation. The physical D110-M readiness behavior, output
reliability and speed still require the hardware comparison above.

## References

Reviewed NiimBlue `main` at commit
`30346c5a492f2fdbfed09800a95e6496a582f928` on November 6, 2026. Its Bluetooth
client serializes sends, retains 10 ms packet spacing and uses write without
response. Protocol-response handling remains separate from that GATT choice.
That supports this experiment's design but does not establish the D110-M's
internal buffer capacity.

- [NiimBlue Bluetooth transport](https://github.com/MultiMote/niimbluelib/blob/30346c5a492f2fdbfed09800a95e6496a582f928/src/client/bluetooth_impl.ts)
- [NiimBlue protocol responses](https://github.com/MultiMote/niimbluelib/blob/30346c5a492f2fdbfed09800a95e6496a582f928/src/client/abstract_client.ts)
- [NIIMBOT model-specific tasks](https://printers.niim.blue/interfacing/print-tasks/)
- [Apple readiness and delegate wakeup](https://developer.apple.com/documentation/corebluetooth/cbperipheral/cansendwritewithoutresponse)
- [Apple maximum write size](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:))
