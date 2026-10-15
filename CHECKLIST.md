# Card Show Sessions v1

## Implemented

- [x] Extend the existing SwiftUI/SwiftData app and preserve scanner providers, CSV and diagnostics.
- [x] Explicit new batch creates one timestamped list; one active batch at a time.
- [x] Persist session/list ID, selected game, status, dates and rates.
- [x] Resume the active batch without creating empty sessions on launch/navigation.
- [x] Confirm finish/start when replacing a batch or changing its game.
- [x] Home current-session card, All Sessions, review links and pinned scanner totals.
- [x] Finish retains list/cards; rename preserves identity/date; old history remains separate.
- [x] Decimal offer calculator with cash/trade/maximum percentages and per-copy overrides.
- [x] Exclude/highlight unpriced copies; distinguish known zero.
- [x] Snapshot new-session rates; immutable saved offer estimates and original inputs.
- [x] Preserve recognition deduplication and a consumed marker across camera/app restarts.
- [x] Versioned migration from original fields; visible storage errors without destructive fallback.
- [x] Add ten native session/pricing/migration regression tests (24 total).
- [x] Run eleven JavaScript bridge tests and static Swift/project validation.

## Required on Mac/iPhone

- [ ] Compile this update in Xcode.
- [ ] Run all 24 native tests, including the original-store migration fixture.
- [ ] Verify migration on an existing app install without uninstalling.
- [ ] Perform [device acceptance checks](docs/SessionsV1.md) for resume, game change, offers, saved estimates, CSV and live scanning.
- [ ] Review accessibility, larger text, dark mode and long-session performance.

Automatic bulk classification, actual-paid accounting, net-profit projections, sales/cash transactions, inventory sync and TCGTracking CSV compatibility remain outside this update.
