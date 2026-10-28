# Build 12: steady borders, card handoff and inventory export

**Steady Card Border** is enabled by default in Scanner options and can be turned off there. It briefly retries the card's last accepted border after small movements, instead of immediately preferring an enclosing top-loader outline. The window ends 650 milliseconds after a real accepted scan; repainting or seeing the holder does not renew it.

Only geometry is retained. Motion clears previous frame hashes and fused votes. The engine refits the border using the original support, contrast and drift checks, then requires a fresh accepted match for the same reference on the current frame. Failure runs the original full search in that same frame. Expiry, incompatible motion or dimensions, removal, explicit Scan Next, backend restart and pack replacement release the old geometry. A retained outline is white/searching during movement; it becomes green only after a fresh accepted scan. No confidence threshold or condition-price rule is relaxed.

The setting changes within the existing camera stream. Scalar logs include `web.border_retry` with `border_retry` and `border_retained`, sampled at most once per second, plus the existing sampled scan statistics. Logs do not contain images or card identities. These events show a retry happened; they do not prove the user's physical card was identified correctly.

## Card confirmation and next-card fixes

After saving, the scanner rearms complete candidate delivery without reopening the camera. A different accepted card can settle and open confirmation without requiring an empty frame. Repeated frames of the just-saved card, partial updates and weak guesses stay blocked. Actual no-card observations spanning at least 300 milliseconds or explicit Scan Next allow another identical physical copy. A transient hide event alone does not release this wait. Native handling also accepts a settled different card if its preceding hide event was coalesced by the result stream.

An edited printing/SKU changes a draft's display identifier. Confirmation now validates its stable product against the frozen candidates, preserving the trusted selected draft. Save failures still retain the exact choices for retry. A successful save during scanner startup queues its release until that page reports ready; stop, a new document or explicit Scan Next prevents stale release work.

Condition stays pinned at the top of confirmation while scrolling. Every match's Type / printing dropdown is above its artwork, outside the Add button. Changing either menu never saves; tapping the match confirms it. Each new physical card starts at Near Mint and uses exact online condition/printing quotes, including known zero and unavailable values.

## Inventory export

Open the saved list or View List → Review & Offer. **Export CSV to Files** and **Share CSV** are at the top, above the offers. Export includes the entire list in scan order, regardless of its filter or sort, preserving separate duplicate rows and legacy quantities. See [Inventory export](InventoryExport.md).

Install the new build over the existing app using the same signing configuration. Do not delete the app to upgrade. Settings → About this app must show **Build 12**, release `steady-border-inventory-export`; merging or pulling a PR does not update the app already installed on the phone.

## Validation and phone acceptance

At `9494491`, [macOS CI](https://github.com/wgreelish-png/scanner/actions/runs/40519206789) passed 151 native tests, both simulator UI tests, the Personal-scheme Release iPhone compile, 99 JavaScript tests, 20 Python helper tests, source/resource membership and all 47 pinned assets. The confirmation UI test explicitly selects Mock through the regular menu, edits condition and printing before saving, then relaunches and opens the persisted one-card inventory to verify export/share controls. This does not exercise real camera recognition or the iOS Files/share destinations.

Local JavaScript coverage includes engine expiry/identity/current-frame gates, main/worker transport, white outline behavior, camera-preserving preference changes, same-card suppression, different-card handoff and bounded diagnostics. Real scalar and SIMD OpenCV checks revalidate a three-pixel synthetic movement using one fresh frame, reject removal and preserve the original default decision fingerprint and source pixels. Synthetic frames do not establish real top-loader or glare accuracy.

On the phone:

1. Compare Steady Card Border on/off with ordinary bright cards and the dark Darkrai/top-loader card. Introduce a small movement after green appears. Look for brief white retention followed by a newly accepted match, rather than judging success from the outline alone.
2. Remove, rotate, substantially move and replace cards. Check that an old match does not stick or save automatically. Scan A, B, A and two identical physical copies; verify separate rows and continued scanning.
3. Pick condition and printing directly from confirmation, save and inspect the stored row. Verify the next card resets to Near Mint, and a failed save can be retried without losing those choices.
4. Export an inventory list to Files and share another copy. Open it in Numbers/Excel and compare row order, quantities, printing, condition and market values, including unpriced rows. Check that exporting does not open the camera.
5. Background/return while reviewing and while pricing is pending, then confirm once. Check that the scanner advances without another camera authorization request and retains the same saved list and offers.

Physical iPhone recognition, actual glare/top-loader improvement, real camera transitions and system file/share presentation remain device acceptance checks.
