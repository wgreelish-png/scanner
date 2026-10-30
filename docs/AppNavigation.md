# Bottom navigation and simpler screens

Build 23 uses a native bottom tab bar with four destinations. Each tab keeps its own navigation stack while the app is open.

| Tab | Main actions |
| --- | --- |
| Lists | Search saved lists, see card counts and known value, create an empty list with +, review inventory/offers, and swipe to delete or duplicate. |
| Scan | Start a new saved scan, continue the active session, open existing lists, or view session history. |
| Research | Search the downloaded catalog with artwork previews, open market details or graded research, and look up a PSA slab. |
| Settings | Change game, sound, haptics and price source; connect accounts; open offer defaults, scanner database, diagnostics or About/Privacy. |

The Scan tab is the initial screen. Selecting any tab does not create a session or open a camera. **Start New Scan** explicitly creates a new saved list and retains the existing behavior of finishing another active session without a confirmation prompt. **Continue Scanning** resumes the existing active list. Closing the scanner keeps that session available for later continuation.

Live capture stays full-screen with its existing controls; the tab bar is hidden during capture and visible in list review. The scanner stops when it disappears. A session whose list is deleted from the Lists tab is removed from the Scan tab's retained route. Navigation does not replace a saved list's identity or offers.

The Lists screen prioritizes saved inventory. New empty-list creation uses a short sheet with explicit Create/Cancel actions. Failed creation retains the entered name for retry. Swipe deletion still uses the existing independent confirmation sheet and persistence model. Existing list outcomes, manual additions, export, pricing, saved estimates and continued scanning remain in list review.

Research search reuses the local catalog and its cancellation/debounce behavior. Selecting a card creates a read-only Near Mint draft with printing and condition choices. Market and graded research use the existing services; viewing them does not add inventory or change the selected pricing provider. Missing catalog guidance can switch to Scan or Settings without launching capture.

Settings keeps common preferences and connection actions visible. Offer rates, database maintenance, diagnostics and About/Privacy are one step away. Stored preference keys, weekly recognition refresh, daily API caches, Keychain credentials, signing, persistence schemas and offer calculations are unchanged.

## Verification

Two focused UI cases check that cycling tabs creates no lists or camera screen and that an open list remains at the same navigation depth after changing tabs. Existing list, deletion, pricing and Research UI routes now use the tab bar. The navigation and chart cases share one focused feature job so no additional CI runner is added. Simulator behavior and live-iPhone acceptance must be reported separately from static source/resource checks.

On an iPhone, check each tab in light/dark mode and at large text sizes; create, reopen and swipe-delete a test list; open a saved list, switch to Settings and return; explicitly start or continue a scan and verify full-screen capture, confirmation and next-card handoff; open list review from capture and switch tabs; verify the camera stays stopped while viewing another tab; then return and explicitly continue. Confirm CSV exports, saved offers, pricing source and sign-in still work with existing data. Install over the existing app rather than deleting its data.
