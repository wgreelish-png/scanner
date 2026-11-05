# Estimated labels remaining — build 78

Price Tags, Printer Settings and the saved Print Queue show an estimated
remaining-label count when the connected printer reports usable RFID counters.
The count is reported total minus reported used. It is an estimate from the
roll's chip, not a measurement of the physical paper. No internet lookup is
needed, and product-name numbers are not treated as roll capacity.

The app reads once after connecting, after a completed print batch, and when
Refresh Roll is tapped. Finishing paper configuration also refreshes a stale
or unavailable estimate. Optional reads share the printer's command channel,
have a short deadline and do not run between individual copies. Printing and
paper settings wait only for that bounded in-flight read. There is no polling
timer. Unsupported commands, missing chips and invalid counters show an
unavailable estimate without raising a printing error.

Starting a print or changing the paper setting makes the current reading stale.
Disconnecting or an interrupted job clears it to Unknown. Changing a physical
roll while idle requires Refresh Roll unless the printer reports the change.
An old value is labeled stale until another valid reading arrives.
An ambiguous timed-out RFID request prevents further RFID reads until reconnect,
so a delayed reply cannot be mistaken for a new reading. Normal printer replies
and required print acknowledgements retain their existing validation.

Only supported discrete gap and transparent label counters are used. A valid
exhausted roll can report zero; missing or invalid data cannot. If the pending
queue exceeds a fresh estimate, the queue shows an advisory message. The
estimate never blocks printing or adds a confirmation step.

Unique RFID tag identifiers and roll serials are discarded while parsing. They
are not logged, persisted, or sent to a service. The non-unique product code
exists only in the transient reading. Existing paper choices, saved
price-left/right preferences, label artwork, queue receipts, prices and inventory
remain unchanged. Automatic size lookup and a bundled product catalog are
separate from this feature.

Protocol facts are based on the [NIIMBOT protocol documentation](https://printers.niim.blue/interfacing/proto/#rfidinfo-rfidinfo2)
and the MIT-licensed [niimbluelib RFID parser](https://github.com/MultiMote/niimbluelib/blob/4ff556b0b8de302ff510f738b963c66a943b0e01/src/packets/packet_parser.ts).
The request is 0x1A with payload 01 and its response is 0x1B. Tests use synthetic
roll identifiers rather than personal printer captures.

## Phone check

1. Connect the D110-M with a chipped roll installed. Check Estimated labels
   remaining in Price Tags, Printer Settings and the queue. Compare it with a
   fresh read from the printer; the earlier captured 84-total/9-used example
   calculates to 75, but a roll used since then should have a different count.
2. Print several identical labels and a batch with different prices. The count
   should become stale while printing and refresh once the batch finishes.
   Confirm the exact physical quantity and unchanged continuous-print behavior.
3. Change the roll while idle and tap Refresh Roll. Check that the new count
   appears. Paper dimensions and the remembered price side remain as selected.
4. Disconnect, reconnect, and interrupt a larger batch. Stale or unavailable
   estimates must never appear as fresh. Existing queue recovery still applies.
5. Try missing or unsupported RFID, and a queue larger than the available
   estimate. Printing remains available when the printer is otherwise ready;
   no approval warning is required.

Native execution and physical counter accuracy require Xcode, an iPhone and
the printer. Local portable validation does not establish Bluetooth behavior
or firmware counter accuracy.

Local validation passed: 320 portable tests (172 JavaScript, 59 server, 49
Postman and 40 Python), grammar for all 199 Swift files, Xcode source/resource
membership, 47 pinned scanner assets, both OpenCV smoke tests, build metadata,
scope and whitespace checks. Twenty-one native parser/lifecycle/presentation
cases and one UI regression were added; these require native Xcode execution
and are not counted among the portable tests.
