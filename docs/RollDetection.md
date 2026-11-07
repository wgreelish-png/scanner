# Roll detection — build 98

Revision: `acknowledged-roll-detection`.

Diagnostic log 18's forced refreshes were blocked before the RFID query was sent.
The older `roll_read_source` and elapsed-time entries described an attempt, not
a successful printer response. Build 98 adds explicit results so a short timer
entry cannot be mistaken for a completed roll read.

RFID reads now prefer acknowledged writes when the connected characteristic
supports them. Writes without response are used only when acknowledged writes
are unsupported. Matching RFID replies still determine the read result. Timeout
and cancellation handling fences late replies and unresolved acknowledgements
from later operations; a connection reset cancels retired refresh work.

When stock was invalidated and valid readiness returns, the app coalesces a
refresh and waits for the current read to become idle. A valid unsolicited RFID
update can also apply while connected and idle. Refreshes do not overlap active
printing or paper configuration. A recognized product uses the existing offline
catalog and shows **Detected label size** with its measurements.

Saved label preferences and inventory remain intact. Existing paper/media
compatibility rules still apply, and prepared queue entries retain their saved
geometry and artwork.

## Diagnostic results

| Event | Fields and meaning |
| --- | --- |
| `label.roll_read` | `roll_read_result`: `response`, `no_roll` or `failed`; `roll_read_error` uses a fixed failure classification. Existing `write_mode`, source and duration fields describe the attempted query. |
| `label.roll_detection` | `roll_detection_result`: `matched`, `unknown_product`, `media_mismatch`, `unavailable` or `invalidated`. |
| Matched detection metadata | Nonunique numeric `roll_product_code`, physical `label_width_mm`/`label_height_mm`, and `label_feed_dots`/`label_head_dots` when available. Leading zeros in product codes are preserved. |

Product metadata is accepted only on the detection event. Read-result/error
fields are accepted only on the read event. Codes contain 1–32 ASCII digits;
dimensions are positive ASCII decimals up to 100 mm with at most six fractional
digits; feed length is 1–800 dots and the supported head is 96 dots. Raw packets,
tag UIDs, roll serials, Bluetooth names and card contents are excluded. Diagnostics
remain user-controlled and local.

## Phone check

1. Keep the app active, connect the printer and load a recognized roll. Use the
   refresh arrow in Price Tags or Printer Settings. Check **Detected label size**
   matches the loaded paper, without changing another control to update it.
2. Change the roll while idle and let the printer return to ready. Check the
   detected size refreshes. Printing and paper-setting operations must keep their
   current exclusive access rather than issuing a competing roll query.
3. Export the diagnostic file after a refresh and any roll change. Check the
   explicit read result and subsequent detection classification, rather than
   treating a `forced` source or short elapsed time as proof of a response.

Native coverage includes the read coordinator, protocol/catalog matching and
diagnostic privacy/bounds checks. Both focused `printer_transport` and
`label_preview` native scopes include these checks. Automated validation runs
after implementation; physical roll-change behavior still requires the printer.

## Build 99: first-use API fallback for the 30 × 12 mm roll

Revision: `api-roll-catalog-fallback`.

The build-98 diagnostic log 4 recorded real RFID responses in 108–145 ms, followed
by `unknown_product` for `03032380`. The acknowledged read transport was working;
the product was absent from the bundled catalog.

Official metadata identifies product `80050655`, **T12*30-195WHITE**, for SKU
`03032380`. Its physical dimensions are **30 × 12 mm**, rotation is **90°**, and
media is **Gap**. The 12 × 30 mm product wording describes the same stock. The
existing geometry uses a **240 × 96-dot** raster and the supplied printable
region rounds inward to **x 9, y 5, width 222, height 86 dots**. The design is
generated from these measurements using the existing shared artwork.

The metadata was verified through the official public `POST`
[template endpoint](https://print.niimbot.com/api/template/getCloudTemplateByOneCode),
with JSON `{"oneCode":"03032380"}`; see the
[NIIMBOT cloud API reference](https://printers.niim.blue/other/niimbot-cloud/).
The bundled catalog stays at **130 products / 150 input regions / 13,085 bytes**.
It does not contain `03032380`, so first use of this uncached SKU exercises the
runtime API fallback. The full source API response is not bundled.

For an unknown SKU, the app first checks bundled metadata and its validated
persisted product cache. If neither has a match, it can request metadata from the
same public template endpoint. The request contains only the nonunique product
code, never the RFID tag UID or roll serial. Validated product metadata is saved
for later offline reuse. An unavailable or unusable response keeps the manual
paper workflow instead of guessing dimensions from a product name.

The lookup uses a 5-second request timeout and 10-second resource timeout, with
a streamed response limit of 256 KiB. Online metadata must report success and
match the requested barcode. Required flags/profile, 1–16 explicit text input
regions and physical head geometry are validated before use. If margins are
supplied, all four values must be zero. The usable region must fit the existing
renderer with at least 24 × 16 printer dots.
The versioned geometry-only cache holds at most 256 products and 512 KiB, uses
atomic writes, and ignores corrupt saved data. Existing bundled products retain
their established validation and offline behavior.

Metadata lookup uses the existing roll-reading state; new preparation stays
disabled until it settles, while existing queue review remains available.
A result may populate the reusable cache after its original
connection changes, but connection and roll-revision checks prevent that result
from publishing an old roll's detected size. Prepared queues keep their original
paper snapshot and raster.

`label.roll_lookup` records only `source=api`, `phase=matched`, `not_found` or
`failed`, and elapsed time; failures use the fixed `lookup_failed` reason. It
never stores the raw response body. Check the subsequent roll-detection event
for the size applied to the current connection.

After installing build 99, keep internet access on for the first connection with
this uncached roll and use Refresh roll. Check **Detected label size** reports
30 × 12 mm and the export records an API lookup followed by `matched` detection
for `03032380`, including its leading zero. Once cached, close and reopen the app
with internet access off while keeping Bluetooth enabled, reconnect and refresh.
The same size should resolve from the persisted metadata without another API
lookup; an actual Bluetooth roll read still identifies the loaded product.

Prepare fresh pending labels to use the resolved geometry: previously queued
labels retain their saved paper snapshot and raster. Saved preferences,
inventory and printer-transfer tuning remain intact.
