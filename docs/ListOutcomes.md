# Build 14: saved list outcomes

The **List outcome** section appears at the top of list review, including lists opened from the scanner and from Open Existing List.

- **Record Transaction** opens Purchase, Trade + Purchase, or Trade. After saving, this button shows the selected operation.
- **Nothing Happened** records that the deal did not go ahead. Its checkmark identifies the saved choice.
- **No status** means no outcome has been chosen. Opening the chooser, cancelling, closing the list or closing the app does not mark a transaction.

The outcome and recorded date stay with the list across app relaunches. The saved-lists screen shows the outcome beneath each list's name and quantity. Choose another operation to change it. List options → **Clear List Outcome** returns it to No status. Selecting the same outcome again keeps its original recorded date.

Recording an outcome keeps the list, cards, physical scan order, quantities, prices and saved offers. It does not finish or resume a scanning session. Continued scanning retains the list's outcome; a duplicated list starts at No status because copying a list does not establish another completed deal. A failed save retains the previous outcome and provides a retry message.

This feature records what operation happened. It does not turn estimated offer values into actual payments, sale proceeds, fees or realized profit.

## Upgrade and validation

Build 14 uses storage schema V3 with one optional metadata field on CardList. The released V1 and V2 definitions are preserved, with lightweight upgrades through each version. Existing lists start at No status. The app never deletes a database or substitutes an empty store when migration fails.

Native regressions cover every outcome across disk relaunch, marking/changing/clearing, Nothing Happened versus untouched No status, idempotence, failed-save rollback/retry, unrelated edits, completed and resumed lists, duplication, invalid metadata and migration of a complete V2 store. The migration fixture checks original card data, order, legacy quantities, per-card overrides, active and archived sessions, rates, recognition references and saved offers. The existing V1 migration regression remains enabled. The UI regression records all outcomes, closes/reopens the app six times, checks saved-list badges and preserves an unrelated unmarked list.

At `e33c3bd`, [macOS CI](https://github.com/wgreelish-png/scanner/actions/runs/40581364071) passed all 188 native tests, all three simulator UI tests and the Personal-scheme Release iPhone build. Both V1 and released-V2 migration fixtures passed. JavaScript, helper, source-membership and runtime checks passed as well. This verifies the outcome and clear flows in the simulator; physical-iPhone acceptance remains pending.

On the iPhone, install build 14 over the existing app with the same signing configuration. Verify Settings → About this app shows Build 14 and release `list-transaction-outcomes`. Open an existing list, record an outcome, close/reopen the app and confirm the badge. Test Nothing Happened, changing the operation and clearing it, then check that the list and saved offers remain available. Actual phone interaction remains an acceptance check.
