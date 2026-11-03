# Inventory labels — build 42

Create price labels from saved working inventory without an internet request. Build 43 adds [final sticker rules, profit protection and durable approvals](TagPricingRules.md). Draft edits remain separate from financial records; explicit approval activates the sticker as a checkout suggestion, while each sale still records its actual cash amount.

## Prepare labels

- One card: **Show → Inventory → card → ••• → Print Price Tag**. That lot starts selected, with one label.
- A batch: **Show → Inventory → ••• → Print Price Tags**. Search and select available cards, then continue.
- Choose **Price only** for a large asking price, or **Card details** for name/number, price and condition. Long names truncate; asking prices remain complete.
- Select the paper loaded in the printer: **30 × 14 mm**, **40 × 12 mm**, or **50 × 14 mm**. The supported head prints a 12 mm strip at eight dots per millimetre; larger stock retains its physical margins.
- New prices follow the final tiers: below $0.75 goes to the 2 for $1 bulk category, $0.75–$0.99 becomes $1, values below $100 round down to dollars, and $100+ rounds down to $5. Bulk cards receive no individual tags. Approved/manual prices stay selected until reviewed. Edit whole-dollar prices/copies in the isolated editor; cost/profit warnings require explicit review.
- Each selected lot starts at one copy. **Match Stock Quantities** explicitly requests one label per available copy; **One Each** restores one per lot. The app reports quantities exceeding 100 labels per lot or 250 total instead of silently reducing them.
- Review the actual monochrome bitmap, price, copies, profit information and paper before approving and preparing changed labels. An unchanged existing sticker can be retained without reprinting. Preparing never starts the printer.

The preview is decoded from the same packed bits sent to the printer. It does not depend on artwork downloads or current API quotes. Label paper choice is explicit: the baseline printer does not reliably report its physical sticker size.

## Connect and print

Open **Settings → Label printer**, or connect from **Print Queue**. Turn on the D110, load matching stock, close its lid and tap **Search for D110**. Bluetooth permission is requested only after Search. Merely opening inventory, labels, settings or a saved queue does not create a Bluetooth manager or request permission.

The native connection targets the standard 96-dot NIIMBOT D110 protocol. Some product names/model IDs cover different hardware, so unsupported or unverified hardware is rejected instead of receiving a guessed print sequence. This implementation still requires a physical iPhone/D110 acceptance test; protocol documentation and successful builds do not establish hardware compatibility or label quality.

Tap **Print Queued Labels** to process pending labels serially. Each physical copy has its own progress entry. A completed entry requires a printer completion response; successful Bluetooth writes alone do not count as completed output. Pause/Stop, leaving the print screen or leaving the foreground stops the active job. The printer may finish a label it already received. An established idle connection can be reused while the app remains open; leaving the foreground disconnects it. The first explicit Search continues once after Bluetooth permission is granted and the app is active. There is no background mode or automatic reconnection/reprint.

## Interrupted jobs

The queue is a separate versioned file in Application Support: `CardShowScanner/label-print-queue.json`, bounded to 250 copies and 8 MiB. Each copy is marked **Printing** and saved before bytes can be sent. Confirmed completion is saved before the next copy starts.

An interrupted or uncertain in-flight copy becomes **Check label** after relaunch. Other copies retain their status; reopening never starts printing. Select only failed/uncertain copies to retry. Uncertain copies require explicit confirmation that the physical output was checked and another copy is needed. Completed copies cannot be accidentally included in Retry Selected. A separate Start action is still required.

Failed queue writes block further printing. Unreadable, corrupt, oversized or unsupported queue files are retained until you explicitly discard them. Replacement of an unfinished queue requires review/discard; preparing a new batch cannot silently erase its progress. Paper size, template, price and raster snapshots survive relaunch. Clearing the queue changes no inventory or financial record.

## Protocol reference and diagnostics

The native protocol implementation follows the MIT-licensed [MultiMote/niimbluelib](https://github.com/MultiMote/niimbluelib/tree/f451be49d8e30046dee0a8f9d14747fe38f303c2), pinned to `f451be49d8e30046dee0a8f9d14747fe38f303c2`. Its copyright/license notice is bundled in the app and visible in printer settings. Downloaded reference scripts and libraries are not executed or shipped as a runtime dependency.

Diagnostic breadcrumbs contain fixed connection/queue phases and bounded status codes. They exclude advertised device names/IDs, label text, prices, raw Bluetooth payloads and credentials. No backend, website login or API token is required to print.

## Validation and iPhone acceptance

All implementation completes before checks run. Native cases cover label rounding, missing versus zero, bounded copies/text, exact raster orientation and previews, protocol framing/streaming, saved queue ordering, failed writes, interrupted recovery, manual retry acknowledgement, cancellation, duplicate Start and fixture isolation. UI cases cover individual and batch preparation, local price/copy changes, both templates/paper and saved queue relaunch without requesting Bluetooth.

After implementation, local checks passed grammar parsing of all **157 Swift files**, Xcode source/target membership (**89 app / 55 native-test / 13 UI-test files**) and bundled-resource membership, all **47 pinned scanner assets**, Bluetooth purpose/privacy metadata, portrait-only and foreground-only configuration, and absence of the removed printer code. Native/UI test cases are authored and registered, but this Linux workspace has no Swift/Xcode installation; these portable checks are not native test execution. JavaScript and Python implementations are unchanged and their suites were not rerun locally. Physical printing remains pending. On the phone:

1. Open labels without Search and confirm no permission popup. Search explicitly, connect and print one price-only label. Confirm orientation, margins, alignment, cut/feed and readable price.
2. Print one Card details label, checking name/number, condition and price. Try every paper size you intend to use, including a long card name and a zero price.
3. Select a batch, edit one price, use Match Stock Quantities, then reduce copies and review. Confirm stock, acquisition costs, saved quotes and budget do not change.
4. Stop during a copy, disconnect/power off, open another tab and leave the foreground. Check physical output before retrying the uncertain copy. Verify no automatic restart when reopening.
5. Complete a small batch, relaunch, inspect saved progress and retry only selected unsuccessful copies. Repeat preparation and printing offline using saved inventory.

Build 43 implements persistent approvals, current pricing rules and review thresholds. Quick reprint and barcode/QR scan-to-sell remain later features. This release does not restore the removed printer integration.
