> **2026-10-22 workflow update:** The scan-confirmation branch replaces the remote scanner page with bundled recognition assets, defaults to live scanning, requires review/confirmation, looks up exact condition prices online, and preserves separate duplicate rows in scan order. See [current workflow and validation](docs/ScanConfirmationWorkflow.md). Earlier implementation notes below describe the previous behavior where they conflict. Native build and real-iPhone validation are still required.

# Card Show Scanner — Sessions v1

Native SwiftUI/SwiftData iPhone app, iOS 17+. One persistent batch session at a time, offline card lists, a Review & Offer calculator, CSV sharing, local diagnostics, and selectable mock / experimental TCGTracking scanning. A session is a general scanning batch, not a purchase transaction.

The user confirmed permission for the TCGTracking integration. No third-party code, assets, databases or credentials are bundled. The live adapter uses observed website module exports and remains experimental; no official stable API is claimed.

## Build and run

Open `CardShowScanner.xcodeproj` in Xcode 16+, select the shared **CardShowScanner** scheme and an iPhone simulator, then Run (⌘R). For a physical iOS 17+ phone, select your signing team under Signing & Capabilities. No Swift packages or server are needed for mock mode. Use a physical iPhone to test live camera scanning.

Tests: ⌘U, or choose an installed simulator from `xcrun simctl list devices available`:

```sh
xcodebuild -project CardShowScanner.xcodeproj \
  -scheme CardShowScanner -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -derivedDataPath /tmp/CardShowScannerDerivedData test
```

Use the existing checkout for development. Cloud tasks already have isolated workspaces; no additional worktree is needed.

## Batch workflow and UI

1. **Home:** select a game and explicitly tap **Start New Session**. This creates one timestamped list and its associated active session. The selected game is remembered. Launching or reopening the app does not create a session or list.
2. **Current Session:** Home displays the active game, original timestamp, editable list name, quantity, known market subtotal and missing-price warning. Choose **Continue Scanning** or **View List & Offers**. An unfinished session remains resumable regardless of age.
3. **Scanner:** choose **Mock** or **TCGTracking (experimental)**. Review up to five candidates and select a printing. A confident, unambiguous result permits one-tap addition; ambiguous matches require candidate selection, and ambiguous printings require explicit finish confirmation. Each manual add is one intentional physical copy. A pinned footer shows current batch quantity, known market and cash subtotals, missing-price count and the review link.
4. **Review & Offer:** search/sort/edit cards, adjust quantities/conditions/prices, see separate market/cash/trade/maximum-buy values, edit session percentages, save immutable offer estimates, rename the list or export CSV. Offers use actual current list quantities. The cash and trade offers are alternatives.
5. **Finish Session:** marks the batch Completed and keeps its list and estimates. Starting another session while one is active requires explicit finish-and-start confirmation. Changing games in the scanner uses the same confirmation and creates a separate list.
6. **All Sessions / All Lists:** revisit completed batches or existing lists. Completed lists remain editable/exportable, but cannot receive scanner additions. Original pre-batch sessions remain historical records with their original totals. Standalone lists remain accessible without an inferred session association.

Pause, screen lock/backgrounding and navigation stop capture. Returning resumes the same batch and game; live mode may require another Start Camera tap. No automatic camera activation occurs merely by opening Home. Session deletion is not offered; manually deleting a list requires confirmation, clears its active association and preserves its session record and saved estimates. Duplicating a list copies cards/overrides but does not create another active batch.

### Mock scanning

The orange banner explicitly states **MOCK SCANNER • No camera or live prices**. A new synthetic result arrives approximately every six seconds, with repeated-frame updates between results. Samples include five candidates, confidence levels, duplicates, finishes and missing prices. Prices are illustrative. Images use a native placeholder unless a candidate supplies an image URL.

### Live scanning

Choose the experimental provider, then tap **Download database & Start Camera** in the web panel. The adapter loads the selected game pack, creates the browser backend and overlay, requests the rear camera and forwards recognition to the native candidate/list workflow. Initial database downloads may be large. The phone workflow does not require a desktop.

See [integration findings](docs/TCGTrackingIntegration.md). Device validation of live recognition, pricing, WebKit workers/WASM, caching and large-pack performance is still required.

## Pricing

New batches snapshot global defaults: **70% cash, 80% trade, 75% maximum buy**. A previous single pricing-percentage preference becomes the cash default when available. Global changes affect future batches only; session percentages are independently editable.

The card editor supports nonnegative **USD-per-copy** cash, trade and maximum-buy overrides. Blank means use the session percentage. Overrides apply to the entire exact-identity row, including additional copies. Conflicting overrides must be resolved before editing two rows into the same inventory identity. Duplicating a list preserves overrides. No name-based bulk/EX classification is performed.

Unpriced copies remain unknown and are excluded from all offer calculations, even when an offer override exists. A known price of $0 is distinct from an unavailable price. Partial totals and missing-copy counts remain visible. Offer line totals are rounded to cents after multiplying by quantity, then summed; the market sum is rounded to cents at the end. Editing a card's identity clears the previous price and SKU; the scanner uses a finish's own quote/SKU when available.

Potential gross cash resale spread is known market subtotal minus suggested cash offer. It assumes resale at market and excludes fees, shipping, labor and unsold inventory. It is not net profit or a recorded purchase. Actual-paid accounting and transaction tracking are outside this update.

**Save Offer Estimate** preserves the rates, totals, quantities, market prices and per-card overrides used at that time. Later changes to defaults, session rates, prices, cards or quantities do not alter saved estimates. Saved estimates can be inspected from the review screen.

## Persistence and migration

The same `Library/Application Support/default.store` is retained. `StorageSchema.swift` freezes the original three-model schema and defines a lightweight migration to the batch additions. New fields are optional or have defaults. Legacy lists/cards/history retain their IDs and quantities; legacy records become completed historical records without guessing a list association from a mutable name. Migration creates no batches and never re-adds historical quantities.

The app creates the parent directory before opening SwiftData. If storage/migration fails, an error screen offers diagnostic export. It never deletes the database or silently substitutes memory-only storage. The migration fixture test must still be run in Xcode against the original unversioned schema. Preserve/export valuable existing lists before installing development builds; do not uninstall to resolve a migration error, since that removes local data.

Recognition episodes are separate from inventory identity. Exact inventory identity includes game, product ID, SKU, printing, language and condition. Repeated frames cannot automatically add copies. Manual additions consume the episode too. A consumed-recognition marker persists with the batch to conservatively suppress auto-add of the same card after app/camera restart; seeing a different recognition or a hide/new-card boundary releases it. Two identical physical copies held continuously cannot be distinguished reliably; use **Add Another Copy** intentionally.

## CSV and diagnostics

List CSV sharing/export remains available with app-defined headers: Game, Name, Set, Number, Product ID, SKU ID, Printing, Language, Condition, Quantity, Market Price, Total Value. Unknown prices export as empty cells. Quotes/newlines and spreadsheet formula protection are handled. No TCGTracking CSV import compatibility is claimed. Offer estimates are viewed in-app; they are not added to the card CSV format.

To send a focused log:

1. Settings → Diagnostics → **Clear Diagnostic Log**.
2. Reproduce the workflow or failure.
3. Settings → Diagnostics → **Export Diagnostic Log**.
4. Save/share `CardShowScanner-diagnostics.jsonl` and upload it with a description of what happened.

Recording defaults on and stays local. Two rotating files retain about 512 KB across launches. Events include run/episode identifiers, app/build/OS, startup stages, sampled timings/confidence, add decisions, batch lifecycle, offer snapshot/save outcomes and error categories/codes. Card/list contents, prices, product/SKU IDs, images, credentials, cookies, nonces, raw responses and request URLs are excluded. Turning recording off stops new events; clearing deletes stored events. Exported temporary files are removed when sharing closes; user-saved copies remain under user control.

## Architecture

- `Domain.swift`: card candidates/printing quotes, recognition gate, CSV serialization.
- `Persistence.swift`: SwiftData lists, inventory cards, sessions, offer fields and inventory operations.
- `StorageSchema.swift`: original/current schemas, migration and store initialization.
- `SessionService.swift`: one-active-batch lifecycle, list association, transactional additions, default-rate snapshots and immutable offer saves.
- `OfferCalculator.swift`: Decimal pricing, rounding, overrides and snapshot structures.
- `ScannerProvider.swift`: asynchronous provider contract and mock provider.
- `TCGTrackingScannerProvider.swift` / `Resources/TCGTrackingBridge.js`: isolated experimental WKWebView integration.
- `ScannerViewModel.swift`: recognition confirmation/deduplication and batch additions.
- SwiftUI screens in `CardShowScannerApp.swift`, `ScannerView.swift`, `ListViews.swift`, `SessionReviewView.swift`, and `SettingsView.swift`.
- `DiagnosticLog.swift`: bounded local logging and export.

## Verification status

This update was developed on Linux without Swift, Xcode or an iOS SDK. It has **not been compiled or run on iOS here**. The user previously built and ran the earlier app version; that does not validate these changes.

**11 JavaScript bridge tests pass:**

```sh
node --experimental-vm-modules --test Tests/JavaScript/bridge.test.cjs
```

They use browser/module/camera doubles, not WebKit or the third-party engine. Swift grammar parsing and Xcode project/scheme structural checks pass; these do not type-check SDK APIs or expand SwiftData macros.

**24 native XCTest cases are supplied, not executed here.** The ten new tests cover explicit start/one-active enforcement, finish/replacement, wrong-game/rollback, disk reopen, pricing/quantity/overrides, unpriced vs zero, rounding/input validation, fixed defaults/saved estimates, original unversioned-store migration, and linked-list deletion. Existing candidate, duplicate, CSV, persistence, diagnostic and provider tests remain.

Follow [Sessions v1 device acceptance checks](docs/SessionsV1.md) before relying on the new workflow.

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
