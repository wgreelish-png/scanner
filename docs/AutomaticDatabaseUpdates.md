# Build 15: automatic recognition database updates

Automatic Database Updates is on by default in Settings → Scanner. While the app is active on the Home screen, it waits two seconds, then checks the selected game's already saved database. Successful checks are limited to once per day per game. A failed check backs off for an hour during the current app launch. Opening the scanner, leaving Home, backgrounding, changing games or switching the setting off cancels optional maintenance. Live scanning takes priority over an update.

This is a foreground Home-screen check, not an iOS background-download service. The first database download still occurs when starting the scanner. Existing complete native V2 packs can update automatically. Legacy or incomplete caches keep the existing scanner/manual repair path. Scanner options → Check Database Updates remains available.

Only changed hash/metadata files download; unchanged files are reused. The updater uses a data-only local document with camera access denied. It imports the bundled database loader without starting camera capture or recognition. It stages and verifies durable files without changing the saved index, selected database or pruning the working pack. Native code then revalidates the proposed pack, confirms the old selection still matches and atomically publishes the new manifest while maintenance is allowed. Failed/cancelled downloads, storage failures and stale results do not mark a check successful. A cancelled publication either aborts before its write or finishes before a scanner can read the cache.

Previously saved files are kept while staging. Native cleanup protects the manifest and files referenced by every selected database, including against an older scanner document's delayed cleanup. The cache's existing size limits remain in effect; insufficient space leaves the saved database selected. Settings shows the last completed automatic check for the selected game. Local diagnostics record automatic-check start/completion/failure and scalar byte/cache counts, without card contents or credentials.

Market quotes continue to use the live website. Recognition JavaScript, runtime dependencies and the native interface remain bundled and versioned with the app. New Scan Plus recognition-code or mobile-UI changes do not silently replace them. Those changes still require compatibility review, regression tests and an app update.

## iPhone acceptance

Install build 15 over the existing app using the same signing configuration. Settings → About this app should show build 15 and release `automatic-database-updates`.

1. With an existing downloaded game selected, leave Home open long enough for a check to finish. Confirm Settings shows its completed time and the diagnostic reports the byte/cache counts. Repeat during the same day; it should not check again automatically.
2. Start scanning while a check is pending or downloading. The camera must open using a complete saved database, without an update dialog or waiting for the network. Confirm a card, edit its printing/condition and scan the next card normally.
3. Disconnect internet during an update, return to Home, relaunch and scan with the saved database. Check that an incomplete/failed attempt did not advance the successful-check date. Device offline recognition itself remains an acceptance check.
4. Turn Automatic Database Updates off, change games and background/foreground the app. Verify no unwanted download or camera prompt. Manual Check Database Updates should still work.
5. When TCGTracking publishes a real changed manifest, confirm only changed files download and the next scan uses the new saved pack. Existing lists, scan order, saved offers and online quotes must remain available.

Automated fixtures can verify caching, cancellation and publication behavior; they cannot establish compatibility with an upstream release that has not been tested on the phone.
