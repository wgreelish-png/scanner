# Printing progress, completion and connection — build 83

An explicit Print action opens a dedicated progress screen. It shows the number
of requested copies physically confirmed by the printer and a progress bar.
When the last copy has been confirmed but the printer has not acknowledged the
end of the job, the screen shows that it is finishing. Only the fully confirmed
job, with saved completion receipts and no cancellation or error, automatically
closes progress and returns to Price Tags.

Success routing covers inventory batches and single-card labels, custom and
bulk tags, Saved Print Queue, and the queue reached through Printer Settings.
Opening a previously completed queue never triggers the return action. Stored
receipts remain available after the return; the queue is not cleared.

Pause/Stop stays explicit. Failure, uncertain output, unsaved completion,
backgrounding or manual stopping does not masquerade as success. The progress
screen offers a way back to the queue for review. Cancelling a run after its
last physical receipt but before the final job confirmation keeps those
receipts and does not automatically navigate away or retry printed copies.
Presenting the progress sheet itself does not cancel printing.

The app keeps a verified idle Bluetooth connection while active after successful
printing. Returning to Price Tags happens after the sending task has ended,
so navigation cannot accidentally cancel an unfinished PrintEnd exchange.
Optional RFID failures and unsolicited idle status errors now leave that
verified connection available and show a warning. After a positive final
PrintEnd acknowledgement, late status or roll changes also become warnings
for the next job. Required setup, configuration and active print errors still
fail the run; real Bluetooth failures, cancellation and backgrounding retain
their existing handling.
Without current device diagnostics, navigation before that final exchange,
an optional status reply, or a real link failure cannot be distinguished as
the cause of a reported disconnect.

## Different labels and feed pauses

The D110-M path already sends one declared multi-label job, buffers two native
copy groups and uses the printer's copy count for consecutive identical images.
It also compresses repeated image rows. A different price or design still needs
its own image upload. Acknowledged Bluetooth transfers and the documented packet
spacing can take longer than the printer's physical feed, so a mixed batch can
pause waiting for the next image. This is not a guarantee of uninterrupted feed.

After supplying or refilling its bounded window, the sender now checks the
physical counter immediately. It waits 300 ms only when the printer reports no
new completion. This removes an avoidable wait when the first image finished
while the next image was being uploaded. Packet acknowledgements, the native
copy count, row compression, the two-group/eight-copy bounds, copy order,
density/quality and physical completion checks remain in place.

One job-level diagnostic summary records bounded numeric transfer statistics
and allowlisted task information. It contains no label images, prices, card
names, inventory contents, RFID identifiers or device serials. Handed-off bytes
measure app-to-Bluetooth dispatch, not guaranteed radio delivery; transfer time
includes acknowledgement, physical-feed and status waits. These counters help
distinguish upload time from printer pacing in the next phone diagnostic.

## Phone checks

1. Prepare several different prices and tap Print. Confirm the progress screen
   appears, shows confirmed copies and keeps Pause accessible. After the final
   job confirmation, it should return to Price Tags with Bluetooth connected.
2. Repeat with identical copies, custom labels, 2-for-$1 tags, write-in tags and
   a single card opened from inventory. Confirm the exact requested quantity
   and the same Price Tags destination after success.
3. Open Saved Print Queue directly and through Printer Settings, including from
   the Settings tab. Print a pending batch and check the success destination.
   Open an already completed queue; it should stay open without printing.
4. Pause during the last label or while Finishing is visible. The screen must
   retain a review path rather than report automatic success. Proven completed
   copies stay completed; retry only copies that still need a print.
5. Test paper/lid/radio interruptions and backgrounding. Incomplete or uncertain
   jobs must stay reviewable. A real disconnect must remain visible and must
   never cause an automatic replay on reconnect.
6. Compare the gaps in a mixed-price batch with consecutive identical copies.
   Confirm copy order, quality and quantity. If gaps or disconnects persist,
   capture a fresh diagnostic after the job so its aggregate transfer counters
   can be checked.

Native execution and real feed/connection timing require Xcode, the phone and
printer. Source review and portable checks cannot establish physical timing.

## Validation receipt

- 322 portable tests passed: 172 JavaScript, 59 research-server, 49 Postman and
  42 Python tests.
- Swift grammar parsed all 210 source/test files. Xcode source membership,
  47 pinned scanner assets, both OpenCV runtime smoke checks, build/revision
  metadata and whitespace checks passed.
- Added 20 native regressions and four UI regressions for completion proof,
  progress routing, interruption, polling, status-error boundaries and diagnostic
  privacy. Independent source review found no remaining blockers.
- Native/UI execution and the unsigned iOS build were not available in the
  Linux workspace; those and the phone checks above remain unverified here.
