# Build 113: manual search and scanner reliability

Diagnostics 22 showed four successful manual additions taking about 35 ms to
save but another 1.15 seconds to return through two modal dismissals. Manual
confirmation now opens inside the existing search sheet. Successful Add closes
the entire flow once. Cancel or Back returns to the same query, optional filters
and results, with the keyboard available again when requested. The normal
printing/condition, pricing, draft-first-card and save-failure rules are retained.

Selecting a card cancels pending typeahead work and retires its request token.
Late completion cannot replace results or log a completed search behind the
confirmation page. Back can reuse completed results without reopening the index
or repeating an unchanged query. An explicitly changed criterion or Retry still
starts a fresh search.

## Narrow a manual search

Expand **Set & number filters** to enter a set name/abbreviation or collector
number. These optional criteria narrow the full saved catalog before the five
closest results are selected. Without filters, existing combined search and
ranking stay the same. **Clear Filters** keeps the main query.

A bare collector number such as `41` can match `041/086`, but does not match
`141/086`. Supply a denominator to require the full number. Alphanumeric codes
remain case insensitive and retain their letters; numeric components normalize
leading zeros without converting long identifiers to integers. Queries and filter
values do not enter diagnostics.

## Resume after backgrounding

Before loading a scanner page, the app checks that its loopback server answers
an authenticated, generation-specific health request. The local probe has a
one-second bound and a 128-byte response cap. It uses no redirects, cached
responses, cookies or external credentials and sends no external network request.
A failed check permits one replacement listener and verification, not a retry
loop. Concurrent users share the check; cancellation and stale generations cannot
restart or stop another client's newer listener. Existing page-load recovery is
still available for a connection failure after a successful probe.

## Delivered video measurements

`web.camera_delivery` summarizes camera-active windows about every five seconds
and flushes the final partial window when capture stops. A lightweight video-frame
callback observes counters only; it never reads image pixels or writes a log per
frame. Turning diagnostics off retires the measurement observer and timer.

| Field | Meaning |
| --- | --- |
| `capture_mode` | Live or Photo Scan at the sampled window |
| `delivery_state` | `measured`, `pending` baseline, or `unavailable` |
| `delivery_window_ms` / `camera_on_ms` | Monotonic aggregate window and camera-active duration |
| `delivered_frames` | Counter delta for frames delivered to the video element |
| `frame_window_ms` / `delivered_fps` | Time between the frame-counter endpoints and their observed cadence |

Frame-counter endpoints can differ from a timer/stop boundary, so their duration
is recorded separately. Windows and counters are bounded and retired streams
cannot add samples to a replacement. A counter reset or unsupported callback does
not fabricate frame delivery. Without a monotonic clock, availability is reported
without invented timing. Requested `target_fps` and track-reported `camera_fps`
remain separate in `web.camera_workload`.

This measures video-element delivery, not physical display refresh, dropped
SwiftUI frames, whole-phone CPU, energy or temperature in degrees. Native health
CPU/memory still excludes WebKit. Summed camera-on durations help compare Live and
Photo Scan sessions; they do not establish battery consumption by themselves.

## Phone checks

1. Search manually, select a card, then Cancel/Back. Verify query, filters and
   results remain. Add it and verify one saved copy and one return to the caller.
2. Try set-only, number-only and combined searches, including a card outside the
   first unfiltered five. Check numeric boundaries and an alphanumeric number.
3. Select a result immediately after typing. Late search work must not alter the
   confirmation. Failure must retain the card for retry; no empty scan list is
   saved merely by opening search.
4. Background for several minutes and return to Live or Photo Scan. Check startup
   without a failed page flash and confirm the loaded database is still reused.
5. Compare ordinary Live and Photo Scan sessions. Export diagnostics and inspect
   delivery windows alongside mode, camera-on time and thermal state. Photo
   processing/review dwell must not count as camera-on time.
6. Disable diagnostics while framing, then re-enable it. Disabled intervals must
   not produce delivery samples or enter a later enabled interval.

Inventory, saved preferences, prices, transactions and the critical-only camera
thermal threshold are preserved. Software and physical-phone results are reported
separately; these measurements do not guarantee thermal or battery improvement.

## Software validation

Local checks passed: 200 app JavaScript tests and 77 Python tooling tests,
including seven new delivery-metric/opt-out cases and focused runner routing.
Grammar checks passed for 11 changed/new Swift files; project membership, all 47
pinned runtime assets, metadata, shell syntax and whitespace checks passed.
Native tests cover catalog filters, suspended searches, server probe ownership,
metrics validation and Photo Scan policy. Focused UI checks cover one-sheet Add,
Back/filter preservation and the outstanding Photo Scan preference/shutter case.
The prior Photo Scan UI run was blocked by a synthetic cleanup timeout test;
its startup budget is now robust to macOS Python startup without changing the
production cleanup timeout. Native/UI execution is sent to GitHub; queued or
running checks are not passing results. Physical-phone timing and battery/heat
comparisons remain pending.
