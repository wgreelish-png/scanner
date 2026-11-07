# Inventory and labels by game — build 100

Revision: `inventory-game-print-filter`.

Use the game picker in **Show Inventory** or **Price Tags** to view one game's
stock. **All Games** is the existing default. The selected game is shared between
these screens and remembered after reopening or relaunching the app.

Common game aliases match the same filter choice. Pokémon Japan stays separate
from Pokémon, and unrecognized/custom game values remain available. Matching
aliases does not rewrite the game identity saved on a card.

Inventory rows and summary totals reflect the selected game. Existing search
and inventory sorting work within that scope. Changing the filter does not alter
quantities, prices, cost basis or inventory provenance. Transaction selections
remain valid against the full stock; a game filter does not remove an otherwise
valid selected card just because it becomes hidden.

In Price Tags, the selected game's stock determines the summary and the inputs
for **Print All**, **Print Price Changed** and **Select Individual Inventory**.
Use the existing **Print order** choice to sort that new batch by card name or
price. Label ordering and game filtering remain independent saved choices.

An existing print queue keeps its prepared entries, artwork and order, including
labels from other games. Opening a screen, changing the game or starting a job
does not rebuild that queue. Label size, price position and Bluetooth transfer
preferences remain unchanged.

## Phone check

1. With stock from multiple games, open Show Inventory. Select one game and
   check that its rows and summary totals match. Try search and the existing
   inventory sort within that game.
2. Open Price Tags and confirm the same game is selected. Print All and Print
   Price Changed should use only that game's eligible stock; Select Individual
   Inventory should offer only that game's cards.
3. Choose a price order, prepare labels and review the queue rows. Changing the
   game afterward must leave that already-prepared queue intact.
4. Return to All Games to see the complete stock. Reopen or relaunch to check
   the remembered choice, including a custom game or Pokémon Japan if present.

The focused `label_preview` native selection includes ShowInventorySortTests and
InventoryLabelBatchTests for game matching, preference and preparation coverage.
Checks start after implementation; results are reported separately.
