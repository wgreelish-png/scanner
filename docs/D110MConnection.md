# D110-M connection and printing — build 66

Build 68 improves [connection handling and setup-timeout diagnostics](PrinterConnectionTimeout.md)
after an actual printer linked over BLE but did not finish identification.

The reported printer advertises with a `D110_M-` prefix. `D110_M` is the internal
and Bluetooth spelling of the D110-M variant. Earlier discovery deliberately
excluded this variant because it requires a different print workflow from the
standard D110. Appearing in iPhone Bluetooth devices only after an app connects
is consistent with this app-managed Bluetooth Low Energy connection.

Discovery now accepts the D110-M name variants as well as standard D110 names.
The user still searches explicitly and selects a device. The reported model,
protocol generation and print head determine compatibility; an advertised name
alone cannot enable printing. D110-M model 2320 must report a 96-dot, 203-dpi
head. Its firmware version comes from the documented basic heartbeat response.
Unrecognized models, head dimensions and protocol generations remain rejected.

The native implementation follows the existing pinned
[niimbluelib reference](https://github.com/MultiMote/niimbluelib/tree/f451be49d8e30046dee0a8f9d14747fe38f303c2).
Its model table, task selector and packet generators distinguish these tasks:

| Printer | Workflow |
| --- | --- |
| Standard D110 | Existing D110 setup, page start and four-byte page dimensions |
| D110-M, protocol 4 | Nine-byte print start, one-way status, thirteen-byte page dimensions |
| D110-M, other recognized generations | B1-family seven-byte print start and six-byte page dimensions |

All tasks use the same 96-dot raster and preview, declare one physical label,
and wait for the printer's completed-page counter before marking it printed.
Discovery or successful connection never starts a print job. A failure after
dispatch keeps the existing uncertain-output handling; no command is retried
automatically. Pending queues and completed-copy records remain unchanged.

Connect from Settings → Label printer → Search for D110 / D110-M. Disconnect
the printer in the NIIMBOT app or another phone first, turn it on nearby, allow
Bluetooth permission and keep this app open. After selecting it, the app shows
the identified model. Backgrounding disconnects it; searching is explicit on
return. Printer diagnostics include fixed failure reasons and negotiated model
codes without advertised names, serials, device identifiers or raw packets.

Native regressions use the pinned reference's D110-M 4.23 handshake, exact task
payloads, malformed/unsupported replies, page completion, cancellation and
standard-D110 compatibility. No downloaded reference code is executed or added
as a runtime dependency. Native execution and physical iPhone/D110-M output
require separate verification; begin hardware acceptance with one test label.

Validation: Swift grammar passed for all 192 Swift files, Xcode source membership
passed, build 66 metadata passed and `git diff --check` passed. Eight new native
regression methods are authored. Native compilation and simulator execution
remain pending because this Linux workspace has no Xcode; these portable checks
do not establish physical printer compatibility.
