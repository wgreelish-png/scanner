# Research-first card taps — build 53

Tapping a card in a saved list, the imported Card Show list or Show Inventory
opens the combined Card Research page with Market selected. A separate editor
or details page no longer comes first. Browsing preserves the main tabs.

The card actions menu (•••) provides Edit Card for an ordinary saved list,
Imported Card Details for the website snapshot, and Inventory Details for local
stock. Inventory Details retains cost editing, acquisition receipts and the
single-card label action. Sell This Card stays directly on the stock research
page, using the same stock identity, scheduled-show guard and transaction form
as Inventory Details. Refresh and API connection remain directly accessible.

Research selections stay read-only: changing a research condition or printing
does not edit the saved card, inventory quantity, cost, transaction or budget.
Editors still start from saved card data and require explicit Save. Existing
manual-price drafts retain their Save/Cancel and tab-navigation behavior.
Imported website cards remain read-only.

## Validation

All implementation finishes before checks. Existing UI scenarios now assert
direct Market navigation from ordinary and imported lists and local stock,
explicit Edit/Details navigation, unchanged research-only selections, draft
Save/Cancel and tab retention, quick-sell cancellation/return, saved financial
values and the single-label route. They are authored for Xcode execution.

Local checks passed after implementation: grammar for all 187 Swift files,
source membership for 105 app / 68 native-test / 14 UI-test files,
build-53/portrait/foreground metadata and whitespace. Xcode/native/UI execution
is unavailable in this Linux workspace; CI is pending after push, without
waiting for a simulator runner. Physical-iPhone navigation remains unverified.

On an iPhone, tap one saved card and one inventory card, confirm Market opens,
then use ••• for editing/details. Change a research condition and return without
saving to confirm the stored card is unchanged. In inventory, open and cancel
Sell This Card and preview a label from Inventory Details. Confirm the main
tabs remain accessible and that Back returns through the chosen screens.
