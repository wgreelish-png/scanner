# Printer stage timings and reuse — build 85

Build 93 restores the working acknowledged transport. The unsuccessful
without-response experiment remains in its separate Git branch/history; its
picker, preflight and image pump are removed from the main app. Preview,
progress and abandoned-queue cleanup fixes remain.

Build 94 adds bounded acknowledged image batching on the verified model
2320/protocol-4 path. It combines exactly two adjacent complete one-way image
frames (`0x83`, `0x84`, `0x85`) into a single ordinary acknowledged write.
The encoded payload is capped at the minimum of 64 bytes, the acknowledged
write limit and the ordinary payload hint. Unknown limits and other printer
profiles retain single-frame writes. No extra setting or approval is needed.

Each original frame keeps its header, length, payload, checksum and footer.
Odd tails and every control, required reply and page boundary stay separate.
The pair waits for its normal CoreBluetooth write acknowledgement before upload
progress advances by two requests. Physical counts still require the printer's
counter and final job acknowledgement. Failed or cancelled output is not replayed.

The pair retains a total 20 ms pacing budget, while its two encoded frames are
contiguous inside the payload. This changes the spacing inside a pair, which
requires physical-printer validation. A payload-limit shrink before submission
stops the pair rather than fragmenting it or retrying its rows automatically.

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

## Comparing acknowledged image batching

The supplied five-label baseline submitted 23,696 image bytes through 968 image
writes. It took 62.450 seconds, including 48.791 seconds of accumulated ATT
acknowledgement waiting and 11.420 seconds of inter-packet pacing. This is mainly
per-write scheduling overhead, not a large artwork file or slow rendering.

Build 94 enables the two-frame grouping described above. The 512-byte
acknowledged API limit does not prove a 512-byte ordinary ATT payload; the same
connection reports 241 bytes for without-response writes. The initial 64-byte
cap stays below both. Actual printer acceptance and speed remain to be checked.

| Summary field | Measurement |
| --- | --- |
| `image_packets` | Original logical image frames; grouping must not change this count. |
| `image_write_count` | Actual Bluetooth image writes, including any fragmented single frames. |
| `image_batch_count`, `image_batched_packets` | Submitted two-frame payloads and logical frames included in them. |
| `image_max_write_bytes` | Largest actual image-write payload. |
| `image_batch_limit`, `image_batch_frame_limit` | Captured payload cap and maximum frames per write. A disabled cap is zero. |
| `group_image_writes` | Actual image writes for one submitted group. |

First print three known different prices and inspect artwork, order and count.
Then repeat the original mixed-price batch with the same paper, price side and
copies, and export diagnostics. Expect a positive batch count and fewer actual
image writes than logical image frames. Compare wire bytes, original frame
counts, acknowledgement waits and wall spans. Also repeat identical copies to
check their existing native-copy reuse. No hardware result is claimed yet.

Pacing could also be measured separately. Removing every observed pacing delay
could recover at most about 11.4 seconds in this baseline, while acknowledgement
waits would remain. Firmware may need processing time after an ATT receipt, so
build 94 retains the total 10 ms budget per original frame. Removing that budget
is a separate change and is not part of image batching.

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
The two-group upload window and acknowledged writes are unchanged. Image batching
changes packaging and spacing inside each pair, while retaining the total pacing
budget. The new counters measure the actual effect of that change.

## Diagnostic 15 and progress clarity — build 87

The supplied build 85 diagnostic contains two finalized ten-label jobs on model
2320, protocol 4, using `d110m_v4`. Both dispatched one PrintStart and one
PrintEnd. Their measured timings were:

| Measurement | Mixed prices | Identical copies |
| --- | ---: | ---: |
| Entire transfer | 99.954 s | 32.029 s |
| Bluetooth write acknowledgement waits | 77.928 s | 21.772 s |
| Packet pacing | 18.118 s | 5.036 s |
| Additional printer-reply wait | 0.147 s | 0.112 s |
| Image groups | 8 | 2 |
| Image packets | 1,549 | 414 |

The mixed job reused five rendered price designs during preparation, but some
matching designs were separated in card order and needed separate uploads.
The user chose to preserve that order. Only consecutive identical artwork may
share a native-copy group; cards are not regrouped by price.

The first physical-counter query arrived after two complete image uploads.
The mixed job's first saved confirmation arrived about 24 seconds after its
first page started. The identical-copy job's first query arrived about 26 seconds
after its first group started and already confirmed six printed copies. These
are confirmation delays, not exact physical print durations. The log cannot
show whether an on-screen count was rendered incorrectly, but it does prove
that confirmation may lag actual output while an image is uploading.

Build 87 shows upload activity separately from the confirmed printed count.
The sending bar advances only after a request completes and validates, with
observable UI updates limited to roughly five per second plus group boundaries.
It reflects the current group's completed requests, not bytes delivered over
the air or physical labels printed. Once that upload ends, the screen can wait
for the printer's next confirmation. A submitted image never advances a receipt
or triggers successful return by itself. Final PrintEnd acknowledgement, saved
receipts, Pause, failure review and interruption handling stay in effect.

The new progress events are in memory only; raster requests do not create a
new diagnostic line per packet. No printer commands, packet spacing, write
acknowledgements, quality, buffer limits, physical label order or stored queue
schema are changed by this progress update.

To check build 87 on the phone, repeat the same-order mixed batch and the
identical-copy batch. During an upload, the separate Sending range and percentage
should move even when Confirmed printed has no new proof. Once an upload ends,
the screen can transition directly to Waiting for printer confirmation; a
visible 100% frame is not required. The identical-copy counter may legitimately
jump from 0 to several labels when its first status query returns. Pause during
an upload and verify the upload indicator disappears, unconfirmed copies remain
reviewable, and the app does not return to Price Tags as if printing succeeded.
The last physical receipt must still wait for the final job acknowledgement.

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
- Build 87 reran the 322 portable tests and source/runtime checks successfully.
  Four additional native and two UI regressions cover upload throttling,
  exact A/B/A card order and wire bytes, interrupted/failed uploads, upload
  acceptance versus physical proof, and final acknowledgement gating. These
  native/UI regressions are authored and reviewed, with execution pending on
  iOS. The progress change introduces no additional printer requests.
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
