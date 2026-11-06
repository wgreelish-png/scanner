#!/usr/bin/env bash
# Shared simulator preparation; native and UI suites run on separate CI hosts.
set -euo pipefail
SCANNER_TEST_TARGET="${1:?Expected an allowlisted native or UI suite}"
SCANNER_TEST_SELECTION=(-only-testing:"$SCANNER_TEST_TARGET")
SCANNER_UI_RUN=false
for SCANNER_ALLOWED_TARGET in "$@"; do
  case "$SCANNER_ALLOWED_TARGET" in
    CardShowScannerTests/NiimbotImageTransportTests|CardShowScannerTests/NiimbotProtocolTests|CardShowScannerTests/ScannerDiagnosticsTests) ;;
    CardShowScannerTests/LabelPrintQueueTests|CardShowScannerTests/LabelPrintRunOutcomeTests|CardShowScannerTests/CustomPriceTagTests) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testSelectedInventoryIsReadyImmediatelyOnFirstNavigation|CardShowScannerUITests/InventoryLabelsUITests/testReselectedInventoryIsReadyImmediatelyWithoutLayoutChanges|CardShowScannerUITests/InventoryLabelsUITests/testPrintAllIsReadyImmediatelyWithoutLayoutChanges) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testLeavingUnprintedInventoryQueueClearsItAndAllowsPreparingAgain|CardShowScannerUITests/InventoryLabelsUITests/testQueuedPreviewRetainsUnprintedLabelsUntilQueueIsLeft|CardShowScannerUITests/InventoryLabelsUITests/testLeavingCustomAndBulkPrintQueuesClearsThemAndPreservesPreferences|CardShowScannerUITests/InventoryLabelsUITests/testPrintingFailureStaysAvailableForReviewWithoutAutomaticRetryOrNavigation) ;;
    CardShowScannerTests|CardShowScannerUITests|CardShowScannerUITests/ResearchUITests|CardShowScannerUITests/MarketEvidenceUITests|CardShowScannerUITests/AppNavigationUITests|CardShowScannerUITests/ShowBudgetUITests|CardShowScannerUITests/ShowTransactionsUITests|CardShowScannerUITests/CardShowInventoryUITests|CardShowScannerUITests/ReviewPresentationUITests|CardShowScannerUITests/ListBulkDeletionUITests) ;;
    *) echo "Unknown test target" >&2; exit 2 ;;
  esac
  if [[ "$SCANNER_ALLOWED_TARGET" == CardShowScannerUITests* ]]; then SCANNER_UI_RUN=true; fi
done
if [ "$#" -gt 1 ]; then
  shift
  for SCANNER_ADDITIONAL_TARGET in "$@"; do
    SCANNER_TEST_SELECTION+=(-only-testing:"$SCANNER_ADDITIONAL_TARGET")
  done
fi
# Evidence fixtures run in their own job; the broad UI job retains the existing
# scanner, list, pricing and connection cases without repeating the new charts.
if [ "$SCANNER_TEST_TARGET" = CardShowScannerUITests ]; then
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/MarketEvidenceUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/AppNavigationUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ShowBudgetUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ShowTransactionsUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/CardShowInventoryUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ReviewPresentationUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ListBulkDeletionUITests)
fi
if [ "$SCANNER_UI_RUN" = true ]; then
  # UI geometry and startup must not depend on simctl's listing order or data
  # from a previously used device. Only this newly created simulator is stopped.
  DEVICE_ID=$(python3 scripts/prepare_ui_simulator.py create)
  scanner_finish_ui_simulator() {
    SCANNER_UI_EXIT_CODE=$?
    trap - EXIT
    python3 scripts/prepare_ui_simulator.py shutdown "$DEVICE_ID" || true
    exit "$SCANNER_UI_EXIT_CODE"
  }
  trap scanner_finish_ui_simulator EXIT
  python3 scripts/prepare_ui_simulator.py boot "$DEVICE_ID"
  SCANNER_TEST_SELECTION+=(-testLanguage en -testRegion US)
else
  DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x["name"].startswith("iPhone")))')
fi
# Xcode 16.3/16.4's iOS 18.4/18.5 simulator omits a Swift WebKit symlink.
# Forward Apple's runtime-only workaround to XCTest; keep the app's iOS minimum.
SCANNER_SWIFT_OVERLAY_DIR=$(python3 -c '
import json, subprocess, sys
from pathlib import Path
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
runtime_id = next(key for key, values in devices.items() if any(device["udid"] == sys.argv[1] for device in values))
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
runtime = next(value for value in runtimes if value["identifier"] == runtime_id)
root = Path(runtime["runtimeRoot"]) if runtime.get("runtimeRoot") else Path(runtime["bundlePath"]) / "Contents/Resources/RuntimeRoot"
overlay = root / "System/Cryptexes/OS/usr/lib/swift"
if runtime.get("version", "").startswith(("18.4", "18.5")) and (overlay / "libswiftWebKit.dylib").is_file():
    print(overlay)
' "$DEVICE_ID")
if [ -n "$SCANNER_SWIFT_OVERLAY_DIR" ]; then
  export TEST_RUNNER_DYLD_FALLBACK_LIBRARY_PATH="$SCANNER_SWIFT_OVERLAY_DIR:${TEST_RUNNER_DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"
  echo "Using the simulator WebKit Swift-library compatibility path."
fi
# Running Keychain tests needs an application identifier, even on the
# simulator. Ad-hoc signing needs no Apple account or provisioning profile.
# These entitlements/settings exist only for this simulator CI invocation.
SCANNER_SIMULATOR_ENTITLEMENTS="$RUNNER_TEMP/ScannerSimulatorTests.entitlements"
python3 - "$SCANNER_SIMULATOR_ENTITLEMENTS" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'application-identifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'keychain-access-groups': ['$(PRODUCT_BUNDLE_IDENTIFIER)'],
        'get-task-allow': True,
    }, output)
PY
if [ "$SCANNER_UI_RUN" = true ]; then
  # Compile while the cold simulator starts. Neither a failed build nor failed
  # readiness may proceed to XCTest; both retain the failing command's status.
  SCANNER_UI_BUILD_OPTIONS=(-parallel-testing-enabled NO -project CardShowScanner.xcodeproj
    -scheme CardShowScanner -destination "platform=iOS Simulator,id=$DEVICE_ID"
    -derivedDataPath "$RUNNER_TEMP/ScannerUITestBuild"
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$SCANNER_SIMULATOR_ENTITLEMENTS")
  xcodebuild build-for-testing "${SCANNER_TEST_SELECTION[@]}" "${SCANNER_UI_BUILD_OPTIONS[@]}" 2>&1 | tee NativeTests.log
  python3 scripts/prepare_ui_simulator.py ready "$DEVICE_ID" 2>&1 | tee -a NativeTests.log
  xcodebuild test-without-building "${SCANNER_TEST_SELECTION[@]}" "${SCANNER_UI_BUILD_OPTIONS[@]}" -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180 -resultBundlePath TestResults.xcresult 2>&1 | tee -a NativeTests.log
else
  xcodebuild test "${SCANNER_TEST_SELECTION[@]}" -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180 -project CardShowScanner.xcodeproj -scheme CardShowScanner -destination "platform=iOS Simulator,id=$DEVICE_ID" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$SCANNER_SIMULATOR_ENTITLEMENTS" -resultBundlePath TestResults.xcresult 2>&1 | tee NativeTests.log
fi
