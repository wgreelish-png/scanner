# Branded price tags — build 71

New inventory and custom price tags use the PokéDen Collectibles wordmark on
the left, a vertical divider and a large whole-dollar price on the right, within
a thin rounded border. **PokéDen price** is the default inventory style.
**Card details** remains available for the existing name/code/condition layout.
The preview comes from the same monochrome bits sent to the printer.

Build 77 adds [Price Left / Price Right](LabelPricePosition.md). The original
price-right arrangement remains the default; the selected position is saved
and reused for newly prepared inventory, custom and bulk labels.

The uploaded compact side-by-side SVGs guide the composition. The wordmark is
bundled as PDF glyph outlines, rather than an enlarged 203-DPI PNG or a crop of
the app icon. The development-only generator draws DejaVu typeface outlines;
the app needs no font substitution or external generator. Typeface notices are
bundled and available in Printer Settings. Branded graphics render at four
times the target grid, average coverage into each printer dot and threshold
once to black/white. There is no dithering or scaling after the final 1-bit
raster is packed. A two-dot frame/divider stays legible on thermal stock.

This improves the source and placement of edges while retaining the hardware's
203-DPI limit. The sample package's 112/120-dot short edges are adjusted to the
verified 96-dot head instead of sending unsupported or clipped rows. Short
40-mm bulk tags use **2 FOR $1**; 30-mm tags use **2/$1** to keep the price beside
the wordmark. Already-calculated prices are formatted, not recalculated.

Paper choices include **40 × 12 mm**, **30 × 14 mm**, **30 × 15 mm** and the
existing **50 × 14 mm** size. The verified D110/D110-M print head is 96 dots
(12 mm) across. A 14 or 15 mm physical roll has a larger margin; it does not
enable a 112- or 120-dot head. The artwork stays within the supported printable
strip, with feed lengths of 320, 240, 240 and 400 dots respectively. Last-used
physical size remains shared across inventory/custom preparation.

**Price Tags → 2 for $1 Bulk Tags** prepares stickers for a bulk bin or box.
The custom editor can switch between an individual price and **2 for $1**.
Bulk stickers need no cash-price entry; switching back retains a previously
entered individual price. Copies, paper, preview, saved queue and explicit Print
work as usual. A bulk sticker is not an individual $0 or $0.50 asking price.
Its saved queue entry carries an explicit bulk marker and no inventory or
approval identity. Legacy individual $0 labels remain $0 labels.

Inventory cards below the existing bulk threshold retain their 2-for-$1
category and still do not generate one individual sticker per card. Printing
a bulk-bin sticker changes no inventory quantities, acquisition costs, asking
prices, approvals, show balances or transaction history. Existing saved queue
artwork remains immutable; clear and prepare a fresh queue to use this design.

## Phone checks

1. Prepare $3 and $28 custom tags using 40 × 12 and 30 × 14 mm rolls. Check
   the exact preview, wordmark, price, border, alignment and margins after
   printing. Repeat with 30 × 15 mm paper if loaded.
2. Prepare inventory labels and confirm PokéDen price is selected by default.
   Select Card details to check the earlier layout is still available.
3. Open 2 for $1 Bulk Tags. Prepare without entering a price, then check the
   saved queue, relaunch and print. Confirm the label reads 2 FOR $1 (40 mm)
   or 2/$1 (30 mm), and
   inventory/financial values remain unchanged.
4. Switch a custom $5 tag to bulk and back. Confirm $5 is retained; an individual
   $0 tag must never turn into a bulk tag without the explicit selection.

## Validation

Implementation completes before checks. Native cases cover branded raster
regions, every supported physical size, complete prices, bulk persistence and
legacy individual-zero distinction, approval isolation and unchanged queue
behavior. UI coverage includes direct bulk entry, 30 × 15 mm preparation,
relaunch and unchanged inventory/balances. Native execution and physical output
require Xcode and the phone. Portable checks passed grammar parsing for all
192 Swift files, source/resource membership, build 71 metadata, data-asset
references, the development generator's syntax and `git diff --check`. PDF
inspection confirms the wordmark contains no embedded raster images.
