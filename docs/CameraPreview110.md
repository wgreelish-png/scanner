# Build 110: camera preview during card review and manual search

Diagnostic 22, exported from build 109 on November 11, shows a deliberate preview
policy change on every card review: 54 applied review transitions and all four
manual-search entries requested and reported 1 FPS. Normal live transitions
restored 30 FPS. The latest session's sampled thermal state was nominal, with no
memory warnings or sampled heartbeat lag. Earlier sessions did contain thermal
pressure, so heat protection remains necessary. Native CPU/memory samples exclude
WebKit; track-reported FPS is a camera setting, not a rendered-frame measurement.

Build 110 changed the preview to retain the resource policy's cap throughout live scanning, card
review, manual search, the manual-search suggestion, and recent-card editing:
30 FPS normally, 10 FPS at fair heat or in Low Power Mode. These are requested
limits, subject to device/browser support. Recognition and outline processing
remain stopped while a review or manual screen is open. Reusing the mounted
stream and loaded database avoids a restart on return. Build 110 kept the earlier
serious/critical pause; [build 111](AppleThermal111.md) narrows the camera pause to
critical heat and reduces card scanning at serious heat. Backgrounding still stops capture. Card matching, inventory and user preferences
are unchanged.

State-only transitions also reuse a successfully applied frame-rate target on
the same stream and track, avoiding repeated camera reconfiguration. A new target
or stream must establish its own success; failed changes and retired streams
cannot reuse that cached result. The serialized latest-request pump and stale
callback fences remain active.

The app-owned bridge and its lifecycle regression tests cover this policy. The
bundled recognition engine and its 47 pinned assets are unchanged. Software tests
cannot verify rendered smoothness or battery impact on an iPhone.

## Phone check

1. With Low Power Mode off and the phone at normal temperature, open scanning,
   select a recognized card, and move the phone slightly. The visible preview
   should remain fluid while the chosen-card result stays fixed.
2. Open Search Manually, search or add a card, then return. Repeat several times,
   including editing a recently scanned card. Preview movement should remain
   fluid through the transitions without another database load or extra camera
   permission request.
3. Enable Low Power Mode and repeat. A 10 FPS preview is expected in reduced
   mode; manual/review must not drop it to 1 FPS. Turn Low Power Mode off and
   confirm the normal cap returns.
4. Background and return once. If iOS naturally reports critical heat, capture
   should stop for cooling. Do not intentionally heat the phone.
5. Export diagnostics afterward. Relevant `web.camera_workload` transitions
   should show `target_fps=30` normally or `10` in reduced mode, with
   `processing_active=false` during review/manual/prompt. Check
   `constraint_state` and `camera_fps` separately; unsupported constraints must
   not be interpreted as confirmed rates.

## Validation

Local checks passed: 185 app JavaScript tests and 73 Python tooling tests,
including the preview lifecycle and focused CI routing cases. Project source and
resource membership, all 47 pinned runtime assets, the changed Swift test's
grammar, build metadata, shell syntax and whitespace checks passed. The focused
native run selects scanner diagnostics, device health, page recovery and manual
search lifecycle suites. Native execution and physical-phone smoothness/thermal
results are pending; this Linux workspace cannot run UIKit or CoreBluetooth.
