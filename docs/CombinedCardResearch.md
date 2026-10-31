# Combined Market and Graded Research

Build 28 opens one **Card Research** page from a saved card, scanner review or catalog search. PSA confirmation opens the same page in **Graded** mode with its verified card grade, including qualifiers. There is no additional card-selection screen after a catalog result.

The card artwork, name, set, number and game appear once. Shared **Printing** and **Language** menus apply to both modes. An ambiguous printing must be explicitly chosen. Technical product/SKU references are kept internally and do not crowd the page.

| Mode | Controls and information |
| --- | --- |
| Market | NM, LP, MP, HP and DMG; exact-condition Open API market value; optional listing details; OppsV2 reported units and sold averages for 30/90/365 days. Additional activity/listing information is collapsed. |
| Graded | Exact returned grader/grade selection; guide estimate, research market value and population; reported 30-day sales/average when available. Additional research is collapsed. |

Build 30 adds **View Card on TCGplayer** under the shared selections in both modes. It opens the exact catalog product page for listings and TCGplayer’s sales graphs. The verified API does not supply exact lowest-listing URLs, so the app does not fabricate a seller link or a condition-specific history URL.

The mode switch stays at the top. A short update/cache label and the information button replace the large evidence block. The information sheet contains timestamps, source explanations and coverage limits. Live charts and history enhancements remain deferred until the Beta APIs are fully released; earlier chart components remain isolated in explicit DEBUG fixtures.

## Data and lifecycle

Only the visible mode loads. Market price and optional sales activity can finish independently; a Beta failure leaves a successful public price available. Switching modes retains completed data, period and grade choices, cancels unfinished work and rejects late responses. Changing printing/language/condition immediately retires old data and loads only the active mode. A grade selection uses the already-returned research response.

Refresh targets the visible mode. Returning from API Connection invalidates old account-dependent results and retries the visible mode through normal caches. Leaving the page or making the app inactive cancels pending work. Existing daily refresh, separate data/HTTP ETags, shipper request limits and bounded disk caches are unchanged; no new endpoints or background jobs are introduced.

Selections are research-only copies. They do not save cards, replace inventory prices, change quantities, merge rows, recalculate offers or alter a scan confirmation. Research estimates remain separate from raw market prices. Missing values remain unavailable, real zeroes remain zero, and another printing/language/grade is never substituted. RAW research combines conditions. Research is still experimental and coverage is partial.

## Validation

Native cases cover lazy loading, mode reuse, exact shared selections, ambiguous printing, period/grade retention, canceled late replies, inactive refresh, service failure isolation, connection return, explicit refresh and unchanged persisted rows/offers. A DEBUG fixture UI case covers mode navigation, retained condition/period, one header and absent live charts. No test fixture is an automatic production fallback.

After implementation completed, local checks passed grammar parsing of all 111 Swift files, target membership for 64 app/39 native-test/8 UI-test files, all 47 pinned scanner assets and dependency closure, and whitespace validation. Xcode is unavailable in this Linux workspace; these checks do not compile Swift or prove device behavior. Native/UI execution and the unsigned Release build run through the existing macOS CI jobs. Consult the branch's latest run for actual outcomes; live-iPhone acceptance remains unverified.

On an iPhone, verify:

1. Open research from a saved card and scan review; switch Market/Graded without another card screen. From Research search, open a catalog result directly. Confirm a PSA match and verify its exact grade is retained.
2. Change printing/language and Market condition. Check exact values or unavailable messages, then return to Graded and choose a returned grade. Repeated mode changes retain the current choices and Market period.
3. Return from API Connection after correcting credentials; retry partial coverage and unavailable conditions. Confirm public pricing still works if Beta access fails.
4. With slow connectivity, change selections, switch modes, leave the page and lock/resume the phone. Old responses must not replace the current selection.
5. Confirm the original saved card, quantity, scan order and offers remain unchanged. Check large text, light/dark mode and the information sheet. Live account access, real PSA lookup and physical scanning require device validation.
