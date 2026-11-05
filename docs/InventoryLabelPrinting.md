# Price labels — build 71

Build 71 adds [PokéDen logo-and-price labels and bulk-bin
stickers](BrandedPriceTags.md). The branded price layout is the new default;
Card details remains available.

Build 70 adds [direct approval, label-title cleanup and queue-clearing
toolbars](LabelApprovalAndQueueControls.md). Full Review Details is optional.

Build 69 adds [continuous D110-M batches, foreground printer discovery from
Price Tags and remembered physical label sizes](ContinuousLabelPrinting.md).

Build 67 adds [Gap / Transparent paper types](PrinterPaperTypes.md), explicit
printer-setting read/apply actions, and one captured type per print batch.

Build 66 adds [D110-M discovery and its model-specific print workflows](D110MConnection.md).
Both standard D110 and D110-M have their actual model, head and protocol checked
before printing. Search remains available in settings and the saved queue.

Create price labels from saved working inventory or enter a price for a standalone sticker, without an internet request. Build 43 adds [final sticker rules, profit protection and durable approvals](TagPricingRules.md). Inventory draft edits remain separate from financial records; explicit approval activates that inventory sticker as a checkout suggestion, while each sale still records its actual cash amount. Standalone stickers are independent of inventory and cost/profit checks.

## Prepare labels

- One card: **Show → Inventory → card → ••• → Print Price Tag**. That lot starts selected, with one label.
- A batch: **Show → Price Tags**. This dedicated page replaces the inventory toolbar's batch-print option. It also provides direct access to the saved queue and printer settings.
- **Print All** selects every available inventory entry and requests one label per physical copy, including explicit reprints of unchanged stickers. It opens Label Details directly.
- **Print Price Changed** selects new cards, approved tags still needing labels and cards crossing the existing market/competitiveness review thresholds. It proposes current suggested prices for nonmanual entries. Manual prices/categories stay intact until explicitly changed. Merely missing a quote does not flag an otherwise unchanged, labeled card.
- **Custom Price Tag** opens a simple whole-dollar price, copy count and paper form, with a price-only bitmap preview. No inventory, market price, saved show or tag approval is needed. Prepare saves pending labels; printing remains a separate action. Custom stickers never change an inventory asking price or mark any card as labeled.
- **Choose Inventory Cards** keeps search and individual selection, with **Select All / Select All Results** and **Clear**. **Set Same Price for Selected Cards** applies one whole-dollar draft price to selected individual-tag entries; bulk cards stay in their category. **Use Suggested Prices** explicitly replaces selected manual draft prices with available suggestions.
- Choose **Price only** for a large asking price, or **Card details** for name/number, price and condition. Long names truncate; asking prices remain complete.
- Select the paper loaded in the printer: **30 × 14 mm**, **40 × 12 mm**, or **50 × 14 mm**. New inventory and custom labels remember the last selected size across relaunches. Saved queues keep their original size and artwork. The supported head prints a 12 mm strip at eight dots per millimetre; larger stock retains its physical margins.
- New prices follow the final tiers: below $0.75 goes to the 2 for $1 bulk category, $0.75–$0.99 becomes $1, values below $100 round down to dollars, and $100+ rounds down to $5. Bulk cards receive no individual tags. Approved/manual prices stay selected until reviewed. Edit whole-dollar prices/copies in the isolated editor; cost/profit warnings require explicit review.
- All/changed batches start with stock quantities; custom/single-card drafts start at one copy per entry. **Match Stock Quantities** requests one label per available copy; **Use One Label per Card** restores one per lot. The app reports quantities exceeding 100 labels per lot or 250 total instead of silently reducing them. Missing prices can be edited or explicitly skipped as a group.
- Review the actual monochrome bitmap, price, copies, profit information and paper before approving and preparing changed labels. An unchanged existing sticker can be retained without reprinting. Preparing never starts the printer.
- All/changed batch reviews use compact rows with expandable previews, price/copy editors are collapsed together, and Continue/Approve stays pinned to the bottom. Cost and profit warnings still require explicit review. Changed/custom batches skip unchanged, already-labeled stickers; Print All is an explicit replacement-label action.

The preview is decoded from the same packed bits sent to the printer. It does not depend on artwork downloads or current API quotes. Physical paper size is remembered, not detected; confirm it when changing rolls. Gap/Transparent is a separate printer setting.

## Connect and print

Open **Show → Price Tags** to start searching automatically. Allow Bluetooth if prompted, then select your printer on the first visit. Later visits reconnect to the last successfully verified printer when it is found. Turn on the D110 or D110-M, disconnect it in other apps, load matching stock and close its lid. **Settings → Label printer** and **Print Queue** also retain an explicit **Search for D110 / D110-M** action; those pages do not initiate Bluetooth by themselves.

The native connection supports the 96-dot NIIMBOT D110 and D110-M using their distinct documented print workflows. Some product names/model IDs cover different hardware, so unsupported heads and protocol generations are rejected. The supplied build-68 diagnostics confirm D110-M connection and successful labels; batch speed, alignment and output still require acceptance on the phone.

Tap **Print Queued Labels** to process pending labels in one declared-count task on D110-M. The legacy D110 keeps its established per-label workflow. Each physical copy has its own progress entry. A completed entry requires a printer completion response; successful Bluetooth writes alone do not count as completed output. Pause/Stop, leaving the print screen or leaving the foreground stops the active job. The printer may finish a label it already received. An established idle connection can be reused while the app remains open; leaving the foreground disconnects it. The requested search resumes after first Bluetooth permission approval. Returning to Price Tags can reconnect while active, but never starts or resumes printing.

## Interrupted jobs

The queue is a separate versioned file in Application Support: `CardShowScanner/label-print-queue.json`, bounded to 250 copies and 8 MiB. Each copy is marked **Printing** and saved before bytes can be sent. Confirmed completion is saved before the next copy starts.

An interrupted or uncertain in-flight copy becomes **Check label** after relaunch. Other copies retain their status; reopening never starts printing. Select only failed/uncertain copies to retry. Uncertain copies require explicit confirmation that the physical output was checked and another copy is needed. Completed copies cannot be accidentally included in Retry Selected. A separate Start action is still required.

Failed queue writes block further printing. Unreadable, corrupt, oversized or unsupported queue files are retained until you explicitly discard them. Replacement of an unfinished queue requires review/discard; preparing a new batch cannot silently erase its progress. Paper size, template, price and raster snapshots survive relaunch. Clearing the queue changes no inventory or financial record.

## Protocol reference and diagnostics

The native protocol implementation follows the MIT-licensed [MultiMote/niimbluelib](https://github.com/MultiMote/niimbluelib/tree/f451be49d8e30046dee0a8f9d14747fe38f303c2), pinned to `f451be49d8e30046dee0a8f9d14747fe38f303c2`. Its copyright/license notice is bundled in the app and visible in printer settings. Downloaded reference scripts and libraries are not executed or shipped as a runtime dependency.

Diagnostic breadcrumbs contain fixed connection/queue phases and bounded status codes. They exclude advertised device names/IDs, label text, prices, raw Bluetooth payloads and credentials. No backend, website login or API token is required to print.

## Validation and iPhone acceptance

All implementation completes before checks run. Native cases cover label rounding, missing versus zero, bounded copies/text, exact raster orientation and previews, protocol framing/streaming, saved queue ordering, failed writes, interrupted recovery, manual retry acknowledgement, cancellation, duplicate Start and fixture isolation. UI cases cover individual and batch preparation, local price/copy changes, both templates/paper and saved queue relaunch without requesting Bluetooth.

Earlier build-52 checks passed grammar parsing of all **157 Swift files**, Xcode source/target membership (**89 app / 55 native-test / 13 UI-test files**) and bundled-resource membership, all **47 pinned scanner assets**, Bluetooth purpose/privacy metadata, portrait-only and foreground-only configuration, and absence of the removed printer code. Current build-69 results are in [continuous label printing](ContinuousLabelPrinting.md). Native/UI test cases are authored and registered, but this Linux workspace has no Swift/Xcode installation; these portable checks are not native test execution. JavaScript and Python implementations are unchanged and their suites were not rerun locally. On the phone:

1. Open Price Tags and confirm discovery starts; select the printer on the first visit. Reopen Price Tags and confirm it reconnects to that same printer without starting a job. Print one price-only label and check orientation, margins, alignment, cut/feed and readability.
2. Print one Card details label, checking name/number, condition and price. Try every paper size you intend to use, including a long card name and a zero price.
3. Select a batch, edit one price, use Match Stock Quantities, then reduce copies and review. Confirm stock, acquisition costs, saved quotes and budget do not change.
4. Stop during a copy, disconnect/power off, open another tab and leave the foreground. Check physical output before retrying the uncertain copy. Verify no automatic restart when reopening.
5. Complete a small batch, relaunch, inspect saved progress and retry only selected unsuccessful copies. Repeat preparation and printing offline using saved inventory.

Build 50 adds the Show Price Tags workspace and explicit Print All replacement labels without changing the approval file, queue format, pricing thresholds, profit formulas or printer protocol. Barcode/QR scan-to-sell remains a later feature.
