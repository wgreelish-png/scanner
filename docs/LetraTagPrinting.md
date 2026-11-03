# LetraTag price tags — build 39

The app now has an opt-in native Bluetooth connection for the DYMO LetraTag 200B and local inventory price-tag previews. This is experimental: our iPhone-to-printer path and physical label quality have not been verified on hardware. A third-party project's claimed hardware support is not a successful test of this app.

## First connection

1. Load a DYMO LT 12 mm cassette, turn on the printer and keep it near the iPhone. Close another app if it already holds the printer's Bluetooth connection.
2. Open **Settings → Label printer → Search for Printer**. Merely opening settings or a tag preview does not initialize CoreBluetooth or request permission.
3. Allow Bluetooth access, select the discovered LetraTag and wait for the connection status. Discovery accepts documented LetraTag advertised names and the discovered service UUID prefix; characteristic UUID tails must match that exact service.
4. Tap **Print One Test Label** once. Check readable upright text, paper feed, condition and the $10 test price. Use the printer's physical cutter as needed. There is no automatic test or automatic retry.

Bluetooth discovery, connection and transmission operate only while the app is active. Discovery stops after 15 seconds; connection setup times out after 15 seconds. Backgrounding, locking the phone, stopping or leaving the feature disconnects and cancels outstanding tasks. A previously requested search may resume when the same view becomes active again, including after the first permission dialog; interrupted print jobs never resume automatically. No Bluetooth background mode is enabled. Data already received by the printer may still print after disconnection, so interrupted/unconfirmed jobs require inspecting the tape before retrying.

## Inventory labels

Open **Show → Inventory → ••• → Print Price Tags**. Search and select available inventory rows, then Review. Each selected row defaults to one label even if its stock quantity is larger. Open a tag to edit its asking price, choose 1–20 labels, inspect the monochrome preview and tap **Print One Label** for each copy. Printer setup is reachable within the flow.

The tag contains a shortened card name/number on the first line, with a larger asking price and condition abbreviation on the second. It uses a fixed 32-row monochrome raster for this 12 mm printer, with edge margins and a bounded feed length of 30–600 columns. Longer metadata truncates; the complete supported price is retained. No barcode/QR accuracy is claimed on this small raster.

The initial asking price is the saved per-card market value rounded to the nearest dollar, matching the existing sale suggestion. Manually entered cents are supported. Missing market prices require an explicit price; a known zero remains zero. Label edits and copy counts are temporary local drafts and do not change market quotes, inventory quantities, costs, list data, transaction receipts or buying funds. Printing is not a sale. Closing the queue discards its drafts/progress; it does not persist a printer/queue or silently reconnect on app launch.

The queue intentionally sends one label per explicit tap. It never prints the entire inventory or automatically sends the next copy/card. Only a fresh status-code-zero reply after the current job has been sent increments the printer-confirmed count. Timeout, disconnection, malformed replies and all unverified nonzero codes leave the outcome unknown and do not advance that count. Review the tape before allowing another attempt; paper output cannot be rolled back by Undo.

## Implementation and attribution

Native iOS **CoreBluetooth** handles device discovery, service/characteristic negotiation, notification subscription and write-without-response backpressure. `NSBluetoothAlwaysUsageDescription` describes the opt-in purpose. This is not AirPrint or a Web Bluetooth/PWA connection, and it does not require the desktop DYMO Connect service, account cookies, an API key, a server, internet access or new signing entitlements.

The wire format is independently implemented in Swift from the MIT-licensed protocol documentation in [thermal-label/letratag](https://github.com/thermal-label/letratag), pinned to commit `a8fb41e19ce3a8cb1e51d6aaeb1acc8060d5842b`. The full copyright/MIT notice is bundled in `LetraTagProtocol.thirdPartyNotice` and visible under **Label printer → Printer protocol credits**. No vendor app/firmware, downloaded code or JavaScript package is executed or distributed by this integration.

The encoder sends the nine-byte checksum/length header separately, then bounded indexed body writes with the final magic bytes. Every write respects the actual CoreBluetooth maximum payload, including index and trailer overhead; body slices never exceed 500 bytes, index 27 is skipped, and index overflow/blank/malformed/oversized bitmaps are rejected before sending. Writes honor CoreBluetooth readiness and are paced without blocking the UI. Only the documented current reply channel can confirm a pending job. A 30-second timeout disconnects an unconfirmed job instead of claiming it printed or replaying it.

The reference protocol includes inferred/partially verified details, especially physical row packing on different tape substrates and nonzero status meanings. The app therefore treats only observed code 0 as confirmed. Firmware differences, orientation/feed, font legibility and physical print completion all require the device acceptance below.

Diagnostics record fixed phases/reasons, status byte codes, packet counts, negotiated write limit (`total` on a sending event) and elapsed time. They never log printer names/identifiers, bitmap bytes, card names, asking prices or credentials. Bluetooth discovery does not inspect unrelated devices beyond filtering their advertising for the supported printer.

## Validation and phone acceptance

Finish implementation before checks. Eighteen native cases cover exact header/opcode/bitmap bytes, MTU boundaries/final trailer, index skip/overflow, strict replies, variable UUID tails, unknown/zero/default/manual prices, copy limits, monochrome preview/packing identity, margins and long Unicode metadata. One no-radio UI regression uses existing synthetic inventory to verify that opening previews requests no Bluetooth permission, label edits remain local, disconnected printing is disabled, and stock/budget stay unchanged. It uses the existing transaction UI job; no simulator job is added.

On an iPhone, verify first-use permission plus discovery, connection, upright test output, repeat test output, one selected price tag, edited $32.50, 2 copies from separate taps, missing/zero prices, changing cassette, printer-off/no-tape cases, failed/unrecognized reply, disconnect/lock during sending, and leaving/reopening the feature. Check the tape before retrying uncertain attempts. Confirm no scan/connection/printing continues while the app is inactive and no job automatically resumes. Compare inventory quantity, price and show balances before/after labels. Test with the DYMO app closed and check that reconnecting after a printer power cycle works.

Xcode/native/UI test execution and physical hardware acceptance must be reported separately from portable syntax/target/resource checks. Do not purchase a replacement printer based solely on this prototype; first test the one already owned.

After implementation completed, local checks passed grammar parsing of 149 Swift files; Xcode membership for 85 app / 52 native-test / 12 UI-test sources and bundled resources; all 47 pinned recognition assets; Bluetooth purpose/privacy/portrait/no-background metadata checks; and whitespace validation. Eighteen new native tests and one no-radio UI regression are registered, but no Xcode build, native/UI execution or physical printing ran in this Linux workspace. The unchanged JavaScript/Python suites were not rerun. Actual iPhone discovery, connection, permission behavior, print status and physical output remain unverified.
