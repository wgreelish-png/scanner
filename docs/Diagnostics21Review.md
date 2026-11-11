# Show log 21 review — November 10, 2026

The 1,113 valid JSONL records cover retained sessions from November 7–10. The export header and all seven app launches identify **build 102**, `inventory-last-printed-tag`. These observations therefore cannot validate the already-saved heat, queue-cleanup, fixed list-search, owned-list inventory, or checkout fixes in builds 103–105. Line references below are one-based in the supplied log; times are UTC.

## New fixes in build 106

| Finding | Evidence and cause | Change |
| --- | --- | --- |
| Riftbound pricing fails immediately | The November 10 scanner uses category 89 (line 750). All 6 scan price attempts and 24 editor price attempts fail; all 28 additions save unpriced. Research subsequently reports `openapi/invalid_response` (1104). The native URL guard still allows only categories 1–3, although the registry and pricing URL builder support Riftbound and the other catalog games. This rejects requests before networking and also blocks the price-cache guard. | Validate category IDs against the existing registry while retaining exact HTTPS origin/path, credential, query and redirect restrictions. Keep sanitized pricing failure reasons in scanner/editor diagnostics. No existing saved card prices are rewritten. |
| Successful manual Add leaves Search & Add open | The current callback closes confirmation but retains search. The log includes three November 10 manual sessions with 1, 7 and 14 successful additions (821–834, 856–941, 946–1092). Those are productive sessions, not proof that every search is redundant; the requested automatic return is based on the user's explicit workflow preference. | After the save succeeds, dismiss confirmation, then dismiss search. Cancellation and failed saves retain their drafts. Scanner resumes through its existing parent-sheet dismissal callback. |
| Automatic roll detection can disappear after printing | Four single-label jobs report accepted completion. Their post-print RFID reads log responses (187, 265, 345, 399), but no updated detection afterward. In three cases detection is explicitly invalidated during the read. After 344–345, another job starts at 347–351 with no new matched detection. Current code can fence a superseded read out without scheduling a fresh one. The log omits prepared dimensions, so this does **not** establish a mis-sized physical label. | Retry a superseded roll read through a bounded, generation-fenced recovery. Preserve printer-confirmed completion, acknowledged transport, timeout/quarantine and print content/order. Verify on the physical printer after installing. |

## Other repeated steps and service issues

- All six automatic manual-search suggestions were declined; four appear in 64 seconds (478–494). A quieter inline suggestion or session cooldown is a worthwhile next UX improvement. The existing code already limits prompts per continuously observed attempt, and the log omits card identities, so this does not prove repeated prompting for one physical card. No prompt redesign is included here.
- Market Activity fails with HTTP 403 on three opens (92, 687, 1107). It already has an access explanation and connection controls. Credentials, entitlement and IP authorization need checking; the log cannot identify which one is responsible. This is separate from the public pricing defect and is not fixed by signing into the public price provider.
- There are 130 catalog search completions, including 115 in the latest substantive run. Completed searches include partial typing and multi-card additions. Do not count these as 130 taps or remove searches indiscriminately. Profiling catalog search is a candidate if manual entry remains warm after the saved workload fixes.

## Already covered or working

- The serious thermal state occurs in build 102. Recognition statistics stop and native CPU falls afterward, consistent with cooling protection engaging. Build 103 already reduces camera/hidden recognition demand. This older log cannot establish the new build's temperature or battery behavior.
- The latest run resumes manual search without another web/database/camera startup. Warm resume is already working; one later database check downloads zero bytes.
- One local-server connection failure recovers automatically in about 20 ms (668–673).
- All 63 health samples report zero recorded memory warnings and zero sampled UI-lag events. Native memory peaks around 114 MiB; native samples exclude WebKit processes. No OS crash report is included. Relaunches and battery-gauge differences alone do not prove crashes or app-attributable battery drain.

## Validation and phone checks

Focused native regressions cover the production pricing URL guard, diagnostic privacy, manual save/retry behavior, warm scanner resume, and superseded roll reads. Two deterministic UI cases use the real manual-search/confirmation views and an in-memory store: successful save closes both sheets and commits exactly one row; cancelling confirmation retains the query and saves nothing. GitHub `job_scope=log_review` selects these checks regardless of the separate test-scope input, without launching unrelated UI/release jobs. Record actual local and CI outcomes separately; defining a test is not a passing result.

Local validation passed: 46 Python helper tests (including focused CI routing), 71 JavaScript bridge tests, grammar parsing of all 13 changed Swift files, Xcode source/resource membership, 47 pinned scanner assets, plist/workflow parsing, shell syntax and whitespace checks. Linux has no Xcode; these checks do not compile or execute the native/SwiftUI tests. Native and UI compilation/execution are delegated to the single focused GitHub run, without waiting for its result.

On the phone, confirm that a Riftbound card gets an exact price where the provider offers one; add a manual card from scanning and verify immediate return with one saved row; cancel another confirmation and verify the query remains. Print, wait for roll refresh, and verify detected paper remains available, then change rolls and verify measurements update before printing again. Hardware output, live provider availability and heat/battery behavior remain phone checks.
