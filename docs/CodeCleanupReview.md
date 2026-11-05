# Code cleanup review

Reviewed on 2026-11-05 in the separate `codex/app-code-cleanup` worktree, starting
from `3d7700d` (build 74, revision `direct-inventory-labels`). The original
`codex/ui-reliability` checkout remains unchanged. This branch keeps the same
build number and revision.

## Scope

The repository inventory contained 369 tracked files. The review covered all
application areas: 107 app Swift files, the authored WebKit bridges and bundled
scanner dependencies, UI/navigation, pricing/research/networking, persisted
models and migrations, inventory/imports, financial calculations, diagnostics,
label rendering, printer protocol and queue lifecycle. It also covered the
native/UI test structure, JavaScript tests, research server, Python/shell tools,
Postman collections, documentation, Xcode configuration and CI workflow.

Third-party scanner bundles were checked through their pinned manifest,
dependency closure and existing engine smoke tests; their generated code was
not rewritten. Repository hygiene checks found no tracked build archives,
dependency installation directories, logs or Python bytecode. Host operating
system files and personal device data are outside this cleanup.

## Changes

- Remove an unused review callback and its sole argument, two unused scanner/
  pricing constants, an unused credentials computed property, and the imports
  made unnecessary by those removals.
- Count queue states directly instead of allocating filtered arrays. Build UUID
  sets from lazy projections and produce sorted research keys without a
  temporary filtered dictionary.
- Compute invariant printing normalization and game-sort ranks once per
  operation, and parse the label price once during validation.
- Make three printer request fields immutable; their explicit initializer and
  default argument values remain the same.

These are small, local refactors across 12 Swift files and one Python utility.
An independent diff review checked references, initialization, ordering and
validation behavior. No app speed or memory benchmark improvement is claimed.
Similar-looking financial, storage and networking helpers with distinct rules
were retained. An observable-model normalization refactor was excluded because
it could alter dependency tracking.

## Preservation checks

All 356 existing files outside the 13 approved code edits are byte-identical to
the starting commit. This includes configuration/signing/project settings,
assets/fonts/label artwork, JavaScript and scanner resources, tests, storage
schemas, inventory/import reconciliation, transaction calculations and the
printer driver. No dependencies were updated.

The UI edits remove only an unused closure property and its argument; view
bodies, layouts, strings, routes and active actions are unchanged. No settings
keys/defaults, Codable stored fields, persistence formats, migration logic,
pricing rules, camera timing or printer commands were changed. Personal device
settings, credentials and inventory were not accessed or rewritten.

## Verification

All implementation edits were completed before running the existing checks.

| Check | Result |
| --- | --- |
| App JavaScript tests | 157 passed |
| Research server tests | 59 passed |
| Postman collection tests | 49 passed |
| Python tooling tests | 40 passed |
| Swift grammar | All 192 app/native-test/UI-test files passed |
| Xcode source and resource membership | Passed: 107 app, 71 native-test and 14 UI-test Swift files |
| Pinned scanner assets and dependency closure | All 47 assets passed |
| Real bundled OpenCV smoke | Scalar and SIMD builds passed existing hash, recognition and source-pixel checks |
| Protected file comparison and `git diff --check` | Passed |

The suites used:

```sh
node --experimental-vm-modules --test Tests/JavaScript/*.cjs
node --test server/research/tests/*.test.mjs
node --test postman/test_*.mjs
python3 -m unittest discover -s scripts -p 'test_*.py'
PYTHONPATH=/tmp/scanner-validation python3 scripts/check_xcode_sources.py
python3 scripts/check_scanner_runtime.py
node scripts/scanner_runtime_smoke.cjs opencv-nsp-412.js
node scripts/scanner_runtime_smoke.cjs opencv-nsp-412-simd.js
git diff --check
```

Swift grammar used `tree_sitter_swift` from the external validation environment;
no validation dependencies were added to the app or repository. This Linux
environment cannot compile the iOS app, execute native/UI XCTest suites, or
verify physical camera/printer behavior. The unchanged macOS CI workflow is
available for native verification of this branch. Portable checks do not
establish native compilation or device acceptance.
