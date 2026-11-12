# Optional on-device text fallback (build 114)

Enable **Scanner → … → Text Recognition Fallback**. The option is remembered
under `scannerTextRecognitionEnabled` and is off by default. Turning it off
restores the existing scanning path without OCR.

- **Photo Scan:** the existing visual image matcher runs first. Only its
  `noMatch` outcome triggers one text attempt on the same frozen photograph.
  A successful visual match does not run OCR. Take Another Photo resets the
  one-attempt boundary.
- **Live Scan:** tap **Read Card Text** when the card will not match. This takes
  one snapshot, pauses visual recognition while reading it, and keeps the camera
  preview available. It does not add a continuous OCR loop. No text match resumes
  normal live recognition; a match remains held for review.
- Text suggestions open the existing **Choose the Card** screen. Its banner
  identifies text search as the source. Review the name, collector number,
  printing and condition, then tap the correct card to add it. Text results are
  not accepted visual matches and cannot trigger an automatic addition.
- Manual search remains available if the title or number cannot be read or the
  saved catalog does not contain the card. Existing inventory, pricing and other
  preferences are unaffected.

## Implementation boundaries

The app-owned bridge copies one upright JPEG at a maximum 2048-pixel long edge.
Only the authenticated native RPC receives those temporary bytes. Vision accepts
at most 2,000,000 bytes and checks JPEG type/dimensions before processing. The
Vision request runs on a serial utility queue with background processing
preferred; cancellation forwards to `VNRequest.cancel()`.

Initial OCR targets English text. Layout parsing favors titles in the upper
half and collector codes below, in the same horizontal region. It recognizes
fractions such as `055/086` and `TG01/TG30`, plus Yu-Gi-Oh! set codes. It rejects
bare damage/HP numbers, price stickers and generic card-type headings. Search
uses title plus collector filters across the saved catalog before taking up to
five results; an unreadable/mistaken collector can fall back to title suggestions.
This is a candidate search, not proof of identity. Frame one upright card filling
most of the preview; small, sideways or heavily obscured text may still need
manual search.

The pinned visual matcher, thresholds, pack format and base image encoding are
unchanged. No remote OCR service, Photos permission or saved capture is added.
Images and OCR text are not written to diagnostics. Diagnostic events are
`scanner.text_option`, `scanner.text_started` and `scanner.text_finished`, using
only option/source, bounded outcome, observation/candidate counts and monotonic
elapsed milliseconds. Existing activity-trail rules remain in place.

Every native job has a UUID, document nonce, foreground/manual/thermal guards and
a 20-second deadline. Manual entry, backgrounding, critical heat, leaving the
scanner and disabling the option cancel pending work. Stale responses cannot
open review. An uncertain completion retires the camera/page and exposes Retry
Scanner. A new photograph or job cannot inherit an old result.

## Device test

1. Leave the option off. Scan a normal card in Live and Photo modes; confirm the
   existing visual result/add behavior.
2. Enable the option, switch to Photo Scan and photograph the sleeved
   **Krookodile ex 055/086** that previously failed. If visual recognition has no
   match, check the Reading Card Text indicator and resulting Choose the Card
   suggestions. Confirm title/number, choose printing/condition, and add once.
3. In Live Scan, tap Read Card Text for that card. Check its suggestions and
   explicit add, then try another card without leaving the scanner.
4. Try a price sticker, unreadable collector and a card missing from the catalog.
   Check that no inventory entry appears without a confirmation tap and manual
   search remains usable.
5. Open manual search, turn the option off, pause/leave, or background during text
   reading. Confirm no delayed result appears over another screen. Retake a Photo
   Scan and check that the new image gets its own single attempt.
6. Reopen the app and confirm the option is remembered. Export diagnostics if a
   case fails; supply a separate card photo if needed, because the log intentionally
   contains no image or recognized name/number.

Portable tests cover the bridge snapshot bounds, one-attempt rule, pause/release,
nonce/owner/cancellation fences and unchanged base photo/live tests. Focused
native CI (`job_scope=text_assist`, `test_scope=all`) covers parser/matcher,
invalid input, cancellation, policy, preference, explicit confirmation, catalog
filtering, photo state, manual lifecycle and diagnostic schema. Physical OCR
accuracy, latency and energy use require iPhone validation; Linux checks cannot
establish those results.

Local validation: 214 JavaScript tests and 79 Python tooling tests passed;
changed Swift files passed syntax parsing, Xcode source membership passed, and
all 47 pinned scanner assets passed integrity/dependency checks. Native Swift
build and simulator tests run separately on GitHub's macOS runner.
