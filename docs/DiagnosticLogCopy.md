# Copy the diagnostic file — build 60

Settings → Diagnostics → Copy Diagnostic Log now puts the exported
`CardShowScanner-diagnostics.jsonl` file on the clipboard using a file-backed
`NSItemProvider` and its filename. It no longer assigns the report contents to
the clipboard's string property. The confirmation says “Diagnostic file copied.
Paste it as an attachment.”

Copy prepares an atomic report and the provider before changing the clipboard.
It uses a separate temporary export from the share sheet, so dismissing sharing
or leaving Settings does not remove the copied file. iOS manages the temporary
file's eventual lifetime. The clipboard item stays on this device. Export
Diagnostic Log still opens the existing file share sheet.

Copy and Export share report assembly and the existing privacy filters. Copy
records `diagnostics.copy`; sharing records `diagnostics.export`. Recording can
be disabled and existing logs still copied. There is no clipboard read, upload,
new raw logging or scanner change.

Native cases cover the exported file header, sanitized fields, disabled
recording, rotated log order, and loading the provider's attachment bytes.
Physical iPhone verification remains pending: tap Copy Diagnostic Log and paste
into a destination that accepts file attachments, confirming the `.jsonl`
filename and contents. Export remains available for destinations that do not
accept files from the clipboard. All implementation completes before checks;
Linux checks cannot verify iOS clipboard delivery.

Local checks passed for all 192 Swift source grammars, source/target membership,
build-60 metadata and whitespace. The three native file-copy cases have been
updated but cannot run without Xcode. CI and physical iPhone pasting remain
pending after push; simulator jobs are not awaited.
