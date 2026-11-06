# Write-in price tags — build 82

Every selected inventory copy still receives a label. If its price is
unavailable or zero, the new label keeps the logo, border and divider but leaves
the price area empty for handwriting. It prints no dollar sign, zero, question
mark or unavailable-price message. Card-details labels keep their name, code
and condition and reserve clear space for the handwritten price.

An empty inventory price field also selects a write-in label. Nonempty malformed
or negative input, cents-priced new stickers, invalid copies and oversized
batches still require correction. A known positive saved sticker remains usable
when its market quote is unavailable. An explicitly saved 2-for-$1 category
still prints that deal; its internal zero sentinel is not a zero-dollar price.
For a new lot with no saved sticker and a missing or zero inventory value,
printing does not infer a deal or invent a price.

Custom Price Tag accepts 0 for a write-in label. Its untouched empty price form
still requires input, so opening that screen does not select a blank job by
default. Standalone 2-for-$1 tags retain their deal artwork.

Counts, previews, review, copies and queue preparation include write-in labels.
No price approval is created for the blank area, and completing a write-in label
does not claim that a priced sticker has been printed. The inventory's saved
price/category, market value, costs, stock, receipts and balances remain intact.
Known-price labels keep their existing revision checks and printing history.

New queue snapshots explicitly identify a blank price. Older saved queues retain
their original printer bits and display, including old printed $0 artwork.
Pending old $0 labels require clearing and preparing again rather than printing
the old zero; historical completion receipts remain intact. Detected RFID
paper measurements, saved price-side preferences, exact printer-bit previews,
continuous printing and interrupted-job recovery remain in place.

## Phone checks

1. Select an unpriced card, a zero-valued card and a positive-priced card. All
   requested copies count toward the total. The first two previews should show
   an empty price area; the positive price should stay visible.
2. Open an inventory label editor. Leave its price empty, or enter 0, then save
   and prepare. The tag remains in the batch without a required-price warning.
3. Check a saved positive price whose market quote is missing, and a saved
   2-for-$1 card. Both should print their actual saved sticker, not a placeholder.
4. Open Custom Price Tag and enter 0. Confirm it previews and queues a write-in
   label. An untouched empty custom form remains unprepared; the bulk-tag form
   still prints its 2-for-$1 deal.
5. Print write-in tags with Price Left and Price Right on the detected roll.
   The price area should be empty on the selected side, with readable remaining
   artwork. Repeat with Card Details and check the reserved writing space.
6. Check inventory, prices and balances after preparation/printing. Blank tags
   must not create $0 prices or acknowledge a real priced sticker. Reopening an
   old queue must preserve its existing art and completion receipts.

Native/UI execution and physical output require Xcode, the phone and printer;
portable checks alone cannot establish print alignment or handwriting space.

Local checks passed: 322 portable tests (172 JavaScript, 59 server, 49 Postman
and 42 Python), grammar for all 207 Swift files, source/resource membership,
both OpenCV smoke tests, pinned scanner resources, build metadata and whitespace
checks. Thirteen native regressions and one UI regression were added. These
native/UI cases require Xcode execution and are not portable test results.
