# Remembered card image quality — November 13, 2026

Build 117 adds Automatic alongside Low (200px) / High (400px) in Settings → Card images. Automatic uses 200px artwork in list rows, thumbnails and search grids, and 400px artwork when opening a card's details or research. High remains the default and existing Low/High selections are preserved. All three choices persist across launches under `cardImageQuality`.

A shared display loader observes the setting and each view's explicit thumbnail/detail context to select the corresponding known TCGTracking CDN rendition. Low and High apply the same fixed rendition in both contexts. It is used by research, manual search, scan results, lists, inventory and transaction artwork. Canonical front/back URLs keep their product/face identity; custom, signed, external, local and other unrecognized image URLs remain unchanged. Saved card URLs and inventory records are not rewritten.

The cached-only price-tag inventory thumbnails use thumbnail context, prefer an already-cached chosen rendition and retain their original fallback. They do not start image downloads. Label bitmaps, printer DPI and recognition/reference-image processing do not use this setting.

Changing quality changes display requests; it does not purge previously cached images or download a complete offline Pokémon package.

The update also isolates the previous chart's bar/rule content and constrains its inputs after the macOS compiler reported a type-check timeout. Values, chart interactions and accessibility identifiers are retained; native compilation remains subject to CI validation.

## Verification

Native unit coverage checks all three modes in both display contexts, known URL renditions, preserved external/signed URLs, remembered preferences, invalid-preference fallback and unchanged saved URLs. The UI test selects Automatic, Low and High, relaunches the app, verifies each selection and checks that list count and haptics remain unchanged.

Build 117 portable validation passed: 35 workflow/runner tests, Xcode source-registration checks, scanner runtime asset checks and `git diff --check`.

The focused market_activity workflow includes the image-quality tests and prior chart regressions. Native build/UI results require the macOS runner and are reported separately from portable checks.
