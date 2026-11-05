# Offline RFID paper detection and generated layouts — build 79

The app bundles the reviewed 13,085-byte product catalog, containing 130 product
codes and 150 vendor input regions. An actual printer RFID reply supplies the
non-unique product code. A matching catalog entry sets the dimensions and
Gap/Transparent media for newly prepared labels without an internet request.
Missing, unknown or unsupported roll metadata keeps the manual paper workflow.
Roll identity is usable even when its remaining-label counters are unavailable.

The renderer generates each design from the existing shared vector PokéDen
wordmark, scalable text, border and divider. There is no image per product.
Price Left/Price Right works on the detected paper and remains remembered.
Preview comes from the exact one-bit printer data, displayed upright for the
captured paper orientation. Inventory, financial data and asking prices are
independent of the paper selection and are not changed by detection.

The catalog preserves original axes, rotation, paper type, cable/multi-region
flags and full-precision input rectangles. Derived layouts rotate into printer
orientation, intersect the supplied region with the physical label and the
centered 12 mm / 96-dot print head, then round usable edges inward. The design
fits within one largest usable region per physical label; multiple regions do
not silently multiply the requested copy count. The existing four manual
presets retain their previous rendering and encoded string values.

The source entries with slightly out-of-bounds regions remain unchanged in the
catalog; only derived drawing bounds are clipped. Two source products have no
input regions. Their generated design uses the bounded physical print area and
normal layout margins, without assuming that absent data describes factory
artwork. Cable and other specialty stock use only the supplied dimensions;
missing cable-tail dimensions are not inferred from a product name. Physical
feed and placement on specialty stock still need printer acceptance tests.
The flagged multi-region product `06222115` supplies only one region; that
region is preserved as supplied, without inventing a lane split or lane count.

The detected roll is authoritative while verified on the current connection.
The saved manual size, manual media choice and saved price side remain intact.
Disconnecting or receiving unknown/missing roll metadata restores the remembered
manual choice. Detection never starts printing. There is no polling loop or
cloud lookup, and no unique RFID tag ID or roll serial is retained in labels,
the catalog, diagnostics or preferences.

A prepared queue retains its own paper geometry and printer bits. Reconnecting,
changing the default or updating the catalog cannot silently redraw it. Before
any sending marker or print command, the queue drains an existing RFID read and
checks the saved paper against the detected roll. A changed layout or media
requires clearing and preparing that queue for the loaded roll. Legacy/manual
queues also need preparation again after a known roll is detected, because they
do not contain that roll's printable-region snapshot. With unrecognized RFID,
manual queues keep their existing explicit printing behavior. Automatic queues
require a matching verified roll rather than guessing. Pause during the initial
stock check leaves every queued label pending and sends no label commands.

## Phone checks

1. Load the known `120425109` roll and connect. Price Tags and Printer Settings
   should show 40 × 12 mm / Gap detected from the roll. Open inventory, custom
   and bulk labels; each should use the detected paper and show its generated
   preview without selecting a size manually.
2. Set Price Left, close and reopen the label screens, then relaunch/reconnect.
   The price side remains left and the roll is read again. A single shared
   vector logo is used for all papers.
3. Print a single label, identical copies, and a batch of different prices.
   Check exact quantity, readable full prices, smooth logo/borders, region
   placement and unchanged continuous-batch behavior.
4. Where available, test 10 mm stock, a 22/25 mm short label, a long 75 mm label,
   transparent stock, a portrait-format product and the 270-degree product.
   Compare the upright preview and left/right price preference with the print.
5. Change rolls after preparing a queue. Its preview and saved bytes must stay
   unchanged. Printing should explain any mismatch before sending; clearing
   and preparing again should generate the newly detected layout.
6. Tap Print while the initial RFID read is still pending, including with a
   transparent roll. It must use the resolved paper/media or stop before sending
   any label. Pause at that point must preserve the pending queue.
7. Disconnect or use an unrecognized/no-chip roll. Your saved manual paper and
   media choices return. Reconnecting a known roll should automatically use
   that roll again without changing inventory or saved price preferences.

Native execution and physical feed/placement require Xcode, an iPhone and the
printer. A correct catalog transformation or syntax check alone does not prove
firmware behavior or roll alignment.

Local validation passed: 322 portable tests (172 JavaScript, 59 server, 49
Postman and 42 Python), grammar for all 205 Swift files, application/test source
membership and bundled catalog resources, 47 pinned scanner assets, both OpenCV
smoke tests, build metadata, exact-decimal catalog recovery and whitespace
checks. Thirty-six native regression cases were added across catalog geometry,
generated rendering, paper selection, queue preflight and RFID lifecycle; they
require native Xcode execution and are not counted among the portable tests.

CI also exposed an existing missing `try` in the game-pricing test fixture,
mixed real/mock clocks in an HTTP-date test, and cold simulator startup beyond
the previous 30-second limit. The fixture now propagates its error, the date
test uses one deterministic clock, and simulator discovery/creation/boot use
bounded 90/120/90-second limits without resets or retries. The affected suites
were rerun locally; native compilation and execution remain separate CI checks.
