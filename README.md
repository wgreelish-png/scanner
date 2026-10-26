# Card Show Scanner — confirmed physical scans

Native SwiftUI/SwiftData iPhone app, iOS 17+. **Start New Scan** immediately finishes any active session, creates a timestamped saved list and opens the live scanner without a confirmation dialog. Previous lists and saved offers remain available through **Open Existing List** for review or continued scanning. Mock scanning is only an explicit choice under **Developer Testing**; live failures never switch to mock.

Before the first live scan, **Connect TCGTracking** offers native username/password fields or **Use the Website Instead**. **Remember sign-in on this iPhone** opts into device-only Keychain storage and a single automatic sign-in attempt on later connection visits. **Forget Saved Sign-In** removes that record. The helper follows the website's actual Login link, fills only a uniquely identified first-party POST login form and submits normally, preserving its verification and hidden fields. Unsupported forms stay on the website; failed logins never loop. Choose **Continue to Scanner** without prices at any time. Setup acknowledgment and form submission never claim successful authentication.

The website session is remembered in WebKit's persistent store. Settings, scanner options and rejected-price review reopen the connection screen. Its fixed, full-width Return button ends editing and closes the presenting cover in one action; scanner startup waits for dismissal. Returning preserves the frozen card, printing and condition and retries the exact quote.

## Scan and confirm

Live scanning uses an edge-to-edge camera with floating controls. Matches use a two-column grid with large full-card artwork (one column at accessibility text sizes). A short consistency check filters early guesses before opening a full-height list of possible matches. Tap the correct match to save it and return to the camera; Discard stays pinned. Tentative names and cached prices never flash over the camera. The camera is no longer confined to a small embedded window.

The app bundles camera capture, recognition JavaScript, worker/module dependencies and scalar/SIMD OpenCV (embedded WASM) in `Resources/ScannerRuntime`. A loopback-only asset server supplies a stable local WebKit origin. The selected game’s database is saved to native Application Support files with atomic writes, independently of WebKit quota/eviction. A complete validated database is reused when the camera reopens; existing valid IndexedDB data migrates without redownloading. Scanner options → Check Database Updates explicitly checks updates; missing/damaged files are repaired, and storage failures are shown. Market pricing follows the public Quick Scan browser request flow; offline pricing is deferred.

A settled recognition freezes its image and alternative candidates/reprints. Later frames and hide/refresh events cannot replace that review. The **Condition** dropdown is always visible above the matches, and each match has its own **Type / printing** dropdown. Choose these before tapping the card to add it; opening or changing a dropdown never saves. Condition applies to whichever match you add, while printing stays specific to its card. Each new card starts at **Near Mint**. A new selection immediately clears the prior price/SKU, requests the exact returned `language|condition` quote, and ignores stale lookup responses. Zero is a known price; missing quotes show **Price unavailable**, without estimated discounts or an inherited NM price.

**Tapping a candidate is explicit confirmation and saves that card.** There is no second Confirm button. An exact quote already loaded is reused; otherwise pricing has a four-second confirmation deadline and failure saves an unpriced row. Save failure retains the entire selection for retry; only a successful transaction releases the review. Repeated frames and double taps cannot save another row. Remove the card, explicitly **Scan Next Card** for an identical copy, or **Discard & Scan Again** to abandon a result. Confirmation shows market value only. Cash/trade/maximum offers remain in list review.

Every new physical confirmation appends its own quantity-one row: A, B, A remains three rows. Review and CSV default to persisted scan order. Editing never merges rows. Legacy merged quantities are retained as historical rows; the original order of their individual copies is unknown. Existing sessions, list identity, offer snapshots, export, diagnostics, and the unchanged storage migration path are retained. Continuing a different list explains and confirms finishing the other active session.

From list review, **Search & Add Card** searches the downloaded game catalog as you type. Up to five matches appear with large artwork previews; add a number or set to narrow them (`Darkrai` → `Darkrai 99` → `Darkrai 99 Triumphant`). Select a preview, choose printing and condition, then explicitly **Add to List**. This appends one physical copy without opening the camera. Text lookup uses saved metadata; artwork and exact market quotes may need internet. See [manual catalog search and the later phone check](docs/ManualCardSearch.md).

## Build and tests

Open `CardShowScanner.xcodeproj` in Xcode 16+, select **CardShowScanner**, and Run. Set personal signing using the local configuration instructions below. Use a physical iPhone for live camera verification.

For the final personal-use installation, select **CardShowScanner Personal**: Run uses Release without attaching a debugger, with the same bundle ID and your ignored signing configuration. [Final phone test and weekly Personal Team refresh](docs/PersonalIPhone.md) explains how to keep the app/data installed; free signing normally expires after seven days.

```sh
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
```

**Passed in this Linux workspace:** 75 JavaScript tests (35 bridge, 11 database-cache, 13 public-pricing request, 13 website sign-in form, 2 real bundled OpenCV/engine smoke tests and 1 quick-scan diagnostic test); 20 Python helper tests (2 signing, 11 native-failure annotation, 7 simulator crash reporting); Swift grammar parsing; app/test source and bundled-resource membership; 47-asset hash/dependency verification. Bridge tests include the four-second card-presence timeout, brief tracking loss, empty-camera behavior, same-attempt suppression, popup/confirmation races and resume without camera reacquisition. The real-engine tests initialize each WASM build in an isolated Node process, hash and match synthetic input, and reject an empty frame. They do not exercise an iPhone camera or establish real-card recognition accuracy.

**Native validation:** [macOS CI at `48d50a3`](https://github.com/wgreelish-png/scanner/actions/runs/40404140351) passed all 146 native cases, the end-to-end swipe-delete simulator UI test and the unsigned Personal-scheme Release iPhone build. New cases verify alternative-match dropdowns preserve exact condition/printing/price/SKU and populate catalog printing choices without mutating the frozen candidate snapshot. Existing native catalog search, stale replies, duplicate rows, failed-save retry, session/offer preservation, deletion rollback, local-server, permission, Keychain, offers and migration regressions also pass. The simulator-only workaround for the [iOS 18.4/18.5 Swift WebKit Cryptex defect](https://github.com/WebKit/WebKit/pull/46146) is working. Xcode is unavailable locally on Linux. Choose an installed iPhone simulator ID from `xcrun simctl list devices available` on a Mac:

```sh
xcodebuild test -project CardShowScanner.xcodeproj -scheme CardShowScanner \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID'
```

Keep normal simulator signing enabled for Keychain tests. CI generates temporary simulator-only application/keychain entitlements and ad-hoc signs its test host without an Apple account; the Release iPhone compile remains unsigned. Personal signing configuration is unchanged.

Before relying on this app, complete [the physical-iPhone acceptance checks](docs/ScanConfirmationWorkflow.md). **Bundling/caching is not verified offline support.** The October 23 build-4 phone log confirms worker/camera startup, 426 cached shards with zero downloaded bytes, HTTP 200 pricing and a priced card saved. Repeated pricing, exact condition changes, offline relaunch, native remembered sign-in and single-tap return still require device checks. Keep existing data installed to test migration; export valuable lists before development upgrades.

Build 7 fixes condition-price refreshes in Edit Card, reuses exact catalog condition quotes in both review screens, populates Type / printing dropdowns and repairs the list-delete confirmation target. See [the changes and short phone check](docs/ConditionPricingFixes.md). Recognition code and camera settings are unchanged.

Build 8 repairs local-server startup recovery and adds sampled border/lighting diagnostics plus **Mark Scan Issue** actions. Recognition thresholds, matching, camera settings and confirmation behavior are unchanged. See [the later phone test and logging guide](docs/StartupRecoveryDiagnostics.md).

Build 10 adds the manual catalog search above and includes the swipe-delete repair: normal and full swipes keep their gestures, confirmation uses a stable list ID, and failed deletion restores the live relationships for retry. See [swipe deletion validation](docs/SwipeListDeletion.md). No upstream recognition-engine refresh or top-loader detection change is included.

Build 11 makes condition and per-match printing menus visible directly on scan confirmation. The existing batch detail response populates printing choices for every frozen match, including alternatives whose downloaded metadata initially lists only Normal. After four seconds of an observed card without a settled result, the scanner offers **Search Manually** or **Keep Scanning**. Search opens the existing catalog for the same list and stops camera capture until you close it. Keep Scanning resumes without reopening the camera or repeatedly prompting for that attempt. A Search Manually button is also available when no border can be detected. See [the short phone check](docs/ScanConfirmationWorkflow.md#build-11-phone-check). Recognition thresholds and camera settings are unchanged.

## Review, offers and diagnostics

Saved lists retain search, sorting, edits, conditions, quantities, renaming, duplication and native CSV sharing. Offer review retains independent cash/trade/maximum rates, per-card overrides and immutable saved estimates. Scanning does not record a purchase. CSV remains app-defined; TCGTracking import compatibility is unverified.

Offer review leads with **My Card Price** and a prominent **Customer Pays You**, **You Pay Customer**, **Even Trade** or **Unused Trade Credit** result. Choose Cash Only, Trade + Cash or Trade Credit Only. Adjusting **Custom cash offer** updates the selected whole-list cash value and its unused-trade payout immediately; clearing it restores calculated cash. Transaction Math shows configured and applied cash/trade percentages. It recalculates from already-scanned values without fetching prices. Saved estimates preserve their original inputs, cash basis and results in optional JSON without a schema migration. See [trade calculations, examples and allocation assumptions](docs/TradeTransactions.md).

Offer controls have explicit independent tap targets; scanner/saved-estimate routes are registered outside lazy List rows. Reviews opened from the camera return to that same scanner on Continue Scanning. The scanner alone may reuse native camera authorization for its exact active local main frame and video-only capture; other origins, subframes and audio are denied. First-time native requests are coalesced, and denied/revoked access requires the user's Settings change. Pricing and sign-in pages remain unable to capture media.

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

Earlier phone logs show HTTP 401 price failures after the pricing view was ready. The supplied HAR establishes the successful POST URL, candidate payload and response, but its omitted cookies do not establish anonymous access. Subsequent user-provided headers show the same first-party `detail.php` request returning 401 and later 200. The user reports an in-app price without signing in, and different private-browser behavior on iPhone and Chrome. A universal login requirement is not established; the app now provides an explicit connection/sign-in step at the user's request.

Pricing uses the actual Quick Scan document context through WebKit, with a bundled request function. The visible connection browser and hidden pricing page share the default persistent website store. Returning invalidates the old pricing document, pending startup and old response generations; the next request prepares a fresh document with the current website session. The app does not fabricate browser headers or use remote recognition. Capture is denied and redundant remote OpenCV loads are blocked in the pricing page. Requests use the real candidate batch, a four-second timeout and a two-MB response limit. Native sign-in passes user-entered details as structured JavaScript arguments to the visible website's guarded form helper. Remembered credentials use `WhenUnlockedThisDeviceOnly` Keychain storage with synchronization disabled. Credentials, cookies and form values never enter diagnostics or fixtures.

`Tests/Fixtures/quickscan-detail.json` contains only the public response, without HAR request headers, cookies or tokens, and belongs to the native test target only. Tests cover selecting Nidoran instead of the first guess, exact condition/printing/SKU quotes and missing `market_price` fields despite other price fields being present. A passing fixture/request test is not a verified successful live iPhone price lookup.

## Build 2: native storage, portrait and negotiated offers

The fresh device log confirms WebKit cache writes failed after an 8.3 MB download and the previous pricing view still received 401. Build 2 uses an authenticated loopback API to store opaque database records in the app’s dedicated Application Support directory; filenames are hashes, writes are atomic, limits are bounded and reconstructable files are excluded from backups. This changes downloaded recognition data only, never saved lists or SwiftData stores. Initial migration/download may still be needed once; subsequent complete-cache reopens should report `cache_backend=native`, `source=cache`, `downloaded_bytes=0`. Disk-full/cache errors remain visible; clearing cache reports failures instead of claiming success.

The app is portrait-only. List review includes **Custom cash offer**, a whole-list USD amount independent of market prices, rates and per-card overrides. Blank uses calculated cash, zero is valid, and **Save Offer Estimate** preserves the selected amount. Old saved estimates decode without it. The selected cash total and difference from calculated cash are displayed; no SwiftData schema change was made.

Pricing uses ordinary public Quick Scan initialization and sends actual candidate refs together. Diagnostic errors classify the server's rejection into a fixed set of reasons without logging raw responses, tokens or card contents. Build 2 phone logs show HTTP 401 classified as authentication required; that server message alone does not prove a login requirement.

Build 3 reports revision `native-cache-alias-inspection`. It accepts valid cached records through equivalent iOS directory paths and reports native inventory counts. Build-2 logs showed writes followed by another download; the later build-4 phone log confirms native-cache reuse with zero downloaded bytes. Debug builds expose both web views to Safari Web Inspector. The successful priced scan establishes one working flow; repeated and offline acceptance remains required.

Build 4 reports revision `pricing-connection-save-retry`. It adds the website connection step and exact-quote retry described above. Main-window navigation stays on the HTTPS TCGTracking website; external identity-provider redirects are not implemented and require device review if the site's login uses them. Failed scan saves explicitly remove only their new card rows and restore session counters, keeping the frozen selection, saved offers and unrelated pending edits. An invalid replacement game is rejected before finishing the current session. Native regressions check that failure leaves no card row and a retry adds exactly one.
