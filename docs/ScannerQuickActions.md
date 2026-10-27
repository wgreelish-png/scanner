# Build 13: scanner corrections, copies and automatic next cards

Install over the existing app with the same signing configuration. Settings → About this app shows Build 13 and release `scanner-quick-actions-auto-next`. Lists, saved offers, legacy quantities and the storage schema are unchanged.

## Scanner actions

After a successful confirmation, the scanner shows the last added card, its printing, condition and market quote.

- **Add Another Copy** explicitly saves one additional quantity-one row. It uses the last confirmed card, printing, language, condition, SKU and quote. It does not merge quantities or perform another price lookup. A missing quote remains unavailable and a known zero stays zero.
- **Undo Last Add** removes only the latest unchanged physical row added by this scanner. For a recognized card it reopens the frozen matches with the saved condition and printing, so you can correct the choice or discard it. Undoing a copy removes that copy and leaves the camera ready.

Rapid repeated taps are briefly blocked. A failed save or undo retains the previous data and allows retry. Undo does not rewrite historical offer snapshots. Editing/removing the target, adding a newer row elsewhere or finishing the session invalidates those quick actions. The undo history belongs to the current open scanner; after relaunch, use saved-list review to edit existing rows.

## Automatic next-card behavior

Confirmation saves first, then prepares the existing camera for another card. There is no required Scan Next button. Sustained observed absence clears the old card's recognition state and requests a full candidate result, including for identical artwork or reprints. A different stable tentative match uses the same slower settling rule as ordinary scanning. Repeated frames of the saved card, partial-only updates and low-confidence guesses remain suppressed.

Two identical copies swapped without an observable gap can look exactly like one card held continuously. Use Add Another Copy for that situation. Search Manually remains available after saving, and Scanner options → Reset Card Recognition provides an explicit recovery action. Intentional camera pause remains paused.

## Validation

At `07cb1c5`, [macOS CI](https://github.com/wgreelish-png/scanner/actions/runs/40527087993) passed all 176 native tests, both simulator UI tests, 102 JavaScript tests, 20 helper tests, source/resource membership, all 47 pinned assets and the Personal-scheme Release iPhone compile. All 41 Swift files also parsed locally. Native quick-action tests exercise actual SwiftData transactions and on-disk relaunch/CSV order; the simulator UI tests exercise confirmation controls, last-added actions appearing, reopening the saved list and export controls. Real iPhone actions and system file/share presentation remain unverified.

The JavaScript regressions exercise actual quick-scan same-art state, verified-absence rearming, the slower tentative next-card gate and preservation of the existing camera stream. Native regressions cover the normalizer's new episode after a coalesced hide, exact copied quotes, zero/missing prices, separate persisted rows and CSV order, stale targets, double taps, rollback/retry and historical offers.

Physical-iPhone acceptance is still required:

1. Select the first tile for A, then show B without pressing a next-card button. Check that B opens confirmation and starts at Near Mint.
2. Remove A briefly and present a second identical copy. Confirm a fresh result; also test Add Another Copy while the same card remains visible.
3. Copy a card with a non-default printing and condition. Verify separate quantity-one rows with the same SKU/quote. Confirm one quick double tap adds only one copy, and deliberate later taps add further copies.
4. Undo a copy, then undo a recognized card. Correct its match and save again. Check that only the intended row changes and saved offers remain available.
5. Export and reopen A, A, B, A. Check scan order, quantities, printing, condition, market values and unavailable prices. Reopen a saved list and verify its identity and offers.

Real camera transitions, exact on-device pricing, Files/share presentation and top-loader accuracy are not established by simulator or synthetic-image tests.
