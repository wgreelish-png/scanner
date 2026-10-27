# Export a scanned inventory list

From the scanner, choose **View List**. You can also use **Open Existing List** on the home screen and select the saved list. The **Export inventory** section is at the top of list review, above the offer calculations.

- **Export CSV to Files** opens the iPhone file picker. Choose a folder and save the file; you can change its filename there.
- **Share CSV** opens the iOS share sheet for AirDrop or another destination.

The export includes every saved row in its original scan order, even when list review has a search filter or another sort selected. Identical scanned copies remain separate rows; legacy quantities are retained. It uses the existing saved data and does not change or finish the session, modify offers, or start the camera.

Columns are Game, Name, Set, Number, Product ID, SKU ID, Printing, Language, Condition, Quantity, Market Price and Total Value. Market prices are the saved per-copy values. Missing prices are blank; a known zero remains zero. These are market values, not a record of the amount paid for inventory.

CSV escaping, unknown prices, separate duplicate rows, stored scan order and export after reopening are covered by the existing native regressions. Verify the iPhone Files/share presentation with a small list before exporting a large inventory.
