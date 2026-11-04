# Copy diagnostics as text — build 57

Settings → Diagnostics now has Copy Diagnostic Log beside Export Diagnostic Log.
Copy assembles the filtered environment header and recent JSONL events and
writes that string directly to the system clipboard on the main actor. The
screen confirms when the assignment has finished. A report-read or encoding
failure shows an error before changing the clipboard.

Previously, Export opened the shared file-URL activity sheet. Its system Copy
action did not reliably supply pasteable text. File export and the generic
ShareSheet remain available and unchanged for diagnostic/CSV attachments.

Text and file export share report assembly and the existing privacy filters.
Recording can be disabled and existing logs still copied. There is no new raw
logging, clipboard read, upload or scanner startup change. The pending database,
rear-camera status and preview-resizing investigation still awaits the user's
log.

All implementation completes before validation. Native cases cover the text
header, sanitized fields, recording-disabled and rotated logs, and invalid UTF-8.
After installing build 57, tap Copy Diagnostic Log, check the success message,
and paste into a text field or chat. Physical-iPhone clipboard behavior remains
unverified in this Linux workspace.

Changed Swift grammar, source/target membership, build-57 metadata and whitespace
checks passed locally. The three new native cases have not executed here;
Xcode CI and iPhone paste validation remain pending after push.
