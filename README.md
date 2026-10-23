# Card Show Scanner — confirmed physical scans

Native SwiftUI/SwiftData iPhone app, iOS 17+. Open **Start New Scan** to create a timestamped saved list and open the live scanner, or **Open Existing List** to review and append cards. Mock scanning is only an explicit choice under **Developer Testing**; live failures never switch to mock.

## Scan and confirm

Live scanning uses an edge-to-edge camera with floating controls. Matches use a two-column grid with large full-card artwork (one column at accessibility text sizes). A short consistency check filters early guesses before opening a full-height list of possible matches. Tap the correct match to save it and return to the camera; Discard stays pinned. Tentative names and cached prices never flash over the camera. The camera is no longer confined to a small embedded window.

The app bundles camera capture, recognition JavaScript, worker/module dependencies and scalar/SIMD OpenCV (embedded WASM) in `Resources/ScannerRuntime`. A loopback-only asset server supplies a stable local WebKit origin. The selected game’s database is saved to native Application Support files with atomic writes, independently of WebKit quota/eviction. A complete validated database is reused when the camera reopens; existing valid IndexedDB data migrates without redownloading. Scanner options → Check Database Updates explicitly checks updates; missing/damaged files are repaired, and storage failures are shown. Market pricing follows the public Quick Scan browser request flow; offline pricing is deferred.

A settled recognition freezes its image and alternative candidates/reprints. Later frames and hide/refresh events cannot replace that review. Touch and hold a candidate to review its finish, or expand Condition & printing; each new card starts at **Near Mint**. A new selection immediately clears the prior price/SKU, requests the exact returned `language|condition` quote, and ignores stale lookup responses. Zero is a known price; missing quotes show **Price unavailable**, without estimated discounts or an inherited NM price.

**Tapping a candidate is explicit confirmation and saves that card.** There is no second Confirm button. An exact quote already loaded is reused; otherwise pricing has a four-second confirmation deadline and failure saves an unpriced row. Save failure retains the entire selection for retry; only a successful transaction releases the review. Repeated frames and double taps cannot save another row. Remove the card, explicitly **Scan Next Card** for an identical copy, or **Discard & Scan Again** to abandon a result. Confirmation shows market value only. Cash/trade/maximum offers remain in list review.

Every new physical confirmation appends its own quantity-one row: A, B, A remains three rows. Review and CSV default to persisted scan order. Editing never merges rows. Legacy merged quantities are retained as historical rows; the original order of their individual copies is unknown. Existing sessions, list identity, offer snapshots, export, diagnostics, and the unchanged storage migration path are retained. Continuing a different list explains and confirms finishing the other active session.

## Build and tests

Open `CardShowScanner.xcodeproj` in Xcode 16+, select **CardShowScanner**, and Run. Set personal signing using the local configuration instructions below. Use a physical iPhone for live camera verification.

```sh
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
```

**Passed in this Linux workspace:** 49 JavaScript tests (23 bridge, 11 database-cache, 13 public-pricing request and 2 real bundled OpenCV/engine smoke tests); 20 Python helper tests (2 signing, 11 native-failure annotation, 7 simulator crash reporting); Swift grammar parsing; app/test source and bundled-resource membership; 47-asset hash/dependency verification. The real-engine tests initialize each WASM build in an isolated Node process, hash and match synthetic input, and reject an empty frame. They do not exercise an iPhone camera or establish real-card recognition accuracy.

**Native validation:** [macOS CI at `fd3fc62`](https://github.com/wgreelish-png/scanner/actions/runs/40006675280) compiled the test target and passed the unsigned Release iPhone build, but XCTest still aborted before test execution after making all 59 main-actor tests asynchronous. Standard app/test framework runpaths and simulator crash-reason reporting are now configured; a passing follow-up run remains required. Xcode is unavailable locally on Linux. Choose an installed iPhone simulator ID from `xcrun simctl list devices available` on a Mac:

```sh
xcodebuild test -project CardShowScanner.xcodeproj -scheme CardShowScanner \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' CODE_SIGNING_ALLOWED=NO
```

Before relying on this app, complete [the physical-iPhone acceptance checks](docs/ScanConfirmationWorkflow.md): local-origin camera permissions, real engine/worker initialization, a real card scan, downloaded-pack caching/relaunch, exact condition/SKU prices, frozen review, retry/double taps, A-B-A ordering, editing and resumed-list CSV. **Bundling/caching is not verified offline support.** Supplied phone logs show recognition-worker initialization and candidate results; the updated cache, pricing transport and grid still need device validation. Keep existing data installed to test migration; export valuable lists before development upgrades.

## Review, offers and diagnostics

Saved lists retain search, sorting, edits, conditions, quantities, renaming, duplication and native CSV sharing. Offer review retains independent cash/trade/maximum rates, per-card overrides and immutable saved estimates. Scanning does not record a purchase. CSV remains app-defined; TCGTracking import compatibility is unverified.

Settings → Diagnostics can clear/export `CardShowScanner-diagnostics.jsonl`. Logs record startup stages, pricing outcomes, save errors and recognition lifecycle without card/list contents, credentials, raw payloads or images. Upload the exported file with the failed step when reporting device behavior. Unconfirmed review is held in memory across navigation/backgrounding within the current screen; it is not persisted across force-quit.

When running a Debug build on a connected iPhone, these same filtered events also appear live in Xcode's debug console. Press **Shift–Command–Y**, select console output, and filter for **`[CardShowScanner]`**. Keep **Settings → Diagnostics → Record diagnostics** enabled, reproduce the issue, and copy the relevant lines directly. macOS Console can also display them with the connected iPhone selected and the **Diagnostics** category. Release builds retain the file export without the console mirror.

For network debugging, enable **iPhone Settings → Apps → Safari → Advanced → Web Inspector** and **Mac Safari → Settings → Advanced → Show features for web developers**. Mac Safari's **Develop → iPhone** menu can inspect the website running in iPhone Safari. Debug builds also expose the app's recognition and public pricing web views under **CardShowScanner**; inspect the pricing page's **Network → detail.php** entry to compare its actual status, Origin, Referer and response with the working Safari request. Share neither Cookie nor Authorization values. Release builds do not enable app web inspection.

The user's permission for TCGTracking integration remains established. This uses observed module and catalog interfaces, not a claimed stable official API. Asset provenance/adaptations/hashes are recorded in the bundled manifest. Source comments are preserved. See [workflow and device checks](docs/ScanConfirmationWorkflow.md) and [release gates](docs/ReleaseReadiness.md).

## Keep personal signing settings out of Git

The project inherits `Config/Signing.xcconfig`, which optionally includes **`Config/Signing.local.xcconfig`**. The local file is ignored by Git. Set your team there once, rather than selecting a team again in Xcode's project editor. Structural project changes still belong in `project.pbxproj`; do not ignore that file or use skip-worktree/assume-unchanged.

For an existing checkout with local signing edits, **close Xcode** and run these commands from the repository folder. They save the old project and stash its tracked edits before pulling. Do not use them while Git reports an unresolved merge/rebase; resolve that operation first.

```sh
signing_backup=$(mktemp -t CardShowScanner-signing)
cp CardShowScanner.xcodeproj/project.pbxproj "$signing_backup"
git stash push -m "Preserve local Xcode project settings" -- CardShowScanner.xcodeproj/project.pbxproj
git pull origin main
python3 scripts/configure_signing.py --from-project "$signing_backup"
```

Reopen `CardShowScanner.xcodeproj` and build. The backup and any stash remain available for review. Do not reapply the old project wholesale; doing so can remove new source references again. If the backup contains multiple team IDs, the helper asks for an explicit team instead:

```sh
python3 scripts/configure_signing.py --team YOUR_10_CHARACTER_TEAM_ID
```

For a new checkout, use the explicit-team command. The helper is idempotent for the same team and refuses to overwrite a differing local configuration. Edit the local xcconfig directly when switching teams. No Apple account passwords, certificates or provisioning profiles are stored in it. You still need the Apple account available in Xcode and normal device provisioning; this does not change Personal Team expiration limits.

## Latest diagnostics and public pricing

The fresh phone log confirms repeated HTTP 401 price failures after the earlier pricing view was ready. The new HAR confirms a successful signed-out POST to `/newscanplus/api/detail.php`, with the genuine Quick Scan first-party browser origin and no Cookie or Authorization header. Pricing now uses that actual public document context through WebKit, with a bundled request function. It does not add a sign-in requirement, fabricate browser headers, scrape the page, or use remote recognition. The pricing view permits ordinary public-page initialization, waits for document completion and executes the packaged request in the page’s own JavaScript world. Capture is denied and redundant remote OpenCV loads are blocked. Requests use the real candidate batch, a four-second timeout and a two-MB response limit.

`Tests/Fixtures/quickscan-detail.json` contains only the public response, without HAR request headers, cookies or tokens, and belongs to the native test target only. Tests cover selecting Nidoran instead of the first guess, exact condition/printing/SKU quotes and missing `market_price` fields despite other price fields being present. A passing fixture/request test is not a verified successful live iPhone price lookup.

## Build 2: native storage, portrait and negotiated offers

The fresh device log confirms WebKit cache writes failed after an 8.3 MB download and the previous pricing view still received 401. Build 2 uses an authenticated loopback API to store opaque database records in the app’s dedicated Application Support directory; filenames are hashes, writes are atomic, limits are bounded and reconstructable files are excluded from backups. This changes downloaded recognition data only, never saved lists or SwiftData stores. Initial migration/download may still be needed once; subsequent complete-cache reopens should report `cache_backend=native`, `source=cache`, `downloaded_bytes=0`. Disk-full/cache errors remain visible; clearing cache reports failures instead of claiming success.

The app is portrait-only. List review includes **Custom cash offer**, a whole-list USD amount independent of market prices, rates and per-card overrides. Blank uses calculated cash, zero is valid, and **Save Offer Estimate** preserves the selected amount. Old saved estimates decode without it. The selected cash total and difference from calculated cash are displayed; no SwiftData schema change was made.

Pricing uses ordinary public Quick Scan initialization and sends actual candidate refs together. Diagnostic errors classify the server’s rejection into a fixed set of reasons without logging raw responses, tokens or card contents. Build 2 phone logs still show HTTP 401 classified as authentication required; successful in-app pricing remains unresolved.

Build 3 reports revision `native-cache-alias-inspection`. It accepts valid cached records through equivalent iOS directory paths and reports native inventory counts. Phone logs from build 2 show successful writes followed by another download, so successful zero-download reopening still requires device verification. Those logs also show public-page HTTP 401 responses classified as authentication required, while the user confirms signed-out Safari pricing works. The URL is already the same `detail.php` endpoint; inspect the failing app request with Safari Web Inspector before claiming the pricing issue resolved.
