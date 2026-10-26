# Build 10: search the downloaded catalog and add cards manually

Open a list or Review & Offer and tap **Search & Add Card**. Type a name, card number or set. Up to five distinct product matches appear in a two-column grid with large artwork previews; accessibility text sizes use one column. Add more terms to narrow the matches:

- `Darkrai`
- `Darkrai 99`
- `Darkrai 99 Triumphant`
- `Darkrai top 99/102 TM`

The ranking uses text relevance, not price or popularity. Name matching ignores case, accents and punctuation. Numeric card numbers are matched from their start, including zero-padded numbers; prefixed numbers such as TG01 are supported too. The existing search bar in list review still filters cards already in that list. Search & Add searches the downloaded game catalog.

Tap a preview to review its printing and condition. Every new selection starts at Near Mint. The online detail service supplies exact printing/condition quotes and SKUs; metadata snapshot prices are never used as live quotes. A known zero is $0 and a missing quote stays unavailable. Connect TCGTracking or retry price if access/network fails. You can explicitly add a card without a market value when no quote exists.

Only **Add to List** writes a card. Each confirmed physical copy becomes its own quantity-one row appended in scan order. Double taps cannot save twice. If saving fails, the selected card, printing and condition remain available for retry. Existing list/session identity and saved offers are retained. If adding to this list would finish another active session, the app asks before switching; it never opens the camera for manual entry.

## Data and performance

Search reads the same native Application Support metadata as recognition. It follows the current game's committed manifest, reads only referenced metadata shards and supports legacy native v1 records. It never starts the camera, loads OpenCV, downloads another database or searches other games' cached metadata. Duplicate product references are combined while retaining printing choices. Missing/incomplete catalog data is visible and retryable; open the scanner once to download the game, or explicitly Check Database Updates to repair it.

Initial indexing runs asynchronously away from the main UI actor and is shared across typing requests. The selected game's index is reused until its manifest changes; cache clearing invalidates it. Search is debounced and capped at five results. Stale search/price replies cannot replace a newer query/selection. Result images and live market prices can need internet; text lookup uses downloaded metadata and does not establish offline pricing support.

This feature changes no recognition algorithms, confidence gates or camera settings. Top Loader Assist and upstream New Scan Plus engine changes are not part of this implementation.

## Validation and later phone check

Native fixtures exercise real native v1/v2 cache encodings, top-five/deduplication, name/number/set refinement (including Darkrai & Cresselia LEGEND Top 99/102), prefixed card numbers, game isolation, database version changes, clear/incomplete cache behavior and unsafe metadata. Further tests cover stale search replies, default condition, exact zero-price/SKU persistence, session resumption/switch confirmation, duplicate rows and failed-add retry. Actual cached-card coverage, previews and interaction speed require the user's iPhone test.

On the phone, try the Darkrai queries above, confirm the correct set/number/artwork, switch condition/printing and add it. Add the same card again and verify two separate rows. Leave/reopen the list and verify order and saved estimates. Cancel another selection and verify no row was added. Search should not open the camera or redownload the database.
