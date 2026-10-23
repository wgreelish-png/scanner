# Card Show Scanner — confirmed physical scans

Native SwiftUI/SwiftData iPhone app, iOS 17+. Open **Start New Scan** to create a timestamped saved list and open the live scanner, or **Open Existing List** to review and append cards. Mock scanning is only an explicit choice under **Developer Testing**; live failures never switch to mock.

## Scan and confirm

Live scanning uses an edge-to-edge camera with floating controls. Recognized cards open a draggable confirmation sheet; Confirm/Discard remain pinned while you review details. The camera is no longer confined to a small embedded window.

The app bundles camera capture, recognition JavaScript, worker/module dependencies and scalar/SIMD OpenCV (embedded WASM) in `Resources/ScannerRuntime`. A loopback-only asset server supplies a stable local WebKit origin. The selected game's database downloads/caches using the packaged pack loader. Market pricing uses the online catalog; offline pricing is deferred.

A recognition freezes its image, suggested card and alternative candidates/reprints. Later frames and hide/refresh events cannot replace that review. Select the candidate, finish and condition; each new card starts at **Near Mint**. A new selection immediately clears the prior price/SKU, requests the exact returned `language|condition` quote, and ignores stale lookup responses. Zero is a known price; missing quotes show **Price unavailable**, without estimated discounts or an inherited NM price.

**Confirm & Add** is the only save action. Save failure retains the entire selection for retry; only a successful transaction releases the review. Repeated frames and double taps cannot save another row. Remove the card, explicitly **Scan Next Card** for an identical copy, or **Discard & Scan Again** to abandon a result. Confirmation shows market value only. Cash/trade/maximum offers remain in list review.

Every new physical confirmation appends its own quantity-one row: A, B, A remains three rows. Review and CSV default to persisted scan order. Editing never merges rows. Legacy merged quantities are retained as historical rows; the original order of their individual copies is unknown. Existing sessions, list identity, offer snapshots, export, diagnostics, and the unchanged storage migration path are retained. Continuing a different list explains and confirms finishing the other active session.

## Build and tests

Open `CardShowScanner.xcodeproj` in Xcode 16+, select **CardShowScanner**, and Run. Set personal signing using the local configuration instructions below. Use a physical iPhone for live camera verification.

```sh
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
```

**Passed in this Linux workspace:** 16 JavaScript tests (14 adapter tests and 2 real bundled OpenCV/engine smoke tests); 2 Python signing-helper tests; Swift grammar parsing; app/test source and bundled-resource membership; 47-asset hash/dependency verification. The real-engine tests initialize each WASM build in an isolated Node process, hash and match synthetic input, and reject an empty frame. They do not exercise an iPhone camera or establish real-card recognition accuracy.

**Unrun:** 33 native XCTest cases, Xcode build, and physical-iPhone acceptance. Attempting `xcodebuild` here returns `command not found`. The PR includes a macOS workflow; no passing CI result is claimed. Choose an installed iPhone simulator ID from `xcrun simctl list devices available` on a Mac:

```sh
xcodebuild test -project CardShowScanner.xcodeproj -scheme CardShowScanner \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' CODE_SIGNING_ALLOWED=NO
```

Before relying on this app, complete [the physical-iPhone acceptance checks](docs/ScanConfirmationWorkflow.md): local-origin camera permissions, real engine/worker initialization, a real card scan, downloaded-pack caching/relaunch, exact condition/SKU prices, frozen review, retry/double taps, A-B-A ordering, editing and resumed-list CSV. **Bundling/caching is not verified offline support.** No successful iPhone scan is claimed for this implementation. Keep existing data installed to test migration; export valuable lists before development upgrades.

## Review, offers and diagnostics

Saved lists retain search, sorting, edits, conditions, quantities, renaming, duplication and native CSV sharing. Offer review retains independent cash/trade/maximum rates, per-card overrides and immutable saved estimates. Scanning does not record a purchase. CSV remains app-defined; TCGTracking import compatibility is unverified.

Settings → Diagnostics can clear/export `CardShowScanner-diagnostics.jsonl`. Logs record startup stages, pricing outcomes, save errors and recognition lifecycle without card/list contents, credentials, raw payloads or images. Upload the exported file with the failed step when reporting device behavior. Unconfirmed review is held in memory across navigation/backgrounding within the current screen; it is not persisted across force-quit.

The user's permission for TCGTracking integration remains established. This uses observed module and catalog interfaces, not a claimed stable official API. Asset provenance/adaptations/hashes are recorded in the bundled manifest. Source comments are preserved. See [workflow and device checks](docs/ScanConfirmationWorkflow.md).

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
