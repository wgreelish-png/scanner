# Build 108: show workflow improvements

Implementation follows the diagnostic-21 review and the requested printer-flow cleanup. Inventory contents, quantities, saved settings, print order, transport commands, printer-confirmed completion and financial calculation rules are preserved. The new list price-recovery action changes missing quotes only when explicitly requested.

## Changes

- Custom/bulk tags and selected inventory now have a direct **Print** action on the preview/configuration screen, followed by progress and return to Price Tags. **Review Queue** is optional. Interrupted/uncertain output still requires explicit review before retry.
- Completed-only inventory receipts can be replaced by a new custom/bulk job; unfinished/uncertain work remains protected. The Price Tags queue count represents outstanding work. Roll reading shows a wait state, rather than an empty-queue discard warning. Copy-only custom edits reuse the same artwork and keep the preview stable.
- Automatic website IP checks pause after sign-in-required/account mismatch until an explicit check or authentication change. Optional checks pause during serious/critical heat. Foreground, account, cancellation and server cooldown safeguards remain; website check failure does not prohibit an independent Direct API request.
- Initial manual confirmation uses the daily quote cache. Explicit Retry/Refresh still requests fresh data.
- Saved editable lists expose **Refresh Missing Prices** in List options, with a fixed progress/summary bar and Cancel. Requests are serial and respect the cache. Known prices, including a real zero, are untouched. Current rows, persisted baselines and request generations fence out changed/deleted targets. Existing quantity, order, overrides, costs, stock and receipts are retained. A dirty model context stops the pass without saving or rolling back unrelated edits. Serious/critical heat stops the pass with completed updates retained. Imported source inventory is excluded.
- Offer overrides on unpriced cards are described as saved but not included. Entirely unknown totals display Unavailable; genuine zero quotes and explicit custom cash values remain visible. The existing exclusion policy and saved historical calculations are unchanged.
- New/changed per-card overrides accept at most two decimal places, matching checkout. Untouched legacy values are preserved, with a warning when correction is needed before a new transaction; no silent rounding of historical values.
- Declining automatic manual search starts a two-minute cooldown for that scan session. Search Manually remains available and suppression releases the bridge latch so recognition continues.
- App lifecycle diagnostics come from the root across all screens, with duplicate transitions suppressed. Beta Research/Market Activity coverage is checked separately from public pricing; unsupported games get a coverage message rather than misleading credential advice. Genuine access failures show a nearby API Connection action and relevant sign-in/cooling context.

## Phone test plan

| Flow | Check |
| --- | --- |
| Custom and bulk | Enter a price and several copies. Change only copies and confirm stable artwork. Tap Print once: progress opens directly; the queue-review screen is skipped. Wait for completion and return to Price Tags. Repeat with 2 for $1 tags. |
| Individual inventory | Select several different prices, set low-to-high order and print from the preview. Verify every physical label, order and copy count. After completion, immediately print a custom tag without clearing finished receipts. |
| Recovery | Pause a test job or disconnect during upload. Confirm unsuccessful/uncertain work stays available for review; nothing automatically retries. Check physical output before authorizing uncertain retries. |
| Printer readiness | During roll detection, confirm the UI says it is reading measurements. A disconnected printer should make Print unavailable with a connection route; optional Review Queue remains available. |
| Missing prices | On a saved list containing unknown, known-zero and manually priced entries, choose List options → Refresh Missing Prices. Verify only unknown entries change, totals update, and copies/overrides/financial records stay the same. Repeat offline, cancel partway, and retry a partial pass. |
| Editing and recovery | Open another card/list while refresh is pending or cancel the pass. A late result must not overwrite an edit or deleted card. Finish any unsaved edits before starting another pass. |
| Offers | An unpriced card with an override says it is not included; unknown-only totals say Unavailable. Known $0 remains $0. Enter a new override with three decimal places: Save is unavailable until corrected. Existing historical values remain unchanged. |
| Manual search | Add a card manually and verify automatic return without reopening the database. Reopen another card: normal cached pricing works; explicit Refresh still checks anew. Decline a suggested manual search and verify no repeat modal for two minutes, with Search Manually still reachable. |
| API access | A sign-in-required website check should pause automatic retries. Explicit Check IP Now or returning from sign-in permits another check. Public pricing still works independently. Unsupported Beta games show coverage information; genuine access failures offer API Connection. |
| Diagnostics | Visit Settings, printing and research, then background/return. Export the log: one root scene transition per phase should appear, alongside activity breadcrumbs. Observe normal temperature/battery behavior during ordinary use; this change makes no measured energy or hardware-reliability claim. |

## Software validation

Focused native cases cover authentication/thermal pauses, cache selection, cooldown/lifecycle, exact missing-price recovery and persistence fences, override presentation/validation, custom raster reuse, completed receipts, duplicate starts and final acknowledgement. Four targeted UI cases exercise direct custom printing, individual-to-custom printing, failed/uncertain recovery and missing-price updates. `job_scope=show_polish` runs portable checks, all native tests and those four UI cases; broader UI groups and Release remain separate opt-ins. Queued/running checks are not passing results.

Local validation passed: 69 portable Python tests, 182 JavaScript tests, grammar parsing of all 42 changed/new Swift files, Xcode source/resource membership (including the new model and native tests), 47 pinned scanner assets, app plist, runner shell syntax and whitespace checks. Linux does not provide Xcode; native compilation and test execution are delegated to the focused GitHub run. Printer output, live API access and phone temperature/battery behavior remain phone checks.
