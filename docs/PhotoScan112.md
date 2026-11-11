# Build 112: Photo Scan

Photo Scan is an optional capture mode alongside Live Scan. Choose **Photo Scan**
in the scanner options, frame one card, then tap **Take Photo**. The selected
capture mode is remembered for the next scanner session.

The app freezes that camera frame and stops camera capture before recognizing
it. The existing on-device database remains loaded. Recognition runs on the
static image rather than continuously scanning new live frames. Review the
candidate, printing and condition using the existing card-review flow, then add
the card normally. The camera stays off during processing, review and after
saving; **Take Another Photo** explicitly opens framing for the next card.

If no usable match is found, retake the image or use manual search. Returning
from manual search or closing a result does not silently resume continuous
recognition. Live Scan remains available for the existing continuous workflow.
Photo Scan works in ordinary scan lists and Leftover Stock counts; it does not
change inventory, transaction or pricing rules.

## Recognition and resource behavior

- One card is requested per captured image. The still-image backend uses the
  same local detection, perspective correction, hashing and matching database.
- A photo is not processed as several supposedly independent live observations.
  Still-image acceptance and confidence are preserved; an uncertain result
  remains uncertain. Blur, glare, missing borders or a small card may need a
  retake. Photo Scan does not guarantee higher matching accuracy.
- Full-frame buffers are size capped and scoped to the current capture/review.
  The existing review may keep a small card thumbnail. This workflow does not
  save captures into the Photos library or add image data to diagnostics.
  Retaking, switching modes or leaving retires stale work and releases full-frame
  resources.
- The worker is reused where supported, with the existing main-thread fallback.
  The pinned recognition engine is unchanged. Desktop OCR and network-assisted
  reranking are not enabled for Photo Scan.
- The camera and continuous recognition are off between photos, reducing
  sustained work. A captured image still needs a processing burst, and framing
  still uses the camera. Actual heat and battery improvement require phone
  measurements.
- Apple's critical-heat camera protection remains active. Mode switches,
  backgrounding, manual search and interrupted operations cannot make an old
  photo result enter a later scan session. Repeated photos of identical artwork
  are separate recognition episodes; each confirmed shot adds only the chosen
  copy through the normal save flow.

## Phone checks

1. Select Photo Scan, capture one clear card and confirm that camera movement no
   longer changes the frozen image during recognition or review. Add the card;
   check that one copy was saved and framing stays off until Take Another Photo.
2. Capture the same card again. Confirm that the new shot can add a second copy
   without requiring a different card or an artificial removal boundary.
3. Capture an empty background or an unreadable card. Verify the no-match state,
   retake and manual-search routes. Returning must not start continuous scanning.
4. Repeat capture, retake, manual search, recent-card editing and mode switching.
   Verify the database is reused and the next capture is current, without stale
   matches or duplicate saves. Reopen scanning and confirm the mode is remembered.
5. Background during framing and during processing, then return. Verify camera
   capture stops while away and stale results do not overwrite the active shot.
6. Test Live Scan afterward as a regression. It should retain automatic matching
   and normal review behavior. Test both ordinary lists and Leftover Stock.
7. Use injected critical thermal states for software testing rather than heating
   the phone. A real critical state must prevent new camera capture while manual
   entry remains usable. Export diagnostics after an ordinary session to compare
   resource context; native CPU samples exclude WebKit worker processes.

Software validation and physical-phone results must be reported separately.
Passing mocked bridge/native-state tests does not establish optical quality,
actual camera smoothness, sustained thermal reliability or battery improvement.

## Software validation

Local validation passed: 193 app JavaScript tests, including eight Photo Scan
lifecycle cases, and 75 Python tooling tests. The final bridge-only rerun passed
all 82 bridge cases after the stale-review release guard was added. Xcode
source/resource membership, all 47 pinned runtime assets, six changed/new Swift
files' grammar, build metadata, shell syntax and whitespace checks passed.
Native policy/provider cases and the focused mode-preference/shutter UI scenario
are dispatched to GitHub's macOS runner. A queued/running native or UI check is
not a passing result. This Linux workspace cannot execute iOS camera APIs.
