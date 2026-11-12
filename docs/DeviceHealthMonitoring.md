# Device health monitoring and heat protection

Build 111, revision `apple-thermal-camera-threshold`, follows Apple’s recommendation
to reduce demand at serious heat and stop camera use at critical heat. Build 110’s
`smooth-review-camera-preview` behavior and the build 76 device monitoring remain
active. See [Apple thermal guidance](AppleThermal111.md) for the source and limits.

## Recorded measurements

When diagnostics are enabled and the app is active, `health.sample` summarizes
resource context every 30 seconds and once when monitoring starts. A two-second
main-actor heartbeat measures scheduling delays; it only updates a bounded
in-memory aggregate, never writes a log line itself. There is no display-link
profiler, per-frame diagnostic write, network upload or background polling.

| Field | Meaning |
| --- | --- |
| `thermal_level` | iOS nominal/fair/serious/critical classification; not a temperature in degrees |
| `low_power_mode` | Whether iOS Low Power Mode is enabled |
| `process_scope` | Always `native_app`; separate WebKit processes are excluded from these CPU/memory measurements |
| `native_memory_mb` | Current native app physical footprint in MiB, when the system query succeeds |
| `native_cpu_ms` | Native process CPU time consumed during `sample_window_ms`, when both samples are valid |
| `sample_window_ms` | Actual foreground sample interval, rather than an assumed fixed duration |
| `battery_percent` / `battery_state` | Sparse battery gauge and charging context; unknown gauge values are omitted |
| `ui_lag_count` / `ui_lag_max_ms` | Number and maximum of heartbeat delays at least 250 ms beyond their expected wake time; maximum capped at 60 seconds |
| `memory_warning_count` | Native memory warnings observed during the sample window |

Thermal changes, Low Power Mode changes and memory warnings also produce fixed
`health.thermal_changed`, `health.low_power_changed` and `health.memory_warning`
events. Repeated memory warning writes are sampled while the aggregate retains
the count. CPU is cumulative process time across threads, so it can exceed
elapsed wall time on a multicore phone. It is not a whole-phone CPU percentage,
energy measurement, camera FPS, or WebKit worker CPU measurement. Heartbeat
lateness indicates scheduling pressure, not an exact per-frame freeze duration.

Inactive/background transitions stop both sampling tasks and notifications and
reset timing baselines. Returning cannot count background dwell as a UI stall
or charge it to a foreground CPU interval. Turning Record diagnostics off also
stops telemetry and restores the previous battery-monitoring setting. Existing
settings and inventory formats are unchanged.

The privacy manifest declares System Boot Time reason `35F9.1` for the
`ProcessInfo.systemUptime` elapsed-time calculations. Absolute uptime and boot
time stay in memory; exported diagnostics contain elapsed intervals and bounded
delay aggregates. This matches Apple's
[elapsed-time API reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## iOS diagnostic summaries

The app subscribes to MetricKit diagnostic delivery only while foreground and
diagnostics-enabled. If iOS supplies reports, `health.os_report` records fixed
crash/hang/CPU-exception/disk-write-exception kinds, positive bounded counts and
the supplied window duration. It never serializes report bodies, call stacks,
metadata, identifiers or screenshots. A bounded in-memory replay history
prevents duplicate windows from repeatedly filling the log; callbacks from a
disabled or previous subscription are ignored.

These are counts in delivered report windows, not cumulative app totals.
Delivery can be delayed and is not guaranteed. A missing report is not evidence
that a crash or hang never happened.

## Active heat protection

Protection uses iOS resource notifications independently of diagnostic opt-out:

- Normal thermal state keeps the existing recognition scheduler and requests
  a maximum 30 FPS camera stream. Recognition resolution remains unchanged.
- Fair or serious thermal state, or Low Power Mode, limits the card scanner processing /
  overlay scheduler to approximately 5 Hz (200 ms between frame requests) and
  requests a maximum 10 FPS camera stream. Actual rates depend on camera support.
- A held choose-card review, manual-search sheet or unresolved manual-search
  prompt stops recognition/outline work while retaining the existing preview
  cap: 30 FPS normally or 10 FPS in reduced mode. The warm stream remains mounted,
  and the loaded database/backend and frozen review remain available. Review or
  manual entry alone no longer requests 1 FPS. Processing stays paused without
  reopening the database or changing matching thresholds.
- Critical thermal state stops card recognition and camera capture
  and shows Cooling down. The loaded database/backend and frozen card review
  remain available. Capture can resume after cooling only when the scanner is
  still active and foreground, manual search is closed and the user has not
  explicitly paused or left it.
- Startup, outstanding camera acquisition, playback, manual return, reset and
  database refresh all respect cooling. A bounded native acknowledgement
  deadline backs up the WebKit command. If delivery fails or hangs, the public
  WebKit camera-stop API retires capture and exposes Retry instead of claiming
  successful cooling recovery.
- The separate PSA barcode camera also refuses startup and pauses at critical
  heat. Captured certification codes remain available; its existing
  Retry Camera action resumes when eligible, and manual number entry works.

No app can promise zero battery consumption or prevent every OS/app crash.
Camera use consumes energy, and heat also depends on charging, brightness,
ambient conditions and other workloads. These changes provide evidence and
reduce scanner demand when iOS reports pressure. Physical-device acceptance
is still required before calling sustained operation verified.

## Diagnostic 19 and build 103

The affected build 102 run began scanning at 02:36:06 UTC on November 7. iOS
reported fair heat at 02:38:49 and serious heat at 02:48:44, approximately
12 minutes 38 seconds after scanner start. Serious began during a manual-search
sheet. The run contains no printing events; earlier retained printer logs belong
to another run. Native memory peaked at 104 MiB, and all samples reported zero
memory warnings and heartbeat-lag counts. The native process sample excludes
WebKit and camera work, so it cannot establish total phone load or the cause of
heat. No crash report was present; report delivery can be delayed.

Before build 103, review froze result delivery while recognition continued behind
its sheet. Manual search stopped recognition but retained a camera with no explicit
frame-rate limit. Build 103 stopped hidden recognition and capped held previews at
1 FPS. Diagnostic 22 then confirmed that this cap made review and manual transitions
jerky even in nominal conditions. Build 110 retains the recognition pause and uses
the normal/reduced preview caps instead. Camera constraint
updates use one serialized pump, coalesce to the latest state and ignore retired
stream callbacks. A pending browser constraint operation is not cancellable;
critical heat still stops its track immediately. Unsupported or rejected
constraints are logged, never represented as measured success.

`web.camera_workload` records transitions, not frames:

| Field | Meaning |
| --- | --- |
| `resource_mode` | Normal, reduced or cooling policy |
| `capture_state` | Live, review, manual, prompt or stopped |
| `target_fps` | Requested cap (30, 10 or 0 when inactive; older builds also used 1) |
| `camera_fps` | Bounded frame rate reported by track settings, omitted if unavailable; not measured rendered cadence or energy |
| `processing_active` | Whether the recognition loop is active |
| `constraint_state` | Pending, applied, unsupported, failed or inactive |

These diagnostics keep the existing opt-out and scalar-only privacy limits.
Comparisons should use the same phone and ordinary scanning conditions. Actual
heat/battery improvement remains pending a sustained physical-device session.

## Phone acceptance

1. Use the app normally for 15–20 minutes, including scanning, manual entry,
   editing a recent card and printing. Export diagnostics afterward. Check
   health samples alongside scanner timings for rising footprint, memory
   warnings, heartbeat delays and the reported thermal bands.
2. Enable Low Power Mode and return to scanning. Verify scanning still finds
   cards and uses reduced processing. Disable it and verify normal operation.
3. Background the app for several minutes, then return. Verify there are no
   health samples during inactivity and no artificial long UI stall / CPU
   interval attributed to that gap.
4. Turn Record diagnostics off and repeat background/foreground transitions.
   No new health records should be added. Turn it on to resume fresh samples.
5. Observe battery context during a normal unplugged session. A percentage
   change is useful context, not a precise measurement attributable solely to
   this app. Avoid drawing conclusions from a single 30-second battery sample.
6. Exercise cooling transitions with injected test states in automated tests;
   do not intentionally heat a physical device. On an organically warm phone,
   verify serious heat uses reduced card scanning and critical-heat Cooling down
   stops capture, keeps saved data/review usable and
   respects user pause/manual-entry/background state during recovery.
7. While choosing a match or entering a card manually, inspect the new workload
   events for `processing_active=false` and the same normal/reduced preview cap.
   Return to scanning and confirm recognition resumes without a repeated pack load, a preview
   glitch or a stale match. In ordinary use at fair heat, check the 10 FPS camera
   request and 200 ms recognition scheduler; send diagnostics after the session.

The native regression tests cover metric bounds, cancellation, preference and
battery ownership, heartbeat baselines, report aggregation/deduplication and
the thermal policy matrix. JavaScript regressions cover cooling startup,
camera resolve/rejection, playback interruption, review preservation, late
callbacks, foreground/manual gating and reduced-scheduler cancellation. Linux
checks cannot execute the native iOS APIs or establish device battery/heat
behavior; Xcode and an iPhone remain necessary for those checks.

## Build 103 validation

All 182 app JavaScript tests passed, including ten new workload/lifecycle tests.
Swift grammar passed for all 214 files, app-source membership passed for 115
files, and the 47 pinned scanner assets passed integrity/dependency checks.
Five native diagnostics tests cover bounded values, requested versus reported
rates, privacy and opt-out. Native execution and sustained iPhone heat/battery
results remain pending; GitHub iOS checks are started without waiting for them.

## Build 76 validation (historical)

The local portable suites passed: 172 app JavaScript tests, 59 research server
tests, 49 Postman collection tests and 40 Python tooling tests (320 total).
Swift grammar passed for all 196 files. Xcode source/resource membership passed
for 109 app, 73 native-test and 14 UI-test Swift files. The 47 pinned scanner
assets and dependency closure passed integrity checks; both bundled scalar and
SIMD OpenCV smoke tests passed. Privacy manifest parsing, the elapsed-time API
reason, metadata and whitespace checks passed.

All 359 other baseline files are byte-identical, including inventory,
persistence, financial calculations, printer code and label artwork. Fourteen
new native test cases were added; native compilation/execution and physical
device testing remain pending in this Linux environment.
