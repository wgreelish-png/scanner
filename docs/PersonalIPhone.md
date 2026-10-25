# Keep the tested app on your iPhone

This app can run directly from the iPhone Home Screen after you unplug it. With a free Xcode Personal Team, Apple's development provisioning normally expires after seven days. Release mode does not extend that period. The app can stay installed, but opening it after expiration requires refreshing its signing from Xcode.

## Final installation

1. Keep the existing app installed. Export important lists once before the final upgrade, and retain the same bundle identifier and signing team.
2. After merging the reviewed changes, pull the updated repository on the Mac and open `CardShowScanner.xcodeproj`.
3. Select the **CardShowScanner Personal** scheme and your plugged-in, unlocked iPhone.
4. This shared scheme already uses Release for Run and launches without attaching the debugger. There is no need to edit a shared scheme or project setting locally. The original **CardShowScanner** scheme remains available for Debug builds and live Xcode diagnostics.
5. Run with **Command–R**. Unlock/trust the phone if Xcode asks, then launch the installed app from its Home Screen after unplugging it. Do not delete/reinstall the app to renew signing.

`Config/Signing.local.xcconfig` keeps your team out of Git. Keep that existing ignored file; signing refreshes do not require a new team selection or changes to the shared project.

## One final card-show test

Use a small saved list and perform this as one end-to-end pass:

1. **New scan and camera:** Start New Scan should open a fresh session immediately. If camera permission was previously granted, reopening the scanner should not ask again. A first-ever request still needs your consent. Scan A, B, A and confirm three separate rows in that order.
2. **Review taps:** Open View List. Tap My Card Price, Custom cash offer, the transaction picker, Transaction Math, percentages, Save Offer Estimate and Saved Offer Estimates. These controls must stay in review. Only the explicit Continue Scanning button should open the camera.
3. **Payout and percentages:** On an example with $20 market, $16 trade credit and $15 calculated cash, set My Card Price to $10. The payout is $5.63. Adjust the full-list cash offer to $16: the remaining payout becomes $6.00 and the applied cash percentage is 80%. Enter $0: payout becomes $0. Clear the custom amount: payout returns to $5.63. The app uses your actual session rates, so other rates produce their corresponding amounts.
4. **Persistence:** Save an estimate, leave and reopen the list, then open the saved estimate. Verify its inputs, percentages and payout remain unchanged after editing the live offer. Continue Scanning once, return and confirm the list identity/order and saved estimates remain intact.
5. **Independent launch:** Unplug the phone, close and reopen the app from the Home Screen, and reopen the scanner/list. Confirm cached database reuse and no repeated camera permission request. Pricing needs internet.

This checks the remaining physical interaction behavior. CI checks calculations, persistence, permission decisions/coalescing, compilation and bundled resources; it cannot verify real iPhone taps or camera consent dialogs.

## Weekly signing refresh

Before the next card show, connect the same iPhone to the Mac, open the same tested checkout and run with Command–R. Keep the same team/bundle ID and installed app. That refresh normally preserves lists, estimates, downloaded databases and the website session. If the app says it is no longer available after a week, use this refresh rather than deleting it.

Longer distribution requires an appropriate paid Apple Developer distribution method; a free Personal Team cannot provide an indefinitely valid signature. App Store distribution is separate from keeping this personal build installed.
