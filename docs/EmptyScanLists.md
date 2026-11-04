# Save new scan lists with the first card — build 61

Opening Start New Scan now holds a temporary scan draft. Neither its list nor
its session is inserted into SwiftData, so closing the camera, opening manual
search, switching games, backgrounding or saving another edit cannot create an
empty saved list. A recognized candidate still requires explicit confirmation.

The first confirmed camera match or manual Add commits the list, session and
physical card together. Only then is the previously active batch completed.
Closing an empty scan leaves that earlier batch available to continue. Until
the first card saves, View List is disabled and Close Scan dismisses the camera.

First-card persistence uses separate copies of the draft models with stable
IDs. A failed save discards those staged copies, restores the earlier active
batch and keeps the original draft/selection valid for retry. Unrelated pending
edits are saved before that transaction so rollback cannot discard them. The
successful save switches the scanner and its Undo/Copy actions to the committed
models; later cards append to the same list.

The existing persisted-session APIs still support continuing saved lists.
Existing empty lists, manually created lists, saved offers and lists emptied by
Undo are preserved. No cleanup or storage migration is performed. Camera,
recognition, pricing and card-confirmation rules are unchanged.

Regression coverage includes repeated empty openings with an unrelated save,
first-card persistence, manual Add, interrupted/failed first-card saves and
retry, previous-session preservation, and Undo after the first card. Native and
UI checks require Xcode; physical iPhone checks should close/reopen several
empty scans, confirm one card, reopen its single saved list and continue it.
All implementation completes before validation. CI is not awaited after push.

Local validation passed: all 192 Swift source grammars, app/native/UI source
membership, build-61 revision metadata and whitespace. Nine new native cases and
the expanded scanner UI scenario are authored; Xcode execution and physical
iPhone acceptance remain pending. These portable checks do not establish a
native build or device pass.
