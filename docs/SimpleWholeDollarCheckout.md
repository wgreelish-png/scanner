# Simple whole-dollar checkout — build 65

Actual sale and purchase cash is entered inline on the transaction screen using
a number pad. Each tap starts a blank replacement entry. Done commits it;
Cancel keeps the previous amount. Whole-dollar cash displays without `.00`.
Cash starts unentered, so opening checkout or selecting stock cannot record an
assumed payment. A committed amount survives changes to the selected cards.

New card sales have no sale-fee control and record a zero fee. Rounded market
totals and the transaction preview are removed from checkout. The fixed record
area keeps the actual cash and signed change to buying funds visible. Detailed
accounting, including historical fees and fractional cash, remains in history.

Review & Offer opens confirmation directly using its existing list and offer
mode. The contextual checkout omits the transaction-type selector, incoming
list picker, list-edit/reload actions and repeated preview. Cash controls appear
before the scrolling card list. Selected cards show acquisition cost and market
reference. Purchase and trade receipts still use an immutable list snapshot;
recording validates the source and updates stock and funds together.

Use calculated cash offer is an explicit button with a dollar amount. It rounds
the complete offer to the nearest dollar, with half-dollars rounding up; it
does not change stored card prices, offer estimates or allocation weights.
Incomplete valuations have no automatic cash suggestion. Mixed trades use the
offer's proportional cash payout, while the entered actual payment determines
the final cash movement. Explicit zero cash records an even trade, and a rounded
receipt that would exceed the agreed outgoing card price is not suggested.

Generic Show transactions retain the controls needed to choose a transaction
and incoming list. Inventory confirmation still supports draft-only swipe
removal and adding existing stock. Newly acquired cards become local inventory
only when recording succeeds. Existing receipts and precise cost/profit math
are preserved.

Coverage includes whole-dollar parsing and bounds, total-offer rounding, signed
display, unchanged fractional history, offer-context routing, blank inline cash
replacement/cancellation, long lists and purchase/sale persistence. All
implementation completes before checks; native and UI execution requires Xcode.

Validation: Swift grammar passed for all 192 Swift files, Xcode source membership
passed, build 65 metadata passed and `git diff --check` passed. Eight native
regression methods and two UI regression methods were added; existing checkout
tests were updated. Native compilation, simulator execution and iPhone
acceptance remain pending because this Linux workspace has no Xcode.
