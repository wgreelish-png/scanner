# Gap and Transparent paper types — build 67

Settings → Label printer and the print queue now share a Paper type selector:
Gap for ordinary die-cut labels separated by gaps, or Transparent for clear
labels. The choice is saved on this iPhone and can be changed while disconnected.
Opening the screen or choosing a type does not initialize Bluetooth or send any
command. Existing installations begin with Gap, matching previous output.

Apply Paper Type explicitly sends the chosen setting to a connected printer.
Read Printer Setting reads its configured type and selects that value locally.
It is not presented as optical detection of the installed roll. If readback is
unsupported or invalid, the chosen type is kept for manual selection. Label
dimensions remain explicit in label preparation, independent of sensing mode.

All standard-D110, D110-M B1-family and D110-M protocol-4 print jobs now use the
chosen type instead of forcing Gap. The existing pinned niimbluelib reference
documents Gap as SetLabelType 1 and Transparent as SetLabelType 5. Readback uses
PrinterInfo [3] → 0x43 with one supported type byte. Setting acknowledgement is
checked by response opcode; a Transparent echo of 5 is not mistaken for false.

The reference also names a separate positioning-calibration command, 0x8e, but
does not document D110/D110-M argument meanings or completion. It notes that
some B1 arguments feed about 15 cm of paper. No guessed feed/calibration command
is sent. RFID-derived dimensions are documented for some other printers, but
the captured D110-M reference does not establish automatic roll dimensions.

Each explicit queue start captures the paper type for the entire batch. Saved
artwork, dimensions, prices and per-copy completion receipts remain unchanged.
Paper actions and printing share one connection/request path; settings controls
are locked while a batch or paper action is active. Leaving during a paper
action or backgrounding cancels it and disconnects without automatic retry.
Paper read/apply never changes inventory, financial records or queue states.

Regression coverage includes Transparent across every print profile, unchanged
Gap defaults/raster bytes, malformed readbacks, Transparent acknowledgements,
session propagation, and offline settings persistence with an untouched queue.
All implementation finishes before checks. Physical printer operation remains
separate from portable source checks and native/simulator test execution.

Validation: Swift grammar passed for all 192 Swift files, Xcode source membership
passed, build 67 metadata passed and `git diff --check` passed. Four new native
regression methods and one offline UI method are authored. Native compilation,
simulator execution and physical D110/D110-M read/apply/printing acceptance
remain pending because this Linux workspace has no Xcode or attached printer.
