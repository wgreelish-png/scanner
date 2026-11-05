# Warm scanner return and recent cards

Build 75, revision `warm-scanner-review`.

## Changes

- **Choose the Card → Search Manually** opens the catalog when none of the
  recognized candidates is correct. It abandons the unconfirmed recognition
  without adding it. The catalog adds to the same scan list.
- Manual search pauses recognition in the existing scanner document. A ready
  camera, loaded game pack and recognition backend are retained while the
  catalog or a recent-card editor is open. Returning starts a fresh recognition
  attempt without reloading the page/database. Late callbacks and quote
  responses from the suspended attempt cannot open another card chooser.
- Real backgrounding and leaving the scanner still stop capture. Returning
  after a real stop may require startup; a failed camera or terminated WebKit
  process remains recoverable through Retry Live Scanner.
- The expanded bottom panel contains a bounded, scrollable recent-card list,
  newest first. Tap a row to review/edit it in the existing card editor. The
  saved list, offer calculations and CSV retain their existing scan order.
  Totals and the scanner's main actions remain outside the scrolling content.
- A compact adaptive strip at the top shows game, scanner status, pause and
  options. The real iPhone status bar remains visible. Keyboard presentation
  and drawer expansion do not change the camera's full-screen layout.
- Scan-origin manual entry focuses the search field on presentation and when
  returning from its card confirmation. Keyboard Done hides the keyboard while
  keeping the search; the navigation Done returns to scanning.

## Evidence for the restart fix

The supplied diagnostics 14 describe build 72. They show full scanner teardown
when manual entry opens, followed by startup when it closes. For example:

| UTC | Recorded event |
| --- | --- |
| 14:43:46 | `scanner.stop`, `web.stopped`, `scanner.manual_search_opened` |
| 14:44:12 | `catalog.card_added` |
| 14:44:14 | `scanner.start`, `web.load_started` |
| 14:44:15–16 | Cached pack/backend/camera startup, then `web.scanner_ready` |

The pack was cached (`downloaded_bytes: 0`, 1,208 cached shards), but loading it
again took 1,179 ms. Similar manual returns loaded it again in 1,216 ms and
recreated the camera. This establishes repeated startup as a source of delay;
the diagnostic file does not record individual visual rendering frames.

## Phone acceptance

1. Scan a card, then choose Search Manually from Choose the Card. Confirm the
   original recognition was not added and the search keyboard is ready.
2. Find and add the correct card. Return from confirmation, verify the query
   remains and the keyboard returns, then use navigation Done to resume the
   camera. Repeat from the scanner's Search Manually button.
3. Verify a normal manual return does not show Opening saved game database,
   flash white bars, or require a second startup. New diagnostic exports should
   not show another `web.load_started`/`web.pack_ready` for that warm return.
4. Add several distinct cards. Expand the panel, check newest-first ordering,
   scroll to an older row and edit it. Return and verify the change; totals and
   main actions remain accessible. List review/CSV retain oldest-first scan
   order.
5. Open manual entry while the scanner is initially loading, then return.
   Background the app with manual entry open and return to it before closing
   manual entry. Verify capture does not resume behind the catalog and the
   eventual return works.
6. Check pause/resume, identical-copy Add Another Copy, Undo Last Add, discard,
   zero-card scan dismissal, denied camera permission, large text and a small
   iPhone screen. Retry Live Scanner remains available for real camera errors.

Native/UI and physical-device execution require Xcode/an iPhone; portable
scanner tests can verify lifecycle messages and state transitions, but cannot
establish physical rendering or camera timing.

## Verification

All implementation was finished before verification. Local checks passed:

| Check | Result |
| --- | --- |
| App JavaScript tests, including seven new lifecycle cases | 164 passed |
| Research server tests | 59 passed |
| Postman collection tests | 49 passed |
| Python tooling tests | 40 passed |
| Swift grammar | All 192 Swift files passed |
| Xcode source/resource membership | Passed |
| Pinned scanner runtime/dependency integrity | All 47 assets passed |
| Bundled scalar and SIMD OpenCV smoke tests | Both passed |
| Whitespace and build/revision metadata | Passed |

Three native model regression tests cover warm suspension, late recognition,
explicit frozen-result discard, and terminal background stop. UI regressions
cover chooser-to-manual fallback and keyboard focus, stable camera geometry,
newest-first review/editing, and fixed controls at accessibility text sizes. The
new UI fixture uses synthetic cards in an in-memory store and a paused mock
scanner. Native/UI test execution and physical rendering remain unverified in
this Linux environment.
