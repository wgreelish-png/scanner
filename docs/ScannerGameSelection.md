# Scanner game selection — build 58

Settings → Scanner Database now has a Game picker instead of a fixed text label.
The chosen game is the default for future scans; existing lists/sessions retain
their identity and game. Status, last refresh and manual database updates use
that game's own cache key. Saved cards and old game names remain valid even if
a later published game list changes.

The supplied Open API response seeds 64 known product categories and aliases.
It includes accessories, so it is not used as evidence that every category has
a recognition database. Card Sleeves, Deck Boxes, Playmats, Protective Pages,
Storage Albums and Bulk Lots are excluded from scanner choices.

Before discovery, the app offers the bundled engine's Pokémon, Magic,
Yu-Gi-Oh!, One Piece, Disney Lorcana, Sorcery, Gundam and Riftbound options.
Refresh Available Games reads New Scan Plus's published pack index and offers
registered card games with valid v1/v2 pack entries. Successful availability is
cached seven days; manual refresh bypasses that interval. Failures retain saved
choices. Discovery is bounded, uses no credentials/cookies and is cancelled
when the screen leaves the foreground. It fetches only the small game index;
first recognition downloads still happen on scanning, with weekly maintenance
and per-game native caching retained.

One registry now supplies scanner, cached-search and pricing/set-category
mappings. Pokémon Japan defaults newly recognized/search-result cards to
Japanese. Generic game-key maintenance replaces the three-game allowlists;
native publication still requires a registered card game and all existing
path, completeness, compare-and-set and pruning checks. Recognition algorithms,
camera startup and the pending preview/startup investigation are unchanged.
Mock remains explicitly selected testing; other games no longer get Pokémon
sample names in that mode.

SKU, product and Beta category validation uses registered category IDs while
preserving exact product/category checks, daily pricing caches, ETags and access
requirements. A published recognition pack proves data availability, not exact
pricing/research coverage or verified iPhone scanning for every game.

## Validation

Implementation finishes before tests. Eighteen native cases cover registry
aliases/categories, accessory exclusion, game-index validation and caching,
cancelled/stale discovery responses, per-game SKU and metadata requests, native
catalog isolation and Beta cadence/ETags. JavaScript cases cover additional game
keys, isolated cached markers, offline reopening and staged maintenance.

This cloud environment received HTTP 403 when reading the live index. Its actual
availability list could not be verified here; the native loader and validation
are tested with controlled fixtures. Xcode/native tests and physical-iPhone
scanning must be reported separately from local checks. On the phone, open the
picker, refresh games, choose a second TCG, download/scan its first card, reopen
offline, switch back to Pokémon and verify each game's cache and pricing stay
separate. Confirm no existing session is silently switched or finished.

Local validation passed: grammar for 192 Swift files; target membership for
107 app / 71 native-test / 14 UI-test sources; all 47 pinned resources and
dependency closure; build-58/portrait/foreground metadata; exact identity matches
for all 64 supplied categories; whitespace; and the updated cache/maintenance
JavaScript suites. Seven standard JavaScript test files passed. The runtime
file failed under this workspace's Node 24 captured-child-output plumbing
(child console output was empty); both OpenCV scripts passed directly, and all
three unchanged runtime cases passed with a temporary file-backed stdio wrapper.
No runner/test workaround was committed. The normal full runner needs CI
confirmation. Eighteen new native cases are authored but have not run here;
Xcode and iPhone checks remain pending after push without waiting for runners.
