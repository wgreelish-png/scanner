# Printer stage timings and reuse — build 85

The next diagnostic export can distinguish artwork preparation, command
encoding, Bluetooth acknowledgement waits, printer replies and completion
polling. Events now include fractional-second ISO 8601 timestamps. Durations
use monotonic clocks and are stored as bounded whole milliseconds; submillisecond
work accumulates before the transport totals are converted to milliseconds.
Previously saved log rows retain their original timestamp format.

## Confirming the printer sequence

`label.transfer_summary` records the verified numeric `printer_model`,
`protocol_version` and the `command_path` selected by the same code that builds
the commands. It preserves the earlier `print_task` field describing serial or
buffered operation. No printer name, serial, RFID identifier or packet contents
are recorded.

| Path | Meaning |
| --- | --- |
| `d110` | Existing supported legacy D110-family sequence. |
| `d110m_b1` | Supported D110-M identity using the reference B1 task mapping. |
| `d110m_v4` | D110-M model 2320, protocol 4, using the dedicated v4 task. |

For the user's verified 2320/protocol-4 printer, one batch declares the total
page count once. Each image group supplies page dimensions and copy quantity,
compressed image rows and PageEnd. The app reads the cumulative physical counter,
then waits for the final PrintEnd acknowledgement and performs the reference
cleanup heartbeat. Dispatch counters `print_start_count` and `print_end_count`
show whether those commands were handed to CoreBluetooth once or repeatedly;
dispatch is not proof of physical output or radio delivery.

`native_groups` counts uploaded image groups. `native_copies` counts additional
copies reusing an uploaded image. Consecutive identical artwork uses the native
quantity field, with the existing eight-copy/group and two-group window bounds.
Different actual artwork still requires another image upload.

## Reading the timings

| Event or field | Measurement |
| --- | --- |
| `label.preparation_summary` | Preview or queue preparation, identified by fixed `preparation_kind` and `preparation_stage` fields. |
| `preparation_elapsed_ms` | Entire preparation attempt, including rendering and storage when needed. |
| `render_elapsed_ms` | Actual raster renderer work; `render_count` counts attempts and `raster_reuse_count` counts reused results/copies. |
| `approval_save_ms`, `queue_save_ms` | Time spent saving price decisions and the prepared queue. |
| `plan_encode_ms` | Request-plan validation, image row compression and command construction. |
| `packet_encode_ms` | Wire framing/checksums immediately before dispatch. |
| `packet_pacing_ms` | Actual time spent in the existing inter-packet pacing delay, including scheduling. |
| `att_ack_wait_ms` | Time between handing acknowledged write chunks to CoreBluetooth and receiving their write callbacks. This includes OS/radio/peripheral scheduling; it is not pure airtime. |
| `printer_reply_wait_ms` | Additional wait for a required printer reply after all write acknowledgements have arrived. An earlier reply does not double-count acknowledgement time. |
| `status_poll_ms`, `status_backoff_ms` | Completion-status request spans and waits before another status poll. |
| `print_start_ms`, `print_end_ms` | Request spans for starting and ending the job. |
| `label.group_transfer` | One image group's submission span and dispatched request/packet/byte deltas. Modern batch initialization is outside this span; legacy per-page setup is inside. `accepted` refers to image submission, not physical completion. |
| `transfer_elapsed_ms` | Entire driver sending attempt, including planning, storage callbacks, status waits and final cleanup. |
| `previous_job_gap_ms` | Prior sending attempt's end to the next attempt's start, including user idle time. Omitted for the first attempt; prior attempts may have succeeded, failed or been cancelled. |
| `label.roll_read` | Fixed cache/read source and the duration of an actual optional RFID read. |
| `label.connection_ended` | A fixed retirement source, typed reason and app state distinguish manual disconnect, lifecycle stop, replacement, cancellation and required failure. |

Request/group/job spans contain their component waits and must not be added to
them. The interval between attempts is not an automatic-delay measurement:
it can include user interaction and time outside the app. Physical-counter
confirmation may arrive after a label finishes while the next complete image
uploads. Neither PageEnd nor a full upload is counted as physical completion.

## Avoiding repeated work

Artwork rasters are already prepared and persisted before printing. Batch command
plans are prepared before the first image is sent. Legacy fallback now reuses
those prepared per-page requests, removing redundant row compression while
retaining its existing serial physical print jobs and command order.

Inventory branded tags retain their existing full-profile/price/side raster
cache. A custom tag model now reuses its latest exact validated preview raster
when Prepare needs the same draft. Changing the price, copies, bulk mode, price
side or complete RFID geometry causes a new render. The cache is local to the
model, keeps one entry and does not rewrite saved queues or preferences. Preview
summaries count one image; queue summaries count requested physical copies.

Automatic RFID consumers share a pending read and can reuse successful metadata
for up to 30 seconds on the same connection and unchanged revision. This limits
read reuse; it does not proactively remove the displayed paper profile after
30 seconds. Explicit Refresh forces a read. Printing, known stock changes,
failed/missing reads and disconnects retain their invalidation behavior; a
post-print stale remaining count still needs a read. The offline product
catalog already stores decoded products and full geometry in one shared lookup.

The verified idle foreground Bluetooth link stays open between jobs. Manual
Disconnect, leaving the active state, actual link failures and required-command
failures retain their existing handling. Packet acknowledgement, pacing, image
quality, label order, bounded buffering, stock checks and final confirmation
remain in place. No periodic background print/reconnect or automatic replay is
introduced.

## Phone comparison

1. Connect the D110-M and print ten copies of one custom price tag. Confirm ten
   physical tags and successful return to Price Tags. For 2320/protocol 4, expect
   `d110m_v4`, one PrintStart and one PrintEnd, two native groups (8 + 2), and
   eight reused native copies.
2. Print ten tags with different displayed prices, such as $1 through $10,
   keeping the same paper and price position. Expect ten groups, zero reused
   native copies, and one start/end for the batch. Distinct card names with the
   same price-only artwork are still identical designs.
3. Export diagnostics after each comparison. Compare preparation, plan/packet
   encoding, acknowledgement, reply and polling durations. Inspect group spans
   alongside the summary instead of adding overlapping measurements.
4. Prepare a custom preview and immediately Prepare the same draft. Check the
   queue preparation summary reuses its raster. Change price side or roll
   geometry and verify the new artwork matches the new choice.
5. Use explicit roll Refresh, then repeat automatic access while the result is
   fresh. Check forced/read versus cache/in-flight sources. Print again and
   confirm the remaining-label estimate is refreshed after invalidation.
6. After a successful print, start another job while the app stays active.
   Verify no connection retirement appears between them. Separately test manual
   Disconnect and app interruption; retirement source must explain each, and
   neither event may replay uncertain output automatically.

Hardware buffer capacity and feed speed are not established by these logs.
The two-group upload window, acknowledged writes and existing pacing are
unchanged. This build measures the stages needed for a supported next change.

## Validation receipt

- All 322 portable tests passed: 172 JavaScript, 59 research-server, 49 Postman
  and 42 Python tests.
- Swift grammar passed for all 210 source/test files. App source membership,
  47 pinned runtime assets, both OpenCV smoke checks, build/revision metadata
  and whitespace checks passed.
- Added 16 native regressions covering ten identical versus ten different
  images, exact command paths, timing order and interruption, preview reuse,
  metadata caching/invalidation and diagnostic privacy/opt-out. Independent
  source review found no blockers.
- The previous build 84 iOS CI release build passed. Its native run exposed
  four existing fixture issues: border pixels in a blank-price crop, a lossy
  JSONSerialization test helper, an overlong language-name fixture and an
  import-replacement test using the merge default. Only those tests were
  corrected; production rendering, money serialization and import behavior
  were preserved. The separate budget UI job timed out selecting a simulator
  before launching the app.
- Xcode/native execution and physical phone/printer comparisons were not
  available in the Linux workspace. The six phone checks above remain to be
  verified on hardware; portable checks cannot establish feed speed or battery
  impact.
