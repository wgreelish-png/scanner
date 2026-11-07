# Label print order — build 97

Revision: `label-price-print-order`.

Use **Print order** in Label Details or Review Labels to choose **Card Name**,
**Price: Low to High** or **Price: High to Low** before preparing the queue.
Card Name is the existing preparation default. The selected label order is
remembered for later preparation independently of inventory sorting and printer
transfer preferences.

Price order uses numeric sticker prices. A **2 for $1** tag sorts as **$0.50 per
card**, while its printed wording stays the same. Blank/write-in prices are
always last in both price directions. Equal prices use card name as the next
sort key; equal names and repeated copies retain their relative order.

For example, the same priced tags sort as:

- Ascending: 2 for $1, $1, $4, $28, blank.
- Descending: $28, $4, $1, 2 for $1, blank.

An existing queue changes only through its explicit **Sort Labels** menu.
That action sorts pending entries; printed receipts, failed and uncertain
entries keep their positions and review state. Sorting is disabled during an
active print job. Opening the queue or starting printing does not sort it again.
The next pending labels are sent in their displayed row order.

Sorting preserves each prepared raster, price, copy number, paper size and price
position. It does not change inventory, financial records or Bluetooth settings.

To check the feature, prepare differently priced inventory tags, including an
equal-price pair, bulk and blank tags. Select each order, inspect preparation and
review, and compare the pending queue rows with physical output. Reopen
preparation to check the saved choice. On a queue containing existing receipts
or review entries, confirm that explicitly sorting moves only pending rows.

The existing manual `label_preview` CI scope already includes InventoryLabelTests
and LabelPrintQueueTests for the ordering checks. Native, UI and Release checks
run in the background after implementation is complete.
