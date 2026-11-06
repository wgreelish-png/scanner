# A tag for every selected inventory copy — build 81

Every selected inventory copy receives a price tag, including cards in the
saved 2-for-$1 category. A selection of Amaura, Bastiodon at 2 for $1, Battle
Cage and Big Parasol with one copy each now shows four labels and prepares four
queue entries. A batch containing only 2-for-$1 inventory cards also works.

The saved category prints as the existing 2-for-$1 artwork. It does not become
an individual $0 or $0.50 price. The count, preview, copies editor, review and
queue use the same eligibility rule. All/changed batches retain stock-copy
quantities; explicit selection can use one per entry or Match Stock Quantities.
The 100-per-entry and 250-per-batch limits still apply to every category.

Inventory deal entries preserve their inventory identity, price revision and
explicit deal category. Older queue entries, ordinary $0 prices and standalone
bulk/custom labels keep their original interpretation. A completed inventory
deal label acknowledges the matching deal revision, so Print Price Changed
does not repeatedly select it. Old or incomplete jobs cannot acknowledge a
later revision. Print All still allows an explicit replacement of an existing
tag, and Keep Existing Sticker remains an explicit choice.

Paper detection, generated layouts, price-side preference, printer completion
checks and queue recovery remain in place. Changing label eligibility does not
change inventory quantities, saved prices/categories, costs, balances, imports,
receipts or transaction history. Standalone 2-for-$1 stickers remain available
as a separate convenience.

## Phone checks

1. Select the four cards in the reported example and one copy each. Confirm
   Total Labels is four, including Bastiodon's 2-for-$1 label. Preview each and
   prepare; the saved queue should contain all four.
2. Select only a 2-for-$1 inventory card, change copies to two, preview and
   prepare. Both labels should be queued with that card's identity and deal.
3. Use Print All with multiple copies of a deal card. Check that its physical
   quantity is included in the total and printed once per requested copy.
4. Complete those labels and check Print Price Changed. The completed matching
   deal should no longer need labels. Print All should still permit a reprint.
5. Compare a known individual $0 label with a 2-for-$1 label. Their display and
   saved categories must remain distinct after reopening the queue. Check the
   remembered Price Left/Right choice and detected paper on both.

Native execution, UI interaction and physical printing require Xcode/the phone
and printer; local portable checks do not establish hardware output.

Local checks passed: 322 portable tests (172 JavaScript, 59 server, 49 Postman
and 42 Python), grammar for all 206 Swift files, source/resource membership,
both OpenCV smoke tests, pinned scanner resources, build metadata and whitespace
checks. Nine native regressions and one UI regression were added, with existing
bulk-exclusion assertions updated. These native/UI cases require Xcode execution
and are not counted as portable test results.
