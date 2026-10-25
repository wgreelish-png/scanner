# Build 7: condition prices, printing choices and list deletion

Changing condition in Edit Card previously cleared the saved market value and SKU without requesting a replacement. The editor now requests the exact condition/language/printing quote, keeps changes in a draft until Save, and supports retry, website connection and manual market values. Late replies cannot replace newer selections or manually entered values.

Both the scanner match review and Edit Card now populate a Type / printing dropdown from the online catalog's returned printings. Opening an existing card updates choices without replacing its saved price. The current printing remains available for legacy records. No printing or condition prices are estimated: a known zero remains $0, and a missing quote remains unavailable.

Successful catalog responses contain all condition quotes. Each pricing provider reuses those exact responses in memory for up to 60 seconds (at most four batches), avoiding another network request on every condition/type change. Explicit Refresh / Retry always requests fresh data and invalidates the previous response, including on authentication failure. No offline price database is introduced.

Delete List now captures the confirmation dialog's selected list independently of its presentation state. Dismissing the dialog can no longer clear the deletion target before its action runs. Deleted cards cascade with their list; session history and immutable saved estimates remain. A native disk-reopening regression verifies deletion persists and other lists stay intact.

Recognition code, camera settings, thresholds and bundled engine files are unchanged. The scanner only adds a short tip about glare and using a light, plain background for dark borders.

## Validation

Local checks: 62 JavaScript tests, 20 Python helper tests, all 28 Swift files parsed, correct app/test/resource membership, 47 pinned recognition assets, scheme/plist parsing and diff checks passed. [macOS CI at `7c4ac73`](https://github.com/wgreelish-png/scanner/actions/runs/40149104115) passed all 102 native XCTest cases and the unsigned Personal Release iPhone build. Physical iPhone behavior still requires the checks below.

## Short iPhone check before the show

1. On a card with available condition quotes, change Near Mint to Lightly Played on the scanner match screen. Confirm market value and SKU change. Select an available alternative in Type / printing and confirm its quote. Rapidly switch conditions and verify the last selection wins.
2. Save the card, open it from the list and change its condition/type. Check the new price, Save and reopen. Cancel a second edit and verify it does not change the saved card. A genuinely missing quote should remain unavailable; you can supply a manual value.
3. Create a disposable list, add a card, then swipe Delete and confirm Delete List. Leave/reopen My Lists and relaunch the app: it should remain deleted. Check another list remains. Cancel deletion on that other list to verify it stays.
4. Use the working personal signing setup and install over the existing app without deleting it. If using the branch directly, pull `codex/condition-pricing-list-delete` on the Mac and run the CardShowScanner Personal scheme. Free Personal Team signing still normally expires after seven days.
