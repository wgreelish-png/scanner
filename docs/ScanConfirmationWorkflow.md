# Card-show scan workflow

## Behavior implemented on this branch

Home has **Start New Scan** (game picker, new timestamped list, live camera) and **Open Existing List**. Settings is in the toolbar. Existing lists can be reviewed or continued, including completed sessions and standalone single-game lists. Continuing requires confirmation before finishing another active session, without deleting its data; the service also enforces this acknowledgment. Mock scanning requires an explicit choice under Developer Testing.

Recognition code, its module graph, and scalar/SIMD OpenCV builds are bundled in `Resources/ScannerRuntime`. A loopback-only server exposes those assets to WebKit on a stable local origin, preserving the selected game's existing IndexedDB pack cache across app launches. The remote quick-scanner page is no longer loaded. `manifest.json` records exact upstream URLs, retrieval date and SHA-256 values. Source comments are retained. One recorded adaptation adds `resolveCandidates=false` to bypass CDN/image-assisted reranking, preserving local hash candidates and the captured thumbnail for manual confirmation. The existing user authorization for this integration remains established.

The selected game's recognition pack downloads from the existing static host and retains its original integrity checks, cache implementation and offline fallback. Prices are looked up separately through the existing anonymous catalog-detail endpoint, using the exact printing plus `language|condition` quote. No credentials or historical catalog responses are bundled. Offline price storage remains out of scope. Card artwork URLs may still require network access; the captured camera thumbnail is kept for review in memory.

Each full recognition freezes the confirmation view, with alternatives/reprints, captured thumbnail when supplied, default Near Mint, and market value only. Changes to match/printing/condition clear the old price and start an online lookup. Stale responses cannot overwrite a later selection. Missing prices remain unavailable, with refresh and an explicit option to confirm unpriced. Ambiguous finishes need explicit selection/confirmation. There is no automatic addition, even if an older installation had enabled it.

A successful Confirm & Add appends a distinct quantity-one row and releases the review. Failure keeps the pending selection and permits retry. Double taps and subsequent frames cannot append a second row. After saving, remove the card for the next recognition, or intentionally choose **Scan Next Card** for an identical physical copy. **Discard & Scan Again** abandons an incorrect snapshot. Pending review survives screen/background stop/restart within the current view; an unconfirmed review is not persisted across app termination.

New scan rows use strictly increasing `addedAt` timestamps with an ID tie-breaker for historical ties. Review defaults to Scan Order; CSV, duplication and saved offer lines use the same order. Editing a row never merges it into another matching row. The existing storage schema is unchanged. Historical merged quantities remain intact: the original physical scan order cannot be recovered from already merged data.

## Validation

Run:

```bash
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
xcodebuild test -project CardShowScanner.xcodeproj -scheme CardShowScanner -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Choose an available simulator name on your Mac. The pull-request workflow chooses an available iPhone automatically. Simulator tests cover persistence, freeze/retry behavior, exact condition quote parsing, separate duplicate rows, reopened order and session continuation. JavaScript tests use fake camera/module objects; they do not establish recognition accuracy.

Required real-iPhone checks before using with customers:

1. Launch Start New Scan; verify no mock result and the local WebKit camera permission/startup path. Verify local-origin camera security, worker/OpenCV startup, and large pack memory usage.
2. Download Pokémon; scan a real card. Compare captured image, candidate/reprint identities and accuracy. Test the other supported games separately.
3. Hold a recognition while moving the camera to another card: the review must not change. Check alternative selection and each condition's online market value/SKU. Test denied permission, network failure and unavailable quotes.
4. Confirm A, B, A as three distinct rows; remove each card between scans. Test intentional identical copies with Scan Next Card. Review physical-stack order, background/resume, completed/standalone list continuation and CSV.
5. Close and reopen the app without connectivity after a successful database download. Recognition startup and cached-pack behavior are required to work, but are **not yet device-verified**. Prices should clearly be unavailable. Do not describe offline recognition as production-ready until this passes.

No successful Xcode build or iPhone validation is implied by Linux grammar/JavaScript checks.

## Recovery and verification for this continuation

The prior workspace commits `3a369dc` and `c6538bf` were not present in the available checkout or advertised remote branches. Inspection found the substantial implementation at remote commit `225ac77` on `codex/scan-confirmation-flow`, already associated with PR #1; this work continues that branch rather than recreating its bundled assets.

Further fixes remove the editor's residual merge path, require explicit service-level acknowledgment of switching active lists, clear the editor's price/SKU on a condition change, preserve diagnostics, and test stale pricing, partially mutated failed-save rollback, same-identity edits, legacy quantities, saved offers and list resumption.

Passed: 16 JavaScript tests, including actual packaged scalar/SIMD WASM initialization, synthetic hash/match and blank-frame pipeline rejection; 2 signing-helper tests; 47-asset integrity/dependency checks; Swift grammar and Xcode source/test/resource membership checks. The scalar and SIMD runtimes are isolated in separate Node processes, matching the app's one-build-per-JavaScript-realm design.

There are 33 native tests supplied. `xcodebuild` was attempted and is unavailable on this Linux machine (exit 127), so neither a native build nor native test pass is claimed. Physical-iPhone checks remain unverified. Cached files, Node initialization and mocked camera callbacks are not evidence of offline iPhone scanning. Use the steps above and attach diagnostic/native test results to PR #1 when a Mac/iPhone is available.

## Full-screen camera UI

Live camera fills the scanner edge-to-edge; it is no longer a fixed-height panel in a scrolling page. Floating controls provide back, pause/resume, game/provider options and retry. The bottom overlay shows market-only batch totals, list review, finish, and an explicit next-card action after saving. Mock mode remains explicitly labeled and lives under Developer Testing.

Recognition presents a medium/large draggable confirmation sheet over the camera. Candidate/printing/condition and market-value details scroll inside it; Confirm and Discard stay pinned. Swipe dismissal is disabled so a pending result cannot be abandoned accidentally. Saving or discarding closes the review and returns to the full camera. Camera backgrounding/navigation guards are retained. Native rendering, safe-area layout, rotation, larger text and sheet behavior still require an iPhone/Xcode check.
