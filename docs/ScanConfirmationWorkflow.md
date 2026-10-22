# Card-show scan workflow

## Behavior implemented on this branch

Home has **Start New Scan** (game picker, new timestamped list, live camera) and **Open Existing List**. Settings is in the toolbar. Existing lists can be reviewed or continued, including completed sessions and standalone single-game lists. Continuing finishes any other active session without deleting its data. Mock scanning requires an explicit choice under Developer Testing.

Recognition code, its module graph, and scalar/SIMD OpenCV builds are bundled in `Resources/ScannerRuntime`. A loopback-only server exposes those assets to WebKit on a stable local origin, preserving the selected game's existing IndexedDB pack cache across app launches. The remote quick-scanner page is no longer loaded. `manifest.json` records exact upstream URLs, retrieval date and SHA-256 values. Source comments are retained. One recorded adaptation adds `resolveCandidates=false` to bypass CDN/image-assisted reranking, preserving local hash candidates and the captured thumbnail for manual confirmation. The existing user authorization for this integration remains established.

The selected game's recognition pack downloads from the existing static host and retains its original integrity checks, cache implementation and offline fallback. Prices are looked up separately through the existing anonymous catalog-detail endpoint, using the exact printing plus `language|condition` quote. No credentials or historical catalog responses are bundled. Offline price storage remains out of scope. Card artwork URLs may still require network access; the captured camera thumbnail is kept for review in memory.

Each full recognition freezes the confirmation view, with alternatives/reprints, captured thumbnail when supplied, default Near Mint, and market value only. Changes to match/printing/condition clear the old price and start an online lookup. Stale responses cannot overwrite a later selection. Missing prices remain unavailable, with refresh and an explicit option to confirm unpriced. Ambiguous finishes need explicit selection/confirmation. There is no automatic addition, even if an older installation had enabled it.

A successful Confirm & Add appends a distinct quantity-one row and releases the review. Failure keeps the pending selection and permits retry. Double taps and subsequent frames cannot append a second row. After saving, remove the card for the next recognition, or intentionally choose **Scan Next Card** for an identical physical copy. **Discard & Scan Again** abandons an incorrect snapshot. Pending review survives screen/background stop/restart within the current view; an unconfirmed review is not persisted across app termination.

New scan rows use strictly increasing `addedAt` timestamps with an ID tie-breaker for historical ties. Review defaults to Scan Order; CSV, duplication and saved offer lines use the same order. The existing storage schema is unchanged. Historical merged quantities remain intact: the original physical scan order cannot be recovered from already merged data.

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
