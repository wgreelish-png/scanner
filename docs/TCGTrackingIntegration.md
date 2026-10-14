# TCGTracking integration findings

## Authorization and source boundaries

The user confirmed permission to build this integration and instructed us to treat that permission as established unless revoked. No further permission proof is a prerequisite in this project. This is distinct from technical support: the uploaded code exposes usable ES module exports, but does not establish an official stable plugin API.

Inspected inputs: `mobile.js`, `quickscan.js`, `desk-results.js`, and `tcgtracking.com.har`. The HAR also contains response bodies for `pack.js`, `scan-backends.js`, `shared.js`, `module-graph.js`, and `quickscan-worker.js`; these were inspected outside the checkout. No HAR, session data, cookies, tokens, captured account responses, third-party code, card databases, or third-party assets were copied into the project.

## What the supplied source establishes

- `startQuickScan` is an exported continuous scanner accepting an existing video, overlay, backend, pack, `fetchDetails`, and result/hide/hint callbacks.
- `same: true` events intentionally omit `ref`, `siblings`, `thumb`, and full candidates. They refresh a previous recognition rather than identify another copy.
- A guess becoming accepted can generate `same: false` even for the same physical card. Native deduplication conservatively retains the episode for a same-product refresh or an ambiguous-to-accepted transition.
- `applyResolvedToView` supplies `view.cands`: complete candidate tuples with confidence and printing state. `payloadFromView` alone supplies mostly reference IDs for alternative matches and therefore cannot drive the full native candidate picker.
- Reference tuples contain `[ref, name, number, setAbbreviation, setName, rarity, image, variants]`. Variant records carry `id`, `label`, `nm`, and optional `primary`.
- `loadPackIndex` and `loadPack` are exported by `core/pack.js`. The implementation owns IndexedDB caching and download integrity/layout checks. We reuse that implementation, without changing checks or reconstructing database formats.
- `createBackend` owns a worker path with a main-thread fallback. Its worker bootstrap depends on the page import map and `NSP_STATIC` configuration.
- `shared.catalogDetail` is the existing browser catalog client. Our wrapper passes it to the scanner; it does not reimplement its endpoint or copy authentication. `useScope('price')` selects the existing anonymous quick-scanner scope.
- Phone-to-desktop linking uses a desktop-issued session and is unnecessary for the standalone phone app. No link token, desktop session, push, poll, inventory write, or pairing endpoint is used.

## Implemented path

`TCGTrackingScannerProvider` loads the normal HTTPS `/newscanplus/quick` page in WKWebView. After navigation completes, it evaluates our bundled `TCGTrackingBridge.js`. The bridge adds its own camera surface above the page, keeping the original page, import map, configuration, and origin intact. It neither scrapes the website's result DOM nor patches private callback closures.

The original site's mobile module can initialize in the background, but its camera is not activated by our layer. The user taps our **Download database & Start Camera** button. Our layer imports the observed modules, loads the selected game's pack, constructs a backend and overlay, requests the rear camera, and registers callbacks with `startQuickScan`. Game IDs verified in the supplied sources are Pokémon `tcgp:3`, Magic `tcgp:1`, and Yu-Gi-Oh! `tcgp:2`. No desktop is required by this code path.

Scan callbacks go through `window.webkit.messageHandlers.scanResult.postMessage`. This handler is implemented by our app-owned layer; it is not assumed to exist in TCGTracking. Wire messages contain a per-navigation nonce and an explicit `scan`, `hide`, or `status` kind. Full results contain at most five detailed candidates with per-finish SKU/price data; partial updates retain native card identity. An ambiguous printing requires explicit finish confirmation and cannot auto-add. User-selected candidates never silently auto-add during later frame updates.

Native handling restricts navigation and camera requests to the expected HTTPS main frame. Camera capture uses a system prompt and an application usage description. Off-origin navigation, microphone requests, oversized payloads, malformed refs, invalid numeric values, duplicate candidates and invalid image URLs are rejected. Stale page messages are ignored. Navigation and bridge failures appear as status messages with retry controls; there is no silent mock fallback.

Pause, disappearance, and app backgrounding stop capture. Restart creates a fresh AsyncStream so a previously cancelled consumer cannot terminate future recognition delivery. Inventory is saved only on an intentional add or an eligible, unconsumed automatic result. Scanner sessions survive pause/retry within the current screen. Cache clearing removes matching TCGTracking IndexedDB/resource caches, preserving cookies and the app's SwiftData lists.

## Verification and remaining limits

Ten Node tests execute the app-owned JavaScript adapter, including a fake module/camera harness. They verify normalization, five-candidate limits, missing prices, per-printing quotes, partial frames, nonce delivery, camera startup/teardown, backgrounding, missing packs, and camera denial. They do not execute TCGTracking's recognition engine or simulate WebKit.

Swift source has passed grammar parsing and the Xcode project has passed structural checks. Twelve XCTest cases are provided but have not run. This Linux machine has no Swift compiler, iOS SDK, Xcode, simulator, or camera. Direct cloud access to TCGTracking previously returned proxy HTTP 403. HAR success responses are historical evidence, not proof of current reachability. We have not claimed a successful live scan or an iOS build.

Required device checks: module imports under the current site's CSP/import map; worker/WASM support or main-thread fallback; camera permission grant/deny; download/cache behavior and large-pack memory usage; live candidate/finish accuracy and pricing; start/pause/retry/background teardown; duplicate behavior when an identical physical copy is replaced while the original remains recognized. The engine cannot reliably distinguish two identical physical copies without a loss-of-card/new recognition boundary; use **Add Another Copy** in that case. Website updates may break the experimental module contract; maintain mock mode as a development option.

Observed hosts for device networking are `tcgtracking.com`, `nsp-static.tcgtracking.com`, and `cdn.tcgtracking.com`. Existing modules may load further assets based on the live page's configuration. No cloud network configuration was changed. An official published plugin bridge would be preferable when available; the provider isolates this version-dependent adapter so it can be replaced without changing lists or persistence.

No additional files are currently needed: the HAR supplied the backend and pack files required for this implementation. If an actual runtime failure reveals another missing dependency, request that exact file then. TCGTracking CSV import compatibility remains unverified and is not offered.
