# Research camera and inventory sorting — build 48

## Research

Find a Card keeps its game picker and text field. A compact camera button with
“Scan” underneath sits in the panel’s upper-right corner. It opens the existing
bundled live recognition engine full-screen for the selected game. No mock
scanner is selected automatically.

The first usable result stops capture and holds up to five artwork previews.
Choosing a match closes capture before opening the existing combined Market and
Graded Research page. Scan Again discards the held matches and starts fresh.
Close or Use Text Search returns to the original query. No list, session,
inventory, cost or budget data is created or changed by the research scanner.
Backgrounding and dismissing stop capture; a held result survives a foreground
return. The existing engine, database cache, camera permission handling and
steady-border preference are reused.

## Available inventory

Available cards has a compact Sort menu beside its section title. It remembers
Name A–Z/Z–A, Market High–Low/Low–High, Quantity Most First, Newest/Oldest Added,
or Set & Card Number. Search filters first, then applies the selected order.
Market ordering uses the displayed unit market price; missing prices come last
in either direction, while a known zero stays a valid price.

Sorting only changes the displayed array. Acquisition lots, duplicate rows,
saved scan order, receipts and exports keep their existing behavior.

## Validation

All implementation is completed before checks run. Nine native research cases
cover freezing, late frames, bounded candidates, selection membership and double
taps, condition reset, retries, live defaults and background/resume behavior.
Five native inventory-sort cases cover missing/zero prices, natural text/card
number ordering, dates, quantity, deterministic duplicate ties and preservation
of the original array. Their execution requires Xcode.

Local validation passed: all 40 portable Python helper tests; Swift grammar for
179 files; source membership for 100 app, 65 native-test and 14 UI-test files;
all 47 pinned recognition assets and dependencies; build-48/portrait/foreground
metadata; shell syntax; and whitespace checks. These checks do not compile Swift
or execute the 14 new native cases. Xcode is unavailable in this Linux workspace;
native/build CI is pending after push. No simulator runner wait is required to
finish this task.

On an iPhone, open Research → Scan, allow camera access if needed, and choose the
correct preview. Verify that the research page opens and no new list is created.
Repeat with Close, Use Text Search, Scan Again, and a background/foreground
return both before and after a match. Confirm typed text is preserved. In Show
Inventory, change each sort, combine it with search, and reopen to check that
the preference remains selected. Physical-camera behavior is unverified until
these device checks are performed.
