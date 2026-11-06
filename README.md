# Card Show Scanner — confirmed physical scans

Native SwiftUI/SwiftData iPhone app, iOS 17+. Build 23 adds a [bottom tab bar and simpler screens](docs/AppNavigation.md): **Lists, Scan, Research and Settings**. The Scan tab opens first; selecting a tab never starts the camera. **Start New Scan** immediately finishes any active session, creates a timestamped saved list and opens the live scanner without a confirmation dialog. Previous lists and saved offers remain available through Lists or **Open Existing List** for review or continued scanning. Mock scanning is only an explicit choice under **Developer Testing**; live failures never switch to mock.

Settings → **TCGTracking sign-in** offers native username/password fields or **Use the Website Instead** for account features. Market pricing uses Open API without website sign-in. **Remember sign-in on this iPhone** opts into device-only Keychain storage and a single automatic sign-in attempt on later connection visits. **Forget Saved Sign-In** removes that record. The helper follows the website's actual Login link, fills only a uniquely identified first-party POST login form and submits normally, preserving its verification and hidden fields. Unsupported forms stay on the website; failed logins never loop. The fixed Done/Return button closes the account connection. Form submission never claims successful authentication.

The website session is remembered in WebKit's persistent store. Settings and scanner options reopen the account connection screen. Its fixed, full-width Return button ends editing and closes the presenting cover in one action; scanner startup waits for dismissal. Returning preserves the current list and session; opening an account connection from scanner Options pauses capture until dismissal.

## Scan and confirm

Live scanning uses an edge-to-edge camera with floating controls. Matches use a two-column grid with large full-card artwork (one column at accessibility text sizes). A short consistency check filters early guesses before opening a full-height list of possible matches. Tap the correct match to save it and return to the camera; Discard stays pinned. Tentative names and cached prices never flash over the camera. The camera is no longer confined to a small embedded window.

The app bundles camera capture, recognition JavaScript, worker/module dependencies and scalar/SIMD OpenCV (embedded WASM) in `Resources/ScannerRuntime`. A loopback-only asset server supplies a stable local WebKit origin. The selected game’s database is saved to native Application Support files with atomic writes, independently of WebKit quota/eviction. A complete validated database is reused when the camera reopens; existing valid IndexedDB data migrates without redownloading. Scanner options → Check Database Updates explicitly checks updates; missing/damaged files are repaired, and storage failures are shown. Market pricing uses the public Open API for exact-condition SKU quotes. Open API can reuse previously downloaded exact-SKU prices from up to four recent sets during connectivity failures, with cached/offline labels and original timestamps.

A settled recognition freezes its image and alternative candidates/reprints. Later frames and hide/refresh events cannot replace that review. The **Condition** dropdown is always visible above the matches, and each match has its own **Type / printing** dropdown. Choose these before tapping the card to add it; opening or changing a dropdown never saves. Condition applies to whichever match you add, while printing stays specific to its card. Each new card starts at **Near Mint**. A new selection immediately clears the prior price/SKU, requests the exact returned `language|condition` quote, and ignores stale lookup responses. Zero is a known price; missing quotes show **Price unavailable**, without estimated discounts or an inherited NM price.

**Tapping a candidate is explicit confirmation and saves that card.** There is no second Confirm button. An exact quote already loaded is reused; otherwise pricing has a four-second confirmation deadline and failure saves an unpriced row. Save failure retains the entire selection for retry; only a successful transaction releases the review. Repeated frames and double taps cannot save another row. Remove the card, explicitly **Scan Next Card** for an identical copy, or **Discard & Scan Again** to abandon a result. Confirmation shows market value only. Cash/trade/maximum offers remain in list review.

Every new physical confirmation appends its own quantity-one row: A, B, A remains three rows. Review and CSV default to persisted scan order. Editing never merges rows. Legacy merged quantities are retained as historical rows; the original order of their individual copies is unknown. Existing sessions, list identity, offer snapshots, export, diagnostics, and the unchanged storage migration path are retained. Continuing a different list explains and confirms finishing the other active session.

From list review, **Search & Add Card** searches the downloaded game catalog as you type. Up to five matches appear with large artwork previews; add a number or set to narrow them (`Darkrai` → `Darkrai 99` → `Darkrai 99 Triumphant`). Select a preview, choose printing and condition, then explicitly **Add to List**. This appends one physical copy without opening the camera. Text lookup uses saved metadata; artwork and exact market quotes may need internet. See [manual catalog search and the later phone check](docs/ManualCardSearch.md).

Build 22 originally added [market evidence summaries and native charts](docs/EvidenceVisualizations.md): exact-SKU price comparisons, selectable sales-volume windows, separate graded daily-price/sales charts, and visible coverage/freshness facts. It preserves daily API caching and existing scanning, inventory and offer behavior.

Build 28 combines Market and Graded Research in [one card page](docs/CombinedCardResearch.md). Printing and language stay shared, Market adds condition choices, and Graded adds grader/grade choices. A compact update label and information sheet replace the large evidence block. Chart enhancements remain deferred.

## Build and tests

Build 85 adds [printer stage timings and cache checks](docs/PrinterStageTimings.md):
preparation, encoding, Bluetooth acknowledgement and printer-response waits,
polling, exact model/command path and intervals between print attempts. Current
custom previews and fresh automatic RFID reads can be reused without changing
saved artwork, stock, settings or the print command pacing.

Build 84 keeps the [printing progress counts](docs/PrintProgressAndConnection.md)
live in the presented screen, starting with the requested batch total and
updating from each saved physical completion receipt.

Build 83 adds [printing progress and return to Price Tags](docs/PrintProgressAndConnection.md).
The progress screen waits for the final job confirmation, then returns to Price
Tags while retaining an idle foreground printer connection. Buffered mixed-label
jobs check available progress immediately after uploading each window.

Build 82 leaves the [price area blank for unavailable or $0 prices](docs/WriteInPriceTags.md)
while still printing the label, ready for a handwritten price. Known positive
prices and saved 2-for-$1 deals keep their usual artwork.

Build 81 gives [every selected inventory copy a tag](docs/AllInventoryCardTags.md),
including the saved 2-for-$1 category. Counts, previews, preparation and print
history include these cards without changing their prices.

Build 80 makes Select Individual Inventory a full-size action beside Print All
in Price Tags, retaining the existing card-selection flow.

Build 79 adds [offline RFID paper detection and generated label layouts](docs/OfflineLabelCatalog.md).
The bundled 13 KB catalog matches roll product codes to dimensions and media,
then fits the existing vector design to the available printable region. Saved
price-side and manual-paper preferences remain available; queued artwork stays
an immutable snapshot.

Build 78 adds an [estimated labels-remaining display](docs/EstimatedLabelCount.md)
from the printer's RFID counters. Reads happen on connection, after printing,
or through Refresh Roll. Unknown or stale counts never block printing.

Build 77 adds a remembered [Price Left / Price Right label option](docs/LabelPricePosition.md).
It swaps the price and PokéDen logo without mirroring their text, shares the
choice across inventory/custom/bulk labels, and preserves already queued art.

Build 76 adds [device health diagnostics and camera heat protection](docs/DeviceHealthMonitoring.md):
foreground-only health summaries, memory/thermal warnings, available iOS crash
and hang report counts, and reduced scanner work in Low Power Mode or elevated
heat. Serious/critical heat pauses capture without changing saved inventory.

Build 75 adds [warm manual-search return and recent scan review](docs/WarmScannerReview.md):
Search Manually is available in Choose the Card, scan-origin catalog entry opens
the keyboard, and returning reuses the loaded camera/database. The expandable
scanner panel shows the list newest first with direct card editing, while a
compact top strip keeps scanner status beside the camera controls.

Build 74 simplifies [inventory label preparation](docs/DirectInventoryLabels.md):
selected price, copies, paper and preview, followed by Prepare Labels. Printing
no longer offers suggested-price actions or requires cost/profit warning
approval. Price edits remain optional and printing remains explicit.

Build 73 adds [buffered continuous label printing](docs/BufferedLabelPrinting.md).
D110-M batches send the next labels before waiting for each physical copy, and
identical consecutive labels use the printer's native copy count. Verified
acknowledged transfers stay in place. Completed copies remain durable; buffered
copies are checked explicitly after interruption. Physical timing needs testing.

Build 72 restores [reliable printer transfers and explicit selected-card
reprints](docs/PrintTransferRecovery.md). Every packet uses the negotiated write
type, including acknowledged raster writes on the verified D110-M. Manually
selected cards can prepare replacement labels even after a prior completed job;
Price Changed retains its automatic skip rule. Physical printing needs a rerun.

Build 71 adds [branded PokéDen price tags](docs/BrandedPriceTags.md): the wordmark,
divider, rounded border and a large whole-dollar price, plus standalone
2-for-$1 bulk-bin tags. This is the default for newly prepared inventory labels;
Card Details remains selectable. The 30 × 15 mm paper option joins existing
sizes, using the supported printer's 12 mm printable strip.

Build 70 removes duplicate card codes from printed label titles, adds direct
approval/preparation from Label Details with optional full review, and puts
Clear Print Queue in the price-tag toolbars. See [label approval and queue
controls](docs/LabelApprovalAndQueueControls.md). Existing saved rasters keep
their original artwork; clear and prepare them again to apply title cleanup.

Build 69 adds [continuous D110-M print batches](docs/ContinuousLabelPrinting.md),
automatic foreground search/reconnection when opening Price Tags and a shared,
remembered physical label size. Each copy still requires a saved physical
completion receipt, and reconnecting never resumes printing. Native execution
and physical batch timing remain to be checked on the phone.

Build 24 adds a [persistent show cash budget](docs/ShowBudget.md): record purchases, sales and cash trades, reinvest 65% of gross receipts, and reserve 35% for yourself. Fees reduce buying funds separately. Open Show Budget from Lists or Scan, or record cash linked to a list from its review screen.

Build 25 adds [automatic Beta IP access](docs/AutomaticBetaIP.md). With a saved Direct connection and matching website sign-in, the app updates this phone’s recorded address while preserving the other allowed addresses (build 33). Checks run only while the app is active and stop when you leave it.

Build 26 adds [compact Card Details](docs/CompactCardDetails.md): artwork, human-readable card identity, prominent per-card market value, quick condition buttons, printing/language menus and quantity. Technical identity fields and the card-level provider picker are removed. Find Correct Card searches the saved catalog, while manual price adjustment and offer overrides are collapsed. Explicit Save/Cancel and the provider selected in Settings are preserved. Chart enhancements are deferred.

Build 27 adds [one standard pricing source](docs/StandardMarketPricing.md): all market quotes use Open API. Provider selectors and the scanner’s first-use website-price sign-in prompt are removed. Existing provider preferences are ignored, while historical saved prices, source metadata and offers remain intact. Account sign-in and Beta API access stay separate; daily caching is unchanged.

Build 29 adds [Card Show inventory import](docs/CardShowInventory.md). Lists → **Card Show Inventory** connects the existing TCGTracking account and imports its exact Card Show location into one saved list. Explicit refresh updates source rows and quantities without duplication; failed/partial refreshes keep the previous copy. Card details, quantities and last imported values stay available offline. An editable duplicate supports local scanning and corrections; the imported list mirrors the website.

Build 30 applies the PokéDen Collectibles logo as the app icon and [streamlines list review](docs/StreamlinedListReview.md). CSV export and offer percentages live in the top-right options menu; outcome buttons join the offer tile, live custom cash and save-estimate controls are removed, and card rows include thumbnails. Research links open TCGplayer listings/history, and show budgets support optional show dates.

Build 31 adds precise [inventory import rejection diagnostics](docs/CardShowInventory.md), separating response validation from authentication and persistence guards without changing saved data or accepting partial imports.

Build 32 adds a dedicated **Show** tab, applies scheduled budgets only on their local show dates, and [records calculated outcome cash automatically](docs/AutomaticOutcomeBudget.md). Open Existing List always returns to the Lists root. Lists now supports multi-select deletion with one confirmation; swipe deletion remains. Public pricing retains its daily set cache.

Build 33 corrects [automatic Beta IP management](docs/AutomaticBetaIP.md): keep all other addresses, replace only this iPhone’s recorded previous IP, and add its current IP when needed. Per-account history stays in device-only Keychain across relaunches; a first run without history only adds the current address. A full allowlist stops with a clear message rather than evicting another entry. [Inventory imports](docs/CardShowInventory.md) decode JSON numeric prices directly as decimals; unusable optional prices become unavailable without blocking valid cards, while identity, quantity and pagination checks stay strict. A [Postman measurement collection](docs/PricingCacheMeasurement.md) measures a sample or full category’s metadata and daily SKU download sizes before planning a larger pricing cache.

Build-33 local checks passed 151 JavaScript tests, 24 pricing-measurement Postman script tests, grammar parsing of 133 Swift files, app/native/UI target membership and all 47 pinned scanner assets. New native inventory/IP cases are registered but have not run locally; Xcode compilation, native tests, live Postman measurements and physical-iPhone import/IP behavior remain unverified for this build.

Build 34 repairs [Opportunities metadata handling](docs/MarketData.md): a structurally unsupported HTTP-200 index no longer blocks an independently validated exact-set lookup. Test Market Activity uses the same complete index validator as lookups, and fixed schema stage/reason/shape diagnostics identify failures without response contents. Daily cache times, HTTP versus data ETags, authentication and rate limits remain enforced. Swift grammar, target/resource membership and asset checks passed after implementation. Seventeen new native regression cases are registered; Xcode/native and iPhone verification remain pending for this build.

Build 35 adds [local show inventory and stock-aware transactions](docs/ShowInventoryTransactions.md). **Show** contains Inventory, Budget, Record Transaction and History. Sell multiple cards/quantities, buy a scanned list using its Cash Offer, or trade with editable Trade Offer values and explicit even-trade concessions. All trade cash received returns to buying funds; sales keep the show’s 65/35 default split. Stock, cash and immutable receipts commit together; Undo restores the original effects with dependent-transaction protection. Delete Show removes its menu entry while retaining stock and receipt history. Build 44 supersedes the original one-time seed: explicit website imports now reconcile available quantities while retaining cost and receipt history. Financial v1/v2 migration is preserved; no TCGTracking transaction synchronization or scanner engine change is included.

Build-35 local verification passed 151 JavaScript and 27 Python tests, grammar parsing of 141 Swift files, all app/native/UI target assignments and 47 pinned scanner assets. Twenty-five new native cases and two transaction UI cases are registered in existing CI jobs; Xcode/native execution and physical-iPhone transaction/migration verification remain pending.

Build 36 streamlines [transaction checkout](docs/ShowInventoryTransactions.md#checkout-corrections-in-build-36): Record Transaction stays at the top, inventory selection is searchable with thumbnails and quantity controls, and selected outgoing cards automatically use whole-dollar market prices. Adjusted sale totals allocate the same market percentage across selected cards with exact cent rounding, visible in checkout and receipts. Review/Edit Selected List returns to the current deal with saved changes; negotiated totals remain for review. Search keyboard Done now dismisses the keyboard. Local grammar parsing of 143 Swift files, app/native/UI target membership and all 47 scanner assets passed. Six native and two UI regressions are added; Xcode/native/UI execution and physical-iPhone verification remain pending.

Build 37 isolates sale cash entry in a small editor with local text/focus, Done and Cancel. Typing no longer changes the checkout's summary layout or triggers inventory/price-allocation work for each keystroke. Preview validation uses an inventory index and a single calculation per render; collapsed allocation details do not sort rows. Fixed-phase timing breadcrumbs support the next device check without recording amounts or credentials. The build-36 log shows keyboard/layout warnings but does not establish the exact hang cause. Swift grammar parsing of 143 files, target/resource membership, 47 scanner assets and whitespace checks passed. Two UI regression cases are added; Xcode/native/UI execution and iPhone verification remain pending.

Build 38 [simplifies long lists and primary actions](docs/SimpleListNavigation.md): transaction types use visible buttons; lists open on Cards with an adjacent Offer section and fixed Record/Scan actions; working inventory pins its quantity and Record button with Source in the toolbar. Incoming/receipt card rows start collapsed, money comes first, Undo stays fixed, and budget Create/Save/Record actions use navigation toolbars. Offer draft inputs survive section changes; export and percentages remain in the three-dot menu. Financial calculations, persisted stock/order, source import behavior and the isolated cash editor are retained. Swift grammar, target/resource membership, 47 scanner assets and whitespace checks passed; Xcode/native/UI execution and iPhone layout checks remain pending.

Build 40 adds **Quick Sell** from an inventory card and [cost and profit tracking](docs/CostProfitTrackingPlan.md). New purchases retain actual allocated acquisition costs, trades carry original costs forward, and sales record fees and profit without charging acquisition cash again. **Sales & Profit** separates known profit from missing costs. Existing stock starts at Cost unknown, with audited edits for remaining lot costs; Undo restores exact costs, stock and original budget effects. A $7 purchase sold for $10 earns $3 profit before fees while the $10 sale still splits $6.50 buying / $3.50 saved. Financial v1-v3 migrate to v4 while retaining cash, stock and receipt history. Portable and native validation status is recorded in the linked document; physical-iPhone acceptance remains pending.

Build 41 removes the experimental label-printing feature, its setup/inventory actions, protocol and rendering code, permissions and printer-only tests. Local verification passed grammar parsing of 147 Swift files, all target/resource assignments, 47 scanner assets, no remaining printer references and portrait/foreground metadata. Build 40's macOS rerun passed 681 native tests and the Release iPhone build; build 41's Xcode rerun and physical-iPhone checks remain separate.

Build 42 adds [inventory label printing](docs/InventoryLabelPrinting.md): individual or searchable batch selection, Price only/Card details templates, editable local asking prices, copy controls and actual raster previews. A saved queue tracks each physical label, blocks automatic retry of uncertain output and works offline. Settings provides an explicit NIIMBOT D110 Bluetooth connection; printing is foreground-only and independent of stock/financial records. Physical iPhone/D110 compatibility and output remain pending acceptance.

Build 43 applies the [final sticker rules](docs/TagPricingRules.md): 2 for $1 below $0.75, $1 through $0.99, whole-dollar floor below $100 and $5 floor at $100+. Pricing review uses asymmetric approval-based thresholds, competitiveness flags, actual-cost profit floors, bounded offers and bundle checks. Approval history survives queue cleanup, manual prices stay intact, unchanged stickers avoid reprints, and approved stickers become checkout suggestions. Unknown cost/profit remains a review item. Existing inventory/financial snapshots and printer transport are preserved.

Open `CardShowScanner.xcodeproj` in Xcode 16+, select **CardShowScanner**, and Run. Set personal signing using the local configuration instructions below. Use a physical iPhone for live camera verification.

For the final personal-use installation, select **CardShowScanner Personal**: Run uses Release without attaching a debugger, with the same bundle ID and your ignored signing configuration. [Final phone test and weekly Personal Team refresh](docs/PersonalIPhone.md) explains how to keep the app/data installed; free signing normally expires after seven days.

```sh
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
```

**Passed in this Linux workspace:** 142 JavaScript tests (42 bridge, 20 border/flow/transport, 23 database-cache, 5 automatic-update adapter, 13 public-pricing request, 13 website sign-in form, 23 Beta IP allowlist, 2 real bundled OpenCV/engine smoke tests and 1 quick-scan diagnostic test); 27 Python helper tests (2 signing, 11 native-failure annotation, 7 simulator crash reporting, 7 native-result summary); Swift grammar parsing; app/test source and bundled-resource membership; 47-asset hash/dependency verification. Bridge tests include the four-second card-presence timeout, same-art next-card rearming, brief tracking loss, empty-camera behavior, same-attempt suppression, popup/confirmation races and resume without camera reacquisition. The real-engine tests initialize each WASM build in an isolated Node process, hash and match synthetic input, and reject an empty frame. They do not exercise an iPhone camera or establish real-card recognition accuracy.

Build 25 adds 36 native IP-access cases. Its [initial CI run](https://github.com/wgreelish-png/scanner/actions/runs/41113528001) compiled Release and passed the budget UI persistence case; 481 native cases ran with two IP validation failures (Apple URL trailing-slash normalization and Darwin accepting leading-zero IPv4 octets). Both checks have been corrected; their native rerun and live iPhone IP updates remain pending. The earlier [build 24 CI](https://github.com/wgreelish-png/scanner/actions/runs/41074050090) passed 445 native tests and the Release iPhone build, while its simulator UI jobs timed out. That is not a full UI pass.

**Native validation:** [macOS CI at `e33c3bd`](https://github.com/wgreelish-png/scanner/actions/runs/40581364071) passed all 188 native cases, all three simulator UI tests and the unsigned Personal-scheme Release iPhone build. The UI tests cover recording/changing/clearing list outcomes across six relaunches, unmarked lists, swipe deletion across relaunch and explicitly selecting Mock, editing condition/printing before confirmation, saving, reopening the one-card inventory and reaching its CSV export/share controls. Native cases cover copy/undo with failure rollback and double taps, exact quotes/SKUs, frozen draft identity, same-art and tentative next-card handoff, queued release during startup, catalog search, stale replies, separate persisted rows, session/offer preservation, listener lifecycle, permissions, Keychain and migrations. The simulator-only workaround for the [iOS 18.4/18.5 Swift WebKit Cryptex defect](https://github.com/WebKit/WebKit/pull/46146) is working. Xcode is unavailable locally on Linux. Choose an installed iPhone simulator ID from `xcrun simctl list devices available` on a Mac:

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

Build 12 adds **Steady Card Border**, a 650ms geometry retry after a real accepted match, requiring fresh validation before green returns. It repairs next-card handoff, pins Condition above confirmation and moves printing menus above artwork. **Export CSV to Files** and **Share CSV** are visible at the top of list review. Settings → About shows the installed build; install build 12 over the existing app to receive these changes. See [implementation limits and phone acceptance](docs/SteadyCardBorder.md).

Build 13 adds **Undo Last Add** and **Add Another Copy** directly to the scanner. Copies preserve the confirmed printing, condition and exact quote as separate quantity-one rows. Undo reopens a recognized card's frozen matches for correction; undoing a copy stays camera-ready. Verified card removal now resets stale same-art state automatically, and different tentative cards use the ordinary settling rule after a save. There is no required Scan Next button. See [quick actions and the phone check](docs/ScannerQuickActions.md).

Build 14 adds a saved **List outcome**. **Record Transaction** offers Purchase, Trade + Purchase and Trade, then shows the selected operation on the button. **Nothing Happened** records a separate explicit outcome; leaving the list unmarked keeps **No status**. Outcomes and dates survive app relaunch and appear in saved-list rows. List options → Clear List Outcome resets the label. Existing lists upgrade to schema V3 without an inferred transaction. See [outcomes, migration and the phone check](docs/ListOutcomes.md).

Build 15 adds **Automatic Database Updates** in Settings → Scanner, enabled by default. The active Home screen checks the selected game's saved database at most once every seven days, stages only changed files and publishes a complete saved pack for the next scan. Settings → Refresh Database Now bypasses the weekly schedule, including when automatic updates are off. Opening the scanner cancels optional maintenance. First downloads and manual updates remain available; recognition code still ships with tested app updates. See [automatic updates and the phone check](docs/AutomaticDatabaseUpdates.md).

Historical build 16 (superseded by build 27) added **Price source** in Settings, scanner Options and card review/editing: keep **Existing TCGTracking** or select **Open API** for public condition-level SKU quotes. The existing source remains the default; failed lookups never switch sources automatically. Exact condition, printing and language matching preserves zero versus missing prices. Saved rows and offers change only through explicit saves. See [source switching, freshness and the iPhone check](docs/SelectablePricing.md).

Build 21 adds **Market Details & Sales Activity** in Edit Card and scan confirmation. Public details show the exact SKU's market/low/high/listing context; optional live OppsV2 data supplies reported sold averages/quantities, comparable listings and provider trends independently of experimental graded Research. An exact product-ID lookup can recover a missing catalog set mapping, and bounded disk caching supports previously downloaded OpenAPI prices offline. The existing pricing selector/default, scanner recognition, inventory values and saved offers are preserved. Settings → **TCGTracking API Connection** tests market activity and graded Research separately. See [Market Details, API access, cache behavior and acceptance checks](docs/MarketData.md) and the [Postman collections](postman/README.md).

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

## Research and PSA slabs — build 17

[Research and PSA slabs](docs/ResearchAndPSA.md) adds sales activity, population, distinct guide estimates/market values and sparse daily history for an exact catalog language/printing/grader/grade. Open **Research** from Edit Card or **Research a PSA Slab** on Home. The slab flow reads a supported barcode or typed certification number, uses an optional authorized metadata adapter, then asks you to confirm the catalog card before showing Research. Missing coverage stays unavailable; research is read-only and does not change inventory prices or saved offers.

Settings → API connection offers **Direct TCGTracking** or **My Server**. Direct mode saves your user-entered shipper ID/API key in device-only Keychain and requests the fixed Beta API from the phone. Build 25 adds [automatic IP access](docs/AutomaticBetaIP.md): while the app is active, the matching signed-in website session replaces only this phone’s recorded previous IP and retains other devices/servers (build 33). It stops when you leave the app. The optional HTTPS [Research server](server/research/README.md) keeps upstream keys on a server with a stable IP and uses a separate device token. The Research API does not resolve PSA certificates; automatic metadata still needs an authorized server adapter, which can remain available while Research uses direct mode. Otherwise use manual catalog/grade selection. Live IP-update/network-switch behavior, direct access, server deployment and physical PSA-label acceptance remain unverified; see the feature guides for checks and limitations.

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

Build 44 fixes [website-authoritative inventory refresh](docs/AuthoritativeInventoryRefresh.md): complete imports replace available working quantities, preserving costs, receipts, tag approvals and cash. Durable snapshot markers prevent duplicate application after interrupted saves; stale responses cannot overwrite intervening activity. The supplied log contains 74 rows / 80 physical cards, versus the stale 86-card working stock.

Build 45 keeps [main navigation visible through card details, Market and API settings](docs/AppNavigation.md). Cards open within their tab’s navigation stack, tab changes retain unsaved drafts and interrupted pricing resumes for the selected condition. Save/Cancel behavior is preserved; no financial or scanner-engine changes are included.

Build 46 fixes the diagnostic’s Market Activity metadata rejection by raising the bounded category capacity from 32 to 256 while retaining schema, identity and size checks. Safe observed/allowed counts are logged for future limit failures. See [Market Activity index capacity](docs/MarketData.md#market-activity-index-capacity--build-46).

Build 47 improves [UI reliability](docs/UIReliability.md): show date checks use foreground-only minute schedules, toolbar tests avoid invalid accessibility scrolling, card rows have stable interaction IDs, and UI jobs prepare a fresh compatible iPhone simulator. Existing save/Undo assertions and CI timeout limits are retained.
