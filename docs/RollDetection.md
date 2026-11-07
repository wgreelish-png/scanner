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
