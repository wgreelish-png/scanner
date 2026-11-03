# UI reliability — build 47

The build-46 Release build and all 837 native cases passed in run [41733268622](https://github.com/wgreelish-png/scanner/actions/runs/41733268622), but all four UI jobs timed out. The import case reported `AXScrollToVisible` failing on the already-visible List Options toolbar button. Other failures involved missing label-menu controls and generic navigation scroll assertions. Those reports do not establish a single cause for every timeout.

## Changes

- Show and budget date/eligibility checks use `ForegroundMinuteSchedule` instead of an animation display-link schedule. Active views receive minute ticks; inactive views receive their initial value without future ticks. The `TimelineView` type remains stable, preserving child drafts and navigation state. Save-time financial eligibility checks remain authoritative.
- Shared UI interactions wait for visible controls and scroll only a visible foreground content container. Fixed toolbar/tab controls are tapped at their checked screen position, avoiding XCTest's failing accessibility-scroll action. Targets must be enabled, inside the visible window, stable in position and members of the visible bar. Screen, menu and value assertions remain intact.
- Saved-card rows expose their existing row UUID as an accessibility identifier. Synthetic navigation fixtures have deterministic UUIDs, so tests activate the card button instead of depending on a text child. No persisted model shape or row order changes.
- Failure messages contain selector IDs, control types, frames and booleans. They exclude raw view hierarchies, field contents, credentials and API bodies. Test inputs explicitly replace previous invalid connection drafts, and optional database/IP maintenance is disabled only through test launch arguments.
- UI jobs select a fresh regular-size iPhone on an available runtime compatible with the selected Xcode SDK. They boot it and await readiness before XCTest, use English/US labels, preserve the test exit status and shut down only that owned device. Simulator data remains available for failure diagnostics. The passing native runner, signing settings and WebKit workaround are retained.

No test cases are removed, financial assertions weakened, job time limits increased, jobs added or automatic transaction retries introduced. Live scanning, providers, pricing math, inventory migration and printer transport are unchanged.

## Validation

All implementation completes before validation. Three native cases cover the foreground schedule, and seven portable cases cover deterministic simulator selection and SDK/runtime compatibility. Existing UI cases continue to check import quantities, Save/Cancel, draft preservation, pricing selection, labels, purchases, sales, budgets, Undo, relaunch, navigation and exports. Structural checks and actual Xcode execution must be reported separately.

After implementation, all 34 Python helper tests passed, including the seven simulator-selection cases. Swift grammar parsing passed for 174 files, target membership passed for 97 app / 63 native-test / 14 UI-test sources, and all 47 pinned scanner assets/dependencies passed. Shell syntax, build/portrait/foreground-only metadata and whitespace checks passed. All existing UI test scenario names are retained. These local checks do not establish Xcode or iPhone execution; GitHub's existing native and UI jobs provide the next validation step.

On an iPhone, repeat card → Market → API settings → another tab → return, then Save and Cancel separately. Open both inventory menus, preview a label without printing, record/cancel a disposable transaction and verify the scheduled-show controls still update when returning to the app. Physical-iPhone behavior remains separate from simulator acceptance.
