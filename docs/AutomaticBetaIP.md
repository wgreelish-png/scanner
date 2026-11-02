# Automatic Beta IP access

Build 25 checks the phone's public IP when the app becomes active, after a network-path change (with a two-second settling delay), and approximately once a minute while it stays active. The timer, network observer and pending website operation stop when the app becomes inactive. There are no background tasks, background URL sessions or added background entitlements.

In **Settings → API connection → Direct TCGTracking**, save your Beta Shipper ID and API key. **Keep This iPhone Connected** is enabled by default. A signed-in TCGTracking website session for that same Shipper ID is also required; the API key does not authorize account settings changes. If that session has expired or belongs to another account, the section offers the existing in-app website sign-in. Returning from sign-in retries the check. **Check IP Now** is available for troubleshooting, and the toggle disables automatic updates.

Build 33 manages only the address recorded by this iPhone for the selected Beta Shipper ID. When it changes, the app removes that recorded previous address, adds the current one if missing and preserves every other entry. My Server mode still skips phone IP management. IPs are address-level entries; the website does not attach device identities to them.

Older builds did not persist phone IP history. On the first upgraded check, no old address is guessed or removed: the app keeps existing entries, adds the detected current address if needed and starts tracking it. Addresses already removed by an older build must be re-added on the website; this change cannot reconstruct them.

## How a check works

1. A short-lived WebKit page loads the fixed HTTPS `tcgtracking.com/apiforbeta` settings page without a cached response, using the same persistent website session as the app's existing sign-in.
2. The bundled script checks the page, matching Shipper ID, detected concrete public IPv4/IPv6 address, allowlist textarea and fresh CSRF token. Missing or changed markup, unknown addresses, redirects or a different account prevent mutation.
3. The app reads this account’s previous phone IP from device-only Keychain. It merges the page’s current allowlist by removing only that previous address when different, preserving the rest and adding the detected current address if missing. No save is sent for an unchanged result. The website requires a complete list, so one `save_ips` POST sends the merged list; there is no empty clear, key rotation or disclaimer acceptance. A full ten-entry list is never pruned to make room.
4. The script verifies the complete merged response. Native validation also checks that all previously observed protected addresses remain, the current address is present and the previous phone address is absent when it changed. Only verified success updates phone history. A failed or ambiguous response stays unconfirmed; a save already accepted by the website cannot be retracted by local cancellation. The website has no compare-and-swap endpoint, so simultaneous external edits are not an atomic multi-client transaction.

The implementation uses the website form contract in the supplied HTML, not a documented API-key-based allowlist-management endpoint. Website changes can require an app update. An expired website session, revoked subscription, network loss or differing IPv4/IPv6 routes between the website and Beta API can still prevent access; automatic IP updates cannot guarantee permanent connectivity. Provider edge propagation can take several seconds after a successful save.

Only coarse result codes enter diagnostics. IPs, cookies, account passwords, CSRF tokens, API keys and raw website responses are not logged. The most recently confirmed IP and check time appear in the connection section. One canonical previous-phone-IP record per hashed Shipper ID is kept in Keychain with WhenUnlockedThisDeviceOnly and synchronization disabled, separate from API/login credentials. It survives relaunches on this phone and is not transferred to another phone through Keychain sync or backup. Missing history means add-only; unreadable history blocks mutation. A history-write failure stays unconfirmed and is retried before another change for that account. Updates are single-flight and generation-guarded; foreground/API lookup callers share a pending check. Website failures do not suppress an otherwise valid Beta request. Failure cooldowns and `Retry-After` remain effective across quick app/network transitions.

Cancellation stops local monitoring and aborts the pending browser operation; it cannot retract a request already accepted by TCGTracking. No new checks begin while inactive. Recognition, inventory, show budgets, prices, offers, CSV, daily API data caches and personal signing settings are unchanged.

## Validation

JavaScript tests cover preserved third-party addresses, first-run add-only, replacement of only the prior address, unchanged/equivalent IPv6 addresses, preserved unknown/range entries, a full-list no-eviction stop, mismatched merged replies, account/page checks, failures, bounded bodies, cancellation and retry headers. Native cases cover public IP validation, foreground-only scheduling, cancellation/stale results, repeated taps, credential mode changes, retries and response confirmation. The resource and every new Swift file must pass Xcode target membership checks.

Physical-iPhone acceptance is still required with a real signed-in account:

- Add two other device/server addresses on the website, then launch in Direct mode. The first upgraded check must keep them and add/confirm the phone address; unchanged checks must send no save.
- Switch Wi-Fi/cellular while active, then change networks while away and return. Only the recorded previous phone address should disappear; other entries stay. Relaunch and repeat to verify device history. Check actual OppsV2/Research access after propagation.
- Background/lock the app during a pending check. Verify no subsequent polling/saves start until returning.
- Expire the website session, sign in through the connection section and verify recovery without rotating the API key.
- Test an account mismatch, a failed save and an IPv6 connection. Failure must never be labelled a successful update.
- Disable the toggle or select My Server and verify the allowlist is no longer changed.

Build 33 adds native cases for per-account/device-only history, Keychain failures, merged response preservation and capacity handling. After implementation completed, all 151 JavaScript tests passed, including the updated allowlist cases; Swift grammar, target membership and bundled-resource checks also passed. The new native cases have not run locally. Live iPhone/network switching and provider behavior still require acceptance with the actual account.
