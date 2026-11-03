# Persistent main navigation — build 45

Card Details now opens inside its tab’s existing navigation stack instead of a sheet above the entire app. Lists → card → Market & Graded Research → API Connection keeps Lists, Scan, Show, Research and Settings available at the bottom. Imported, read-only cards follow the same route. Each tab retains its own navigation position; returning to Lists restores the same card or research screen.

Card quantity, manual price and offer drafts stay in memory while switching tabs. Only Save writes card changes; Cancel or backing out of Card Details discards the draft. API Connection fields also survive a temporary tab change without saving credentials. Interrupted condition/printing price lookups stop while the editor is hidden and resume for the exact selected draft on return, using the existing cache policy and stale-response guard. Completed and manual prices are retained.

Live camera capture retains its full-screen controls. Short tasks such as artwork preview, correction search, sign-in, transaction confirmation and the iOS share sheet keep their focused presentations. Browsing card details no longer requires dismissing them to reach the main sections.

Three isolated UI cases exercise editable/imported card research and API settings, usable tabs at depth, retained navigation positions, unsaved card/connection drafts, explicit Save/Cancel and no accidental scans or lists. Three native pricing cases cover pause/resume and stale replies. They run in the existing native/navigation jobs without adding a CI job. Implementation finishes before checks; Xcode/iPhone results must be reported separately from structural checks.

Build-45 local checks passed grammar parsing of all 171 Swift files, Xcode target/resource membership, all 47 pinned scanner assets, portrait/foreground-only metadata and whitespace checks. This Linux environment has no Xcode; native/UI execution and physical-iPhone navigation remain unverified. JavaScript, Python and scanner assets are unchanged and their unrelated suites were not rerun locally.

On the phone: open a saved card, change quantity or price, open Market and its settings, then tap Settings or Show directly. Return to Lists and check that your previous page and draft are preserved. Cancel the card and reopen it to verify it was not saved. Repeat and Save to confirm persistence. Repeat research navigation with an imported card. Confirm explicit Start/Continue still opens full-screen capture and closing it stops the camera.

---

> Build 32 adds **Show** as a fifth tab for show dates and budgets, removes budget links from the Lists/Scan roots, and makes explicit **Open Existing List** reset the Lists navigation stack. Ordinary tab taps retain their stacks. The four-tab build-23 description below is historical.

# Bottom navigation and simpler screens

Build 23 uses a native bottom tab bar with four destinations. Each tab keeps its own navigation stack while the app is open.

| Tab | Main actions |
| --- | --- |
| Lists | Search saved lists, see card counts and known value, create an empty list with +, review inventory/offers, and swipe to delete or duplicate. |
| Scan | Start a new saved scan, continue the active session, open existing lists, or view session history. |
| Research | Search the downloaded catalog with artwork previews, open combined Market/Graded Research, and look up a PSA slab. |
| Settings | Change game, sound and haptics; view standard market pricing; connect accounts; open offer defaults, scanner database, diagnostics or About/Privacy. |

The Scan tab is the initial screen. Selecting any tab does not create a session or open a camera. **Start New Scan** explicitly creates a new saved list and retains the existing behavior of finishing another active session without a confirmation prompt. **Continue Scanning** resumes the existing active list. Closing the scanner keeps that session available for later continuation.

Live capture stays full-screen with its existing controls; the tab bar is hidden during capture and visible in list review. The scanner stops when it disappears. A session whose list is deleted from the Lists tab is removed from the Scan tab's retained route. Navigation does not replace a saved list's identity or offers.

Build 29 pins **Card Show Inventory** above the ordinary lists. It opens the [TCGTracking inventory importer](CardShowInventory.md), with explicit import/refresh, saved-copy navigation and an editable-copy action. Opening the page makes no inventory request. The imported list is read-only for card fields and quantities, with CSV, research and list outcomes available; a duplicate supports scanning and local edits. Swipe **Remove Saved Copy** removes only the local imported list, and it stays removed until another explicit import.

The Lists screen prioritizes saved inventory. New empty-list creation uses a short sheet with explicit Create/Cancel actions. Failed creation retains the entered name for retry. Swipe deletion still uses the existing independent confirmation sheet and persistence model. Existing list outcomes, manual additions, export, pricing, saved estimates and continued scanning remain in list review.

Research search reuses the local catalog and its cancellation/debounce behavior. Selecting a card opens the [combined Card Research page](CombinedCardResearch.md) directly with a read-only Near Mint draft. Shared printing/language controls, Market condition buttons and the Graded grade menu use existing services. Viewing research does not add inventory or change saved prices; all market quotes use Open API. Missing catalog guidance can switch to Scan or Settings without launching capture.

Settings keeps common preferences and connection actions visible. Offer rates, database maintenance, diagnostics and About/Privacy are one step away. Stored preference keys, weekly recognition refresh, daily API caches, Keychain credentials, signing, persistence schemas and offer calculations are unchanged.

## Verification

Two focused UI cases check that cycling tabs creates no lists or camera screen and that an open list remains at the same navigation depth after changing tabs. Existing list, deletion, pricing and Research UI routes now use the tab bar. The navigation and chart cases share one focused feature job so no additional CI runner is added. Simulator behavior and live-iPhone acceptance must be reported separately from static source/resource checks.

On an iPhone, check each tab in light/dark mode and at large text sizes; create, reopen and swipe-delete a test list; open a saved list, switch to Settings and return; explicitly start or continue a scan and verify full-screen capture, confirmation and next-card handoff; open list review from capture and switch tabs; verify the camera stays stopped while viewing another tab; then return and explicitly continue. Confirm CSV exports, saved offers, standard pricing and account sign-in still work with existing data. Install over the existing app rather than deleting its data.
