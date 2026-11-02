# Simple list actions — build 38

Build 38 keeps primary controls outside scrolling card content. It adds no app-level menus, download jobs or financial features.

## Transaction review

Transaction types use visible Sale, Trade and Purchase buttons. Trade alone reveals Even, Pay Customer and Receive Cash buttons. Selection styling and VoiceOver selected traits identify the active choice. Large text sizes stack these controls vertically, with 44-point minimum targets. Switching type still uses the existing validation/default rules; selecting Trade while already in a trade preserves its cash direction.

Incoming scanned lists show a compact name/quantity/row summary. Review/Edit and Reload are above a collapsed card disclosure, so hundreds of incoming rows cannot bury the agreed amounts. Outgoing selections remain collapsed summaries. Record Transaction stays fixed at the top, and build 37's isolated cash editor is retained.

## Saved lists

Cards and Offer are two direct section buttons in a fixed top summary. Lists open on Cards; the summary keeps quantity, known market value and outcome visible. Entirely unpriced inventory says Market unavailable. Offer contains the existing cash/trade estimates, My Card Price, offer breakdown, Nothing Happened and Finish Session. Its calculation modes also use buttons. Parent-owned draft bindings retain the entered card price and chosen calculation mode when switching sections.

Record/View Transaction and Scan stay in a fixed bottom bar in both sections. Incoming-list editing hides transaction recording, as before. Scan remains explicit and preserves the existing confirmation before resuming a completed list or finishing another active session. Pending outcome sync/errors expose a shared attention control linking to Offer and its retry controls.

Search & Add Card is a direct toolbar action. CSV export/share and Offer Percentages remain in the top-right three-dot menu. Cards retain thumbnails, search, sorting, editing and swipe removal. Full-list CSV export still uses every saved row in persisted order regardless of visible section, search or sort; data is not paginated, merged or truncated by the layout.

Imported source lists keep their read-only behavior. Their Refresh/Make Editable Copy control stays at the bottom outside the card scroller.

## Working inventory and receipts

Working inventory has a compact fixed top quantity/offline-status summary and a direct Source button in the navigation bar. Source opens the existing importer/management screen without refreshing automatically. Load/seed errors precede card rows. A fixed bottom Record Transaction shortcut uses the same active-show/loaded-data guards as Show home. The shortcut refreshes date eligibility once a minute while the inventory is visible and the app is active; recording still revalidates at save time. Search, keyboard dismissal, lot identities and quantities are unchanged.

Receipt amounts come before acquired/released cards. Card rows start collapsed, with quantities shown in their headings. Undo Transaction and Confirm Undo are fixed bottom controls, retaining all existing validation, dependent-transaction protection and confirmation behavior.

Budget setup Create/Save and cash-only recording actions move into navigation confirmation toolbars, with the same disabled guards and IDs. The cash toolbar stays within its existing timeline so date eligibility continues refreshing.

## Verification

Complete implementation before running checks. Existing UI cases are adapted to direct transaction buttons and the Offer section. Two new UI regressions use 80-row synthetic fixtures to cover scrolling while section/summary/action controls remain reachable, compact incoming lists, inventory Source/Record access and receipt Undo. Draft retention across Cards/Offer is also checked. Fixtures add only zero-value extra rows so existing cash expectations remain unchanged, and they make no camera or provider requests. These cases use existing CI jobs; no simulator job is added.

Check both normal and larger Dynamic Type on the phone: long lists, Cards/Offer switching, entered trade price retention, scroll-to-end actions, Search/Add, options export and percentages, every transaction type, cash edit Done/Cancel, source management, record/undo and budget save. Confirm no camera opens without explicitly selecting Scan. Xcode/native/UI execution and physical-iPhone layout behavior must be reported separately from portable grammar/resource checks.

After all implementation completed, local checks passed Swift grammar parsing of all 143 files, correct target/resource membership (81 app / 50 native-test / 12 UI-test sources), all 47 pinned scanner assets/dependencies and whitespace validation. Two long-list UI regressions were added and existing review/transaction cases were adapted. The unchanged JavaScript/Python suites were not rerun. Xcode/native/UI execution and physical-iPhone verification remain pending; Linux structural checks do not establish visual layout or device behavior.
