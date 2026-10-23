# Release readiness — 2026-10-23

Status: reliability changes implemented; production release is not yet verified.

## Evidence available

23 JavaScript tests pass, including first-guess correction, ambiguous/slow-frame settling, immutable review, partial payloads, removal between cards, camera interruption/retry, overlay cleanup and real scalar/SIMD WASM smoke checks. Two signing-helper tests pass. Source/resource membership, all 47 pinned runtime assets and Swift grammar checks pass. A bundled privacy manifest declares app-local UserDefaults access (CA92.1) and file metadata for local diagnostics (C617.1), no app tracking and no developer data collection.

38 native tests are supplied, including candidate double taps, exact condition/SKU quotes, stale responses, failed-save retry, confirmation timeout, discard during lookup, separate duplicates, reopened order, saved offers and migration. They have **not run** here. The Linux environment cannot build an iOS app. CI now includes native simulator tests and an unsigned Release iPhone build; adding these steps is not evidence they passed.

The supplied iPhone diagnostics show the camera worker initialized and produced five-candidate results. They also show six pricing failures (-1011). The log does not contain card identities/images or HTTP statuses, so recognition correctness and the pricing failure's server cause remain unknown. New logs include settling time/count, confidence, chosen candidate index, HTTP status and timeout outcomes without card content.

## Required release evidence

1. Obtain a passing macOS CI run for this exact commit, including native tests and Release compilation. On a Mac, archive with the existing personal signing configuration and inspect Xcode Organizer validation. Keep Config/Signing.local.xcconfig ignored.
2. On an iPhone, scan known cards in each supported game across glare, sleeves, movement and low light. Confirm tentative guesses do not interrupt too early and the correct printing/reprint appears among candidates. Record misses; tune settling from measured behavior rather than assuming the thresholds prove accuracy.
3. Verify tap-to-save, condition/printing edits, a real $0 quote, unavailable quotes, offline/slow pricing and latest HTTP diagnostics. Pricing is not considered verified until the reported endpoint failures are understood and successful exact quotes are observed.
4. Scan A-B-A and identical copies, double tap, cancel during lookup, background/resume, interrupt camera permission, relaunch, resume a saved list and export CSV. Check three quantity-one rows in physical order and retained offer snapshots. Inject a save failure in native tests; confirm no row is added and retry retains the exact choice.
5. Verify first pack download, download interruption, cached pack startup in airplane mode, memory/battery behavior during a sustained session and recovery after WebKit termination. No offline iPhone recognition claim before this passes. Prices require internet.
6. Test upgrading an existing installed database without deleting it, and inspect migration tests. Preserve valuable list exports. Test large lists, accessibility text sizes, VoiceOver, safe areas and device rotation.
7. Before App Store distribution, provide the app icon/asset catalog (currently absent), screenshots, support and privacy-policy URLs, and complete App Store privacy answers for the actual distribution. Review the archive privacy report alongside the included manifest and third-party network behavior. These distribution items are not supplied by passing code tests.

Record the commit, iPhone model, iOS version, game/pack, expected card, actual result and diagnostic export for each failed acceptance step. Unconfirmed review is intentionally held in memory and will be lost on force-quit; committed lists remain persisted. Device acceptance and App Store archive validation are external prerequisites, not claims made by this branch.
