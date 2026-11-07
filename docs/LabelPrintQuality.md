# Label print quality — build 96

Revision: `aligned-thermal-label-artwork`.

Enlarged previews now use smooth screen interpolation when displaying the
decoded label bitmap. The preview still comes from the prepared printer raster;
this display change does not add grayscale or extra dots to the print data.

For dimension-driven branded labels, the rounded frame and divider align to the
native printer-dot grid before rendering. This reduces fractional-dot stroke
placement while retaining the current composition. The existing wordmark and
price text keep the same rendering path, including 4× supersampling and the
final black/white threshold. Paper dimensions, printable regions, price position,
font choices and inventory values remain unchanged.

The D110/D110-M output remains binary thermal printing at about 203 DPI. Screen
interpolation cannot increase that physical resolution; curved edges still use
discrete printer dots. This change does not alter image encoding, acknowledged
Bluetooth writes, pacing, copy grouping or printer-confirmed completion.

Prepared queue entries retain their saved raster. To check the new physical
stroke alignment, prepare fresh pending labels using the same paper and transfer
settings. Existing printed or uncertain work keeps its review state.

## Phone and printer check

1. Confirm that the detected or remembered paper matches the loaded roll.
   Keep the current printer-transfer settings unchanged during this comparison.
2. Prepare fresh **$1**, **$4** and **$28** tags, one **2 for $1** bulk tag and
   one **blank-price** tag. Use **Price Right** and inspect the on-screen previews.
3. Print and check each physical label's price, readable wordmark, border,
   divider, margins and complete artwork. The blank price must leave its writing
   area empty, and the bulk tag must keep its existing deal wording.
4. Repeat the same five cases with **Price Left**. Check the price moves to the
   left while the wordmark and digits stay readable. Reopen preparation and
   confirm the selected side and paper are still remembered.
5. Compare the physical output with a previous label on the same roll. Send
   photos of any broken, doubled, uneven or clipped strokes, together with the
   paper size and price position. Physical quality remains pending this check.

The manual `label_preview` CI scope selects the inventory/adaptive rendering,
custom preparation, custom queue, saved queue and transfer-preference native
tests, alongside the existing focused label-preview UI checks and Release build.
Normal/full and printer-transport test selections remain independent. Automated
validation results are recorded separately when the background checks finish.
