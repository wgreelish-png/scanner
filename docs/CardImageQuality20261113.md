# Remembered card image quality — November 13, 2026

Build 116 adds Settings → Card images → Low (200px) / High (400px). High is the default and the selection persists across launches under `cardImageQuality`.

A shared display loader observes the setting and selects the corresponding known TCGTracking CDN rendition. It is used by research, manual search, scan results, lists, inventory and transaction artwork. Canonical front/back URLs keep their product/face identity; custom, signed, external, local and other unrecognized image URLs remain unchanged. Saved card URLs and inventory records are not rewritten.

The cached-only price-tag inventory thumbnails prefer an already-cached chosen rendition and retain their original fallback. They do not start image downloads. Label bitmaps, printer DPI and recognition/reference-image processing do not use this setting.

Changing quality changes display requests; it does not purge previously cached images or download a complete offline Pokémon package.

The update also splits the previous chart's large sales-volume view into smaller SwiftUI helpers after the macOS compiler reported a type-check timeout. Values, chart interactions and accessibility identifiers are retained.

## Verification

Native unit coverage checks known URL renditions, preserved external/signed URLs, remembered preferences, invalid-preference fallback and unchanged saved URLs. The UI test selects Low and High, relaunches the app, verifies the selection and checks that list count and haptics remain unchanged.

Portable validation passed: 35 workflow/runner tests, Xcode source-registration checks, scanner runtime asset checks and `git diff --check`.

The focused market_activity workflow includes the image-quality tests and prior chart regressions. Native build/UI results require the macOS runner and are reported separately from portable checks.
