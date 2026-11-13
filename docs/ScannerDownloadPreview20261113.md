# Scanner download size preview — November 13, 2026

Build 118 adds a metadata-only size review before a scanner's first recognition database download and explicit database refresh. A complete saved database opens without another download prompt. Settings → Scanner Database → Preview Download Size also lets the user check a game before starting a scan. Existing automatic weekly refresh preferences remain in effect.

The preview separates recognition-file transfer bytes, existing native cache records, known minimum additional storage and available iPhone storage. Published metadata shards are compressed; their decoded storage size is not published. Missing decoded metadata, filesystem allocation and temporary files are therefore excluded from the minimum and explicitly described as additional space. The preview does not invent an exact installed size or apply an arbitrary expansion multiplier. Small index/manifest requests are excluded from the recognition-file transfer estimate.

Only the public index and selected game's manifest are fetched to calculate a preview. Recognition shards, artwork, prices and research data are not downloaded by this check. It does not rewrite inventory, stored preferences, cache records or the active database marker. Existing native records reduce the missing-file estimate; cached metadata provides a clearly labeled fallback when the network is unavailable. Repairing damaged data or a database changing after the preview can change the final transfer.

Cancelling the first download returns from scanning. Cancelling an explicit refresh resumes the saved scanner. A failed metadata check offers retry or an explicit continuation without an estimate. Navigation, backgrounding and cancellation retire pending metadata work so late callbacks cannot start a download in a later session.

The public scanner-game discovery URL also uses the working static `/packs/index.json` endpoint; the previous `/newscanplus/packs/index.json` static URL returned 404.

Native tests cover metadata parsing, cache deductions, compressed metadata, size bounds, legacy packs, cancellation and the approval gate. Deterministic UI fixtures exercise size labels, fixed action controls and unavailable estimates. Software validation results and the focused GitHub run are reported with the commit; physical iPhone storage allocation remains an estimate.

Portable validation passed: 37 workflow/runner tests, Xcode source registration, scanner runtime assets and `git diff --check`. A live metadata-only check confirmed the current Pokémon index/manifest schema: 215 set shards, 5,420,660 recognition-file transfer bytes before cache deductions, and a 34,389-byte decoded manifest. No recognition shards were fetched by that check. Native build and UI results require the macOS runner and are reported separately.
