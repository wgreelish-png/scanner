# Remembered label price position

Build 77, revision `label-price-position`.

The earlier branded renderer fixed the logo on the left and the price on the
right. It did not include a flip setting. The new **Price position** selector
offers **Price Left** and **Price Right** in Label Details and Custom Price Tag,
including 2-for-$1 bulk tags. Printer Settings provides the same default.

Selecting a side immediately saves it to the shared
`niimbotLabelPricePosition` preference. The next newly prepared label uses that
side, including after closing/reopening the screen or relaunching the app.
Inventory, custom and bulk paths use the same preference. Paper size, media
type and saved prices remain independent. Existing installations default to
Price Right until a selection is made.

Price Left moves the price block to the left and the logo to the right. Letters,
digits and the wordmark retain their ordinary readable orientation; this is
not a mirrored image or a 180-degree rotation. Font sizes, content widths,
rounded frame, vector wordmark, four-sample coverage and final 203-DPI printer
packing retain the existing rendering pipeline. Every supported paper size
and bulk-bin deal layout supports both sides. Card details retains its classic
name/code/condition layout and hides the branded position selector.

The preview is decoded from the exact raster sent to the printer. Prepared
queue entries remain immutable: changing the preference affects new label
preparation, not queued or partially printed copies. Clear the saved queue to
prepare replacement labels with the new side. No queue schema, inventory,
price revision, financial record or printer command protocol was changed.
Older encoded inventory label drafts without a position still decode as right.

## Phone check

1. Open Label Details or Custom Price Tag, choose Price Left and inspect the
   preview. The price should be on the left, with both price and logo readable.
2. Close that screen and open a different label path, including Bulk Tags.
   Confirm Price Left is already selected and the preview uses it.
3. Relaunch the app. Prepare a new inventory or custom label and verify the
   selection is still Price Left. Print one label and compare it with preview.
4. Switch to Price Right and repeat the reopen/relaunch check. The original
   arrangement should return without affecting paper/media settings.
5. Prepare a queue, then change the default in Printer Settings. Verify the
   queued preview keeps its original prepared layout; clearing and preparing
   a new queue uses the newly remembered side.
6. Check both sides on the loaded supported roll, a long dollar amount and a
   2-for-$1 bulk tag. Existing price values and copy counts should be unchanged.

Native tests cover preference persistence/isolation, legacy decoding,
prepared-state invalidation and immutable queue data. Raster tests cover box
geometry, unchanged right defaults, unmirrored translated content, all papers,
long prices, bulk deals and preview/printer-bit parity. UI tests cover the
saved selection across preparation paths and relaunch. Native execution and
physical print acceptance require Xcode/an iPhone and printer.

Local validation passed: 320 portable tests (172 JavaScript, 59 server, 49
Postman and 40 Python), grammar for all 196 Swift files, Xcode source/resource
membership, the 47 pinned scanner assets, both OpenCV smoke tests, build metadata
and whitespace checks. The preference, bitmap and UI tests require native
Xcode execution and are not counted among the portable tests.
