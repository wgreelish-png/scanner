# Build 8: scanner startup recovery and top-loader diagnostics

The weekend build-7 log recorded five failures connecting to the app's local scanner page. A completed startup task could be reused after its listener had stopped. The server now tracks listener readiness, invalidates terminal or unavailable listeners, ignores obsolete callbacks and coalesces concurrent starts/restarts. Startup and socket-release waits are bounded. Recovery keeps the same localhost origin, cache token and saved database; it closes obsolete connections without clearing stored data.

The scanner page automatically gets one server-restart/reload attempt for a current localhost connection failure, lost connection or timeout. A stopped or replaced scanner cannot be reopened by an old callback. After the retry is exhausted, Retry Live Scanner remains available. This recovery does not finish a session, add cards, discard a pending match or change the list.

Recognition geometry gates, thresholds, candidate ordering, hashes, matching, camera settings and confirmation behavior are unchanged. The bundled engine only reports additional scalar diagnostic metadata. This build does not claim improved recognition of cards inside top loaders.

## Information in the diagnostic export

- Listener lifecycle: `local_server.starting`, `ready`, `waiting`, `failed`, `restarting` and `stopped`; page retry/recovery events identify automatic recovery and exhausted retries.
- `web.scan_stats`, at most once every five seconds: detection outcome, stage, tracking, raw/rejected/candidate counts, chosen candidate index, outline aspect/area/edge support, match distance/gap and sampled whole-frame brightness/contrast when available.
- `web.recognition_snapshot`: recent scalar detection context when a result becomes held for confirmation.
- `web.scan_issue`: a user-marked top-loader, dark-card or wrong-border problem, with the age of its recent statistics. A held review uses its frozen context. Geometry is omitted when the sample is over 15 seconds old, so old metadata is not presented as a current observation.

Whole-frame brightness is not the detector's card-interior contrast measurement. Outline aspect/area describe the observed shape; they do not prove that it belongs to a plastic holder. Counts are not failed-card totals or recognition-accuracy measurements. Diagnostics contain no camera images, card names/references, cookies, credentials or raw website responses. Existing bounded log storage and the Settings recording switch remain in place.

## When you test later

1. Open the scanner, briefly background/lock the phone, then return and reopen scanning several times. Check that the existing list remains and that the database is reused. Try Retry Live Scanner if a connection failure remains; export the log afterward.
2. Hold a problem card steady for about five seconds. While it is still in view, open **Scanner options (… ) → Mark Scan Issue → Top Loader Not Recognized**. Choose Dark Card Not Recognized for a dark-card miss. Mark a wrong outline or match with Wrong Border or Match; the same menu is available from the flag on the match review.
3. Repeat with an easy bright card, then—if practical—the same problem card outside its rigid holder on a light, matte background. Keep the existing physical-card confirmation workflow.
4. Export diagnostics from Settings, or use the existing `[CardShowScanner]` console filter in a Debug build attached to Xcode. A screenshot of an incorrect outline is still useful: scalar diagnostics cannot reconstruct the image.

Install over the current app with the existing personal signing configuration. Physical-iPhone acceptance is deferred until this test; automated checks establish compilation, lifecycle behavior and diagnostics invariants, not real-world top-loader accuracy.

## Automated validation

[macOS CI at `890f7e2`](https://github.com/wgreelish-png/scanner/actions/runs/40340215446) passed all 124 native tests and the unsigned CardShowScanner Personal Release iPhone build. The 22 added native tests cover listener lifecycle/restart/retry policy and diagnostic validation/export. All 69 JavaScript tests and 20 Python helper tests passed; source/resource membership, all 31 Swift files, scheme/plist parsing and 47 pinned runtime assets were checked. Both OpenCV builds retain the pre-diagnostics synthetic hash and bright-card/tracking/removal decision fingerprint. These automated results do not establish physical iPhone recovery or real top-loader recognition accuracy.
