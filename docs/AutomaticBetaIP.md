# Automatic Beta IP access

Build 25 checks the phone's public IP when the app becomes active, after a network-path change (with a two-second settling delay), and approximately once a minute while it stays active. The timer, network observer and pending website operation stop when the app becomes inactive. There are no background tasks, background URL sessions or added background entitlements.

In **Settings → API connection → Direct TCGTracking**, save your Beta Shipper ID and API key. **Keep This iPhone Connected** is enabled by default. A signed-in TCGTracking website session for that same Shipper ID is also required; the API key does not authorize account settings changes. If that session has expired or belongs to another account, the section offers the existing in-app website sign-in. Returning from sign-in retries the check. **Check IP Now** is available for troubleshooting, and the toggle disables automatic updates.

As requested, this feature manages the **entire account allowlist**. It replaces every entry with the current phone's single detected public IP, including on the first check if other entries exist. Other phones and servers using the same account will lose access. My Server mode skips phone IP management because its caller is the server instead. To keep multiple clients on one account, turn this feature off and manage allowed IPs on the website.

## How a check works

1. A short-lived WebKit page loads the fixed HTTPS `tcgtracking.com/apiforbeta` settings page without a cached response, using the same persistent website session as the app's existing sign-in.
2. The bundled script checks the page, matching Shipper ID, detected concrete public IPv4/IPv6 address, allowlist textarea and fresh CSRF token. Missing or changed markup, unknown addresses, redirects or a different account prevent mutation.
3. If the only saved entry already matches, no save is sent. Otherwise one `save_ips` POST replaces the list with the detected IP. There is **no separate empty-list save**, key rotation or automatic disclaimer acceptance.
4. Only a successful response containing exactly the expected singleton IP marks the update confirmed. A failed or ambiguous response retains an unconfirmed status and retries later; it does not claim the old list is unchanged when a save may already have reached the server.

The implementation uses the website form contract in the supplied HTML, not a documented API-key-based allowlist-management endpoint. Website changes can require an app update. An expired website session, revoked subscription, network loss or differing IPv4/IPv6 routes between the website and Beta API can still prevent access; automatic IP updates cannot guarantee permanent connectivity. Provider edge propagation can take several seconds after a successful save.

Only coarse result codes enter diagnostics. IPs, cookies, account passwords, CSRF tokens, API keys and raw website responses are not logged. The most recently confirmed IP and check time are displayed in the connection section and held in memory; only the enabled preference is persisted by this feature. Updates are single-flight and generation-guarded; foreground/API lookup callers share a pending check. Website failures do not suppress an otherwise valid Beta request. Failure cooldowns and `Retry-After` remain effective across quick app/network transitions.

Cancellation stops local monitoring and aborts the pending browser operation; it cannot retract a request already accepted by TCGTracking. No new checks begin while inactive. Recognition, inventory, show budgets, prices, offers, CSV, daily API data caches and personal signing settings are unchanged.

## Validation

JavaScript tests cover exact account/page checks, replacement without an empty clear, unchanged-IP no-op, failures, malformed/oversized bodies, cancellation and retry headers. Native cases cover public IP validation, foreground-only scheduling, cancellation/stale results, repeated taps, credential mode changes, retries and response confirmation. The resource and every new Swift file must pass Xcode target membership checks.

Physical-iPhone acceptance is still required with a real signed-in account:

- Launch in Direct mode and confirm the website allowlist contains only the phone IP; unchanged checks must not send another save.
- Switch Wi-Fi/cellular while active, then change networks while away and return. Check the displayed IP and perform an actual OppsV2/Research request after edge propagation.
- Background/lock the app during a pending check. Verify no subsequent polling/saves start until returning.
- Expire the website session, sign in through the connection section and verify recovery without rotating the API key.
- Test an account mismatch, a failed save and an IPv6 connection. Failure must never be labelled a successful update.
- Disable the toggle or select My Server and verify the allowlist is no longer changed.
