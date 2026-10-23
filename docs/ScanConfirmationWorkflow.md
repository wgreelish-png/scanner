# Card-show scan workflow

## Behavior implemented on this branch

Home has **Start New Scan** (game picker, new timestamped list, live camera) and **Open Existing List**. Settings is in the toolbar. Existing lists can be reviewed or continued, including completed sessions and standalone single-game lists. Continuing requires confirmation before finishing another active session, without deleting its data; the service also enforces this acknowledgment. Mock scanning requires an explicit choice under Developer Testing.

Recognition code, its module graph, and scalar/SIMD OpenCV builds are bundled in `Resources/ScannerRuntime`. A loopback-only server exposes those assets to WebKit on a stable local origin, preserving the selected game's existing IndexedDB pack cache across app launches. The camera does not load the remote quick-scanner page; the separate pricing-only context described below uses its public first-party document. `manifest.json` records exact upstream URLs, retrieval date and SHA-256 values. Source comments are retained. One recorded adaptation adds `resolveCandidates=false` to bypass CDN/image-assisted reranking, preserving local hash candidates and the captured thumbnail for manual confirmation. The existing user authorization for this integration remains established.

The selected game’s recognition pack downloads from the existing static host and retains its original integrity checks and storage schema. Camera startup first attempts a complete validated cached v2/v1 database with zero network fetches. Check Database Updates explicitly checks the index; unchanged shards are retained. Missing or damaged cache entries are repaired. Cache writes/complete markers are awaited and cache failure is visible. Prices are looked up separately through the existing anonymous catalog-detail endpoint, using the exact printing plus `language|condition` quote. The production app includes no credentials or historical catalog responses. A captured public price fixture belongs to the test target only. Offline price storage remains out of scope. Card artwork URLs may still require network access; the captured camera thumbnail is kept for review in memory.

Recognition waits for at least three consistent observations spanning 600 ms when accepted, or 1,500 ms for a stable ambiguous result, with confidence at least 50. A different full winner restarts settling. Slow-frame gaps restart the observation window without losing partial-update metadata. These are review heuristics, not a measured accuracy guarantee. The camera overlay draws the outline without a guessed name or cached NM price.

The full-height candidate sheet freezes the image and up to five matches. A two-column grid shows large 5:7 artwork with name, set, number, printing and selected condition below. Verified 400px CDN artwork is requested for known 200px product URLs. Accessibility text sizes use one column. Every new card starts at Near Mint. Tap the correct match to explicitly confirm and save; no second confirmation is required. Expand Condition & printing to change defaults for this card; touch and hold another match and choose Review printing & condition to inspect its finish before saving. Market value is shown when available, without offer calculations.

An exact quote already loaded for the selected product/printing/condition is retained. Otherwise the confirmation waits at most four seconds for its online quote, then saves unpriced if necessary. Stale responses cannot replace a newer selection or change a saved row. Missing quotes remain unavailable; zero remains a known price. No condition discounts are estimated. HTTP failures log their status code without response content; the latest phone log identifies four HTTP 401 responses. The supplied successful signed-out HAR has no Cookie/Authorization header and uses the genuine Quick Scan first-party origin. The new pricing transport follows that public browser context. Successful live iPhone pricing still needs verification.

A successful candidate tap appends a distinct quantity-one row and releases the review. Failure keeps all selections and permits another tap to retry. Double taps, subsequent frames and a late quote after Discard cannot save a second row. After saving, remove the card for the next recognition, or intentionally choose **Scan Next Card** for an identical physical copy. **Discard & Scan Again** abandons an incorrect snapshot. Review survives background stop/restart within the current view; unconfirmed cards are not persisted across app termination. Camera-track interruption or a rejected scanner operation stops the loop, releases the stream/overlay and offers explicit retry without switching to mock.

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

Choose an available simulator name on your Mac. The pull-request workflow chooses an available iPhone automatically. The supplied native tests cover persistence, freeze/retry behavior, exact condition quote parsing, separate duplicate rows, reopened order and session continuation. JavaScript tests use fake camera/module objects; they do not establish recognition accuracy.

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

Passed: 40 JavaScript tests, including actual packaged scalar/SIMD WASM initialization, synthetic hash/match and blank-frame pipeline rejection; 2 signing-helper tests; 47-asset integrity/dependency checks; Swift grammar and Xcode source/test/resource membership checks. The scalar and SIMD runtimes are isolated in separate Node processes, matching the app's one-build-per-JavaScript-realm design.

There are 42 native tests supplied. `xcodebuild` was attempted and is unavailable on this Linux machine (exit 127), so neither a native build nor native test pass is claimed. Physical-iPhone checks remain unverified. Cached files, Node initialization and mocked camera callbacks are not evidence of offline iPhone scanning. Use the steps above and attach diagnostic/native test results to PR #1 when a Mac/iPhone is available.

## Full-screen camera UI

Live camera fills the scanner edge-to-edge; it is no longer a fixed-height panel in a scrolling page. Floating controls provide back, pause/resume, game/provider options and retry. The bottom overlay shows market-only batch totals, list review, finish, and an explicit next-card action after saving. Mock mode remains explicitly labeled and lives under Developer Testing.

Recognition presents a full-height candidate sheet over the camera. Candidate, printing, condition and market details scroll inside it; Discard and in-progress feedback stay pinned. Tapping a candidate confirms and saves it. Swipe dismissal is disabled so a pending result cannot be abandoned accidentally. Saving or discarding closes the review and returns to the full camera. Camera backgrounding/navigation guards are retained. Native rendering, safe-area layout, rotation, larger text and sheet behavior still require an iPhone/Xcode check.

## Cache, grid and public-request validation

The packaged pricing function runs through `WKWebView.callAsyncJavaScript` in an isolated world on the committed HTTPS Quick Scan document. Page content JavaScript and camera/microphone capture are disabled there. Browser fetch supplies the real first-party context; no Origin, Referer, user-agent, authorization token or cookie value is manufactured. The function rejects redirects and responses over two MB, times out at four seconds, and preserves returned HTTP errors. The recognition engine continues to use the local bundled runtime. Warmup is asynchronous and does not block cached/offline recognition. No sign-in requirement is introduced.

New diagnostic fields distinguish `downloaded_bytes`, `cached_shards`, `source`, `cache` and `persisted`. A short load time alone never proves a download or a durable cache. Real WebKit eviction, disk-full behavior and the pricing view’s native execution remain required iPhone checks.

The captured price-only response tests Nidoran normal NM/LP and reverse NM, selection of the third alternative, and unavailable market fields that must not use direct/live/top-level substitutes. Source checks verify PricingRequest.js is in the app target and the captured response is in the test target only. No raw HAR or credentials are committed.
