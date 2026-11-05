# Printer setup timeout — build 68

The supplied build-66 diagnostic records two D110-M connection attempts, each
ending in `responseTimeout` five seconds after Connect. No identified event or
print dispatch appears. This matches the per-request timeout after the BLE
channel subscribes, rather than the fifteen-second overall setup deadline. The
green light and sound therefore do not establish completed application setup.
The older diagnostic does not identify which request went unanswered.

Connection now matches characteristic callbacks by the selected service/channel
UUIDs on the current peripheral instead of requiring the discovery wrapper's
object identity. The selected UART channel uses acknowledged writes when it
advertises that capability; otherwise it retains write-without-response and
backpressure handling. Incoming replies remain buffered until any outstanding
write acknowledgement completes. Framing, the Connect wake byte, service
allowlist and strict model/head/protocol checks remain intact.

The identification sequence follows the captured D110-M NIIMBOT-app trace:
Connect, model, protocol status where required, then print-head information.
Standard D110's older sequence is unchanged. Typed step callbacks report each
request before it starts. Cancellation and timeout stop setup without retries
or print commands. A setup timeout now describes printer setup rather than
claiming a label's completion was unconfirmed.

Bounded diagnostics distinguish BLE link, service/channel discovery,
notification subscription, each request, blocked writes, completed writes and
matching replies. A failed request records command/expected-response codes,
last parsed response code, bytes handed to CoreBluetooth, notification counts
and parsed-packet counts before connection teardown clears its state. These
fields contain numeric counts/opcodes and a fixed write-mode classification;
advertised names, serials, characteristic UUIDs and raw payloads are excluded.

These changes improve transport handling and diagnosis. The uploaded file alone
does not prove the precise hardware cause, and this environment has no attached
iPhone or printer. Physical acceptance requires reconnecting the D110-M on the
new build, checking the identified model, then explicitly testing one label.
If setup still fails, the new diagnostic should identify the unanswered command
and whether any notification or valid response reached the app.

Native regressions cover captured request/step order, timeout at each setup
step, cancellation, strict identity validation, and persisted diagnostic-field
bounds/privacy. Implementation finishes before checks. Native and physical
execution remain separate from portable source validation.

Validation: Swift grammar passed for all 192 Swift files, Xcode source membership
passed, build 68 metadata passed and `git diff --check` passed. Four new native
regression methods are authored. Native compilation, simulator execution and
physical D110-M reconnection remain pending because this Linux workspace has
no Xcode or attached printer.
