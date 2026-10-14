# Card Show Scanner

Native iPhone MVP in SwiftUI and SwiftData, targeting iOS 17+. **Two selectable providers: offline mock and experimental live TCGTracking.** The user has confirmed permission for this integration. No third-party scanner code, assets, databases, or credentials are bundled. All mock names and prices are illustrative, not current market quotes.

## Run on a Mac

1. Use Xcode 16 or newer with an iOS simulator runtime installed.
2. Open `CardShowScanner.xcodeproj` and select the shared **CardShowScanner** scheme.
3. Choose an iPhone simulator and Run (⌘R). No packages, account, server, or credentials are required for mock scanning.
4. For a physical iPhone, select your own signing team in the application target's Signing & Capabilities settings, choose a unique bundle ID if necessary, and run on an iOS 17+ device.
5. Run tests with ⌘U. For command-line testing, choose an installed simulator from `xcrun simctl list devices available`, then run:

```sh
xcodebuild -project CardShowScanner.xcodeproj \
  -scheme CardShowScanner -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -derivedDataPath /tmp/CardShowScannerDerivedData test
```

The repository contains a directly openable project; no project generator is needed. Use the existing checkout for development; cloud tasks already have isolated workspaces and do not need additional worktrees.

## Try the workflow

Create a list from **Start Scanning**, then select it. The orange mock banner stays visible. A new synthetic card arrives every six seconds, with repeated frames in between. Pause to review at your own pace. Select among five candidate buttons; ambiguous or low-confidence results require an explicit selection before adding. Select a printing, tap **Add Selected Card**, then tap **Add Another Copy** only when intentionally adding another physical copy. The camera is intentionally unused by the mock provider. To try live recognition, choose **TCGTracking (experimental)** in the scanner source picker, then tap **Download database & Start Camera** inside its web panel. Initial database downloads may be large. This live path is implemented but has not been validated on an iPhone.

Open the list to search, sort, edit a card, change quantities, or correct its identity. Swipe a card to remove it. List menu actions rename, save CSV, and open the native share sheet. Swipe a saved list to duplicate or delete it. Delete requires confirmation. Settings control default game, condition, confident automatic additions, sound, haptics, and a pricing percentage. Session reset is on the active scanner screen and preserves cards and previous session history. No scanner cache is downloaded in mock mode. Live mode uses the website pack loader’s IndexedDB cache; Settings can clear TCGTracking web database/resource caches without deleting lists or cookies.

Prices are USD. Unknown prices remain `nil` and export as empty cells. UI totals are labeled **known subtotal**, with the number of unpriced copies shown. The scanner uses a selected finish’s own quote and SKU when supplied, otherwise its price remains unknown. Manual identity edits clear old quotes and SKU IDs. Candidate confidence is illustrative in mock mode. Card images load only when a candidate or manually edited card provides an image URL; mock cards use a native symbol instead of redistributing third-party images.

## Architecture

- `Domain.swift`: Codable candidates, exact inventory identity, recognition episode gate, and CSV serialization.
- `Persistence.swift`: SwiftData lists, cascade-owned inventory cards, persisted session history, and inventory operations. Inventory and session writes are committed together by the scanner view model.
- `ScannerProvider.swift`: asynchronous provider contract, continuous mock results, and restartable result streams. `TCGTrackingScannerProvider.swift` hosts the experimental live WKWebView adapter; `Resources/TCGTrackingBridge.js` is its app-owned integration layer.
- `ScannerViewModel.swift`: confirmation, episode deduplication, session accounting, user feedback, and persistence errors.
- SwiftUI views: dashboard, scan destination, scanner/candidates, list editor, saved lists, recent sessions, settings, and native CSV sharing.

Inventory merge identity includes game, product ID, SKU, finish, language, and condition. Recognition episode identity is separate: repeated `same` frames cannot automatically add copies. An accepted result needs at least 90% confidence and an unambiguous printing to auto-add. Manual additions also consume the recognition episode, preventing later confidence upgrades from adding another copy. Manual taps always mean one intentional copy. This threshold still requires calibration on real iPhone scans; manual mode is the default. Editing into an already existing exact identity merges quantities. Historical scan-session values are snapshots and do not change when an inventory card is later edited or deleted.

CSV uses explicit app-defined columns (including Language), CRLF records, escaped quotes/newlines, and spreadsheet formula protection. **No TCGTracking import compatibility is claimed.** Exported values are snapshots; no pricing refresh or inventory sync occurs.

## Validation status

This project was created on Linux without Swift, Xcode, an iOS SDK, or a simulator. **It has not been compiled or run on iOS.** Swift grammar parsing passed for all ten Swift source/test files; the Xcode project passed OpenStep parsing and the shared scheme passed XML parsing. These checks do not type-check SDK calls, expand SwiftData macros, run tests, or validate UI behavior.

Twelve XCTest cases are supplied, but **not executed here**, covering:

- Repeated recognition frames versus a new physical-card episode.
- Ambiguous and low-confidence automatic-add rejection.
- Exact duplicates versus different condition/language/printing.
- Candidate confirmation and printing quote invalidation.
- CSV escaping, formula protection, and unknown prices.
- Unknown-price quantity accounting and list duplication.
- Disk-store reopening and cascade deletion.
- Manual-add episode consumption, bridge partial updates/hide/validation, printing quotes and confirmation, and provider stop/restart.

Ten JavaScript adapter tests pass on Node, including module/camera test doubles for startup, result delivery, teardown, backgrounding, and permission denial:

```sh
node --experimental-vm-modules --test Tests/JavaScript/bridge.test.cjs
```

These exercise our adapter, not the third-party engine or WKWebView.

Before using this for a real collection, run the Xcode build/tests and manually verify: create/rename/duplicate/delete lists; five-candidate selection; game switching; pause/resume/background/foreground; both add preferences; condition/quantity edits and merges; partial totals; CSV file and share sheet; dark mode; app termination/relaunch; VoiceOver and larger text. No device validation is claimed.

## TCGTracking integration

The uploaded source files and HAR have now been inspected. The user confirmed permission to proceed. The app implements a same-origin WKWebView module adapter with game-pack loading, camera startup, five detailed candidates, per-finish SKU/price selection, hide events, nonce-bound message validation, and camera teardown. It uses observed module exports rather than website result-DOM scraping or direct endpoint reimplementation.

**The live path is experimental and has not been run on iOS.** No official stable API has been established. See [integration findings, architecture, evidence and device checks](docs/TCGTrackingIntegration.md). No further source files are currently needed. Xcode/device validation is the next required step; no additional permission confirmation is needed unless the user revokes permission.
