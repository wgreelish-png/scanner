# Device health monitoring and heat protection

Build 76, revision `device-health-protection`.

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

- Normal thermal state keeps the existing card scanner scheduler.
- Fair thermal state or Low Power Mode reduces the card scanner processing /
  overlay scheduling cadence to at most approximately 10 Hz. The live preview
  remains managed by the camera; this is not a claim about video FPS.
- Serious or critical thermal state stops card recognition and camera capture
  and shows Cooling down. The loaded database/backend and frozen card review
  remain available. Capture can resume after cooling only when the scanner is
  still active and foreground, manual search is closed and the user has not
  explicitly paused or left it.
- Startup, outstanding camera acquisition, playback, manual return, reset and
  database refresh all respect cooling. A bounded native acknowledgement
  deadline backs up the WebKit command. If delivery fails or hangs, the public
  WebKit camera-stop API retires capture and exposes Retry instead of claiming
  successful cooling recovery.
- The separate PSA barcode camera also refuses startup and pauses at serious /
  critical heat. Captured certification codes remain available; its existing
  Retry Camera action resumes when eligible, and manual number entry works.

No app can promise zero battery consumption or prevent every OS/app crash.
Camera use consumes energy, and heat also depends on charging, brightness,
ambient conditions and other workloads. These changes provide evidence and
reduce scanner demand when iOS reports pressure. Physical-device acceptance
is still required before calling sustained operation verified.

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
   verify Cooling down stops capture, keeps saved data/review usable and
   respects user pause/manual-entry/background state during recovery.

The native regression tests cover metric bounds, cancellation, preference and
battery ownership, heartbeat baselines, report aggregation/deduplication and
the thermal policy matrix. JavaScript regressions cover cooling startup,
camera resolve/rejection, playback interruption, review preservation, late
callbacks, foreground/manual gating and reduced-scheduler cancellation. Linux
checks cannot execute the native iOS APIs or establish device battery/heat
behavior; Xcode and an iPhone remain necessary for those checks.

## Validation results

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
