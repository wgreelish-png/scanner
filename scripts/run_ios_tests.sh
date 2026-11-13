#!/usr/bin/env bash
# Shared simulator preparation; native and UI suites run on separate CI hosts.
set -euo pipefail
SCANNER_TEST_TARGET="${1:?Expected an allowlisted native or UI suite}"
SCANNER_TEST_SELECTION=(-only-testing:"$SCANNER_TEST_TARGET")
SCANNER_UI_RUN=false
for SCANNER_ALLOWED_TARGET in "$@"; do
  case "$SCANNER_ALLOWED_TARGET" in
    CardShowScannerTests/NiimbotProtocolTests|CardShowScannerTests/ScannerDiagnosticsTests|CardShowScannerTests/NiimbotImageTransferPreferencesTests) ;;
    CardShowScannerTests/NiimbotRollReadCoordinatorTests|CardShowScannerTests/NiimbotLabelCatalogTests|CardShowScannerTests/NiimbotLabelProductResolverTests) ;;
    CardShowScannerTests/LabelPrintQueueTests|CardShowScannerTests/LabelPrintRunOutcomeTests|CardShowScannerTests/CustomPriceTagTests) ;;
    CardShowScannerTests/InventoryLabelTests|CardShowScannerTests/AdaptiveLabelRenderingTests|CardShowScannerTests/CustomLabelQueueTests) ;;
    CardShowScannerTests/ShowInventorySortTests|CardShowScannerTests/InventoryLabelBatchTests) ;;
    CardShowScannerTests/ShowBudgetTests|CardShowScannerTests/ShowBudgetStoreTests|CardShowScannerTests/ShowCostLedgerTests) ;;
    CardShowScannerTests/OwnedListInventoryTests|CardShowScannerTests/ShowInventoryReconciliationTests|CardShowScannerTests/ShowTransactionListServiceTests) ;;
    CardShowScannerTests/LabelPrintProgressSessionTests|CardShowScannerTests/ScannerPageRecoveryTests|CardShowScannerTests/DeviceHealthMonitorTests|CardShowScannerTests/DeviceHealthValuesTests) ;;
    CardShowScannerTests/ScannerTextRecognitionTests|CardShowScannerTests/ScannerTextProviderPreferenceTests|CardShowScannerTests/ScannerTextRecognitionStateTests|CardShowScannerTests/ScannerTextRecognitionFlowTests) ;;
    CardShowScannerTests/ManualCatalogFilterTests|CardShowScannerTests/LocalScannerServerTests) ;;
    CardShowScannerTests/OpportunitiesTests|CardShowScannerTests/MarketActivityPresentationTests|CardShowScannerTests/MarketEvidenceTests|CardShowScannerTests/MarketInsightsTests) ;;
    CardShowScannerTests/CardResearchModelTests|CardShowScannerTests/ResearchEvidenceTests|CardShowScannerTests/ResearchTests) ;;
    CardShowScannerTests/ManualCardSearchTests|CardShowScannerTests/OpenAPIMarketPricingTests|CardShowScannerTests/TCGGameRegistryTests|CardShowScannerTests/TCGGamePricingTests|CardShowScannerTests/CardEditorPricingTests) ;;
    CardShowScannerTests/PhotoScanStateTests|CardShowScannerTests/PhotoScanProviderPreferenceTests|CardShowScannerTests/ScannerManualSearchLifecycleTests) ;;
    CardShowScannerUITests/PhotoScanUITests/testPhotoCaptureRequiresRetakeAndRemembersMode) ;;
    CardShowScannerUITests/LeftoverStockFlowTests/testCompletedCountExportsOnlyPositiveAbsoluteStockWithoutChangingInventory) ;;
    CardShowScannerUITests/ReviewPresentationUITests/testManualFiltersAndQuerySurviveConfirmationBack) ;;
    CardShowScannerUITests/ReviewPresentationUITests/testSuccessfulManualAddClosesBothSheetsAndCommitsOneRow|CardShowScannerUITests/ReviewPresentationUITests/testCancellingManualConfirmationKeepsSearchAndDoesNotSave) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testCustomPrintStartsFromPreviewWithoutAQueueStepAndWaitsForFinalAcknowledgement|CardShowScannerUITests/InventoryLabelsUITests/testSelectedInventoryPrintsDirectlyAndCompletedReceiptsDoNotBlockCustomTags|CardShowScannerUITests/InventoryLabelsUITests/testDirectPrintFailureRetainsUncertainLabelsAndRequiresCheckingBeforeRetry) ;;
    CardShowScannerUITests/ReviewPresentationUITests/testMissingPricesRefreshUpdatesUnknownCardAndPreservesKnownZero) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testSelectedInventoryIsReadyImmediatelyOnFirstNavigation|CardShowScannerUITests/InventoryLabelsUITests/testReselectedInventoryIsReadyImmediatelyWithoutLayoutChanges|CardShowScannerUITests/InventoryLabelsUITests/testPrintAllIsReadyImmediatelyWithoutLayoutChanges) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testInventoryPrintOrderSortsNumericPricesAndRemembersSelection) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testGameFilterCarriesFromInventoryIntoPrintedLabelBatch) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testPaperModeCanBeChosenOfflineWithoutStartingBluetooth|CardShowScannerUITests/InventoryLabelsUITests/testPaperModePreferenceSurvivesRelaunchAfterUnprintedQueueCleanup|CardShowScannerUITests/InventoryLabelsUITests/testPaperModeQueueReplacementPreservesLabelContentAndInventory) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testPauseDuringUploadKeepsEveryUnconfirmedCopyAvailableForReview|CardShowScannerUITests/InventoryLabelsUITests/testPauseKeepsProgressForQueueReviewInsteadOfReturningToPriceTags) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testSingleCardDraftIsIsolatedAndAcceptsZeroWithoutClampingCopies|CardShowScannerUITests/InventoryLabelsUITests/testSingleCardDraftCancelPreservesInventoryAndBudget) ;;
    CardShowScannerUITests/AppNavigationUITests/testEditableCardRetainsMainTabsAndUnsavedDraftThroughResearchAndConnection|CardShowScannerUITests/AppNavigationUITests/testEditableCardSavesOnlyWhenExplicitlySavedAfterSwitchingTabs) ;;
    CardShowScannerUITests/ReviewPresentationUITests/testListLookupStaysVisibleAfterScrollingAndPreservesCardsAndOfferDraft|CardShowScannerUITests/ShowTransactionsUITests/testOwnedScannedListEntersInventoryOnceWithoutChangingShowCash|CardShowScannerUITests/InventoryLabelsUITests/testCustomPrintingShowsProgressWaitsForFinalAcknowledgementAndReturnsToPriceTags) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testLeavingUnprintedInventoryQueueClearsItAndAllowsPreparingAgain|CardShowScannerUITests/InventoryLabelsUITests/testQueuedPreviewRetainsUnprintedLabelsUntilQueueIsLeft|CardShowScannerUITests/InventoryLabelsUITests/testLeavingCustomAndBulkPrintQueuesClearsThemAndPreservesPreferences|CardShowScannerUITests/InventoryLabelsUITests/testPrintingFailureStaysAvailableForReviewWithoutAutomaticRetryOrNavigation) ;;
    CardShowScannerUITests/InventoryLabelsUITests/testBatchSearchCopiesPreviewAndLeavingUnprintedQueueClearsBeforeRelaunch) ;;
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
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ResearchUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/MarketEvidenceUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/AppNavigationUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ShowBudgetUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ShowTransactionsUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/CardShowInventoryUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ReviewPresentationUITests)
  SCANNER_TEST_SELECTION+=(-skip-testing:CardShowScannerUITests/ListBulkDeletionUITests)
fi
# Validate all overrides before creating resources or invoking Apple tools.
SCANNER_BUILD_TIMEOUT_SECONDS="${SCANNER_BUILD_TIMEOUT_SECONDS:-1800}"
SCANNER_TEST_TIMEOUT_SECONDS="${SCANNER_TEST_TIMEOUT_SECONDS:-$([ "$SCANNER_UI_RUN" = true ] && echo 3600 || echo 2700)}"
SCANNER_CLEANUP_TIMEOUT_SECONDS="${SCANNER_CLEANUP_TIMEOUT_SECONDS:-30}"
export SCANNER_BUILD_TIMEOUT_SECONDS SCANNER_TEST_TIMEOUT_SECONDS SCANNER_CLEANUP_TIMEOUT_SECONDS
python3 - <<'PYBUDGET'
import os, sys
sys.path.insert(0, "scripts")
from process_budget import seconds
for key in ("SCANNER_BUILD_TIMEOUT_SECONDS", "SCANNER_TEST_TIMEOUT_SECONDS", "SCANNER_CLEANUP_TIMEOUT_SECONDS", "SCANNER_SIMCTL_TIMEOUT_SECONDS"):
    if key in os.environ:
        seconds(os.environ[key])
PYBUDGET
SCANNER_WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/scanner-tests.XXXXXXXX")
export SCANNER_DEVICE_NAME_FILE="$SCANNER_WORK_DIR/device-name"
DEVICE_ID=""
SCANNER_CHILD=""
scanner_finish() {
  SCANNER_EXIT_CODE=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [ -n "$SCANNER_CHILD" ]; then
    kill -TERM "$SCANNER_CHILD" 2>/dev/null || true
    wait "$SCANNER_CHILD" 2>/dev/null || true
  fi
  if [ -z "$DEVICE_ID" ] && [ -s "$SCANNER_WORK_DIR/device-id" ]; then
    DEVICE_ID=$(cat "$SCANNER_WORK_DIR/device-id")
  fi
  if [ "$SCANNER_UI_RUN" = true ] && [ -z "$DEVICE_ID" ] && [ -s "$SCANNER_DEVICE_NAME_FILE" ]; then
    DEVICE_ID=$(python3 scripts/prepare_ui_simulator.py recover) || true
  fi
  if [ "$SCANNER_UI_RUN" = true ] && [ -n "$DEVICE_ID" ]; then
    python3 scripts/prepare_ui_simulator.py shutdown "$DEVICE_ID" || true
    python3 scripts/prepare_ui_simulator.py delete "$DEVICE_ID" || true
  fi
  python3 scripts/process_budget.py --seconds "$SCANNER_CLEANUP_TIMEOUT_SECONDS" -- rm -rf "$SCANNER_WORK_DIR" || true
  exit "$SCANNER_EXIT_CODE"
}
trap scanner_finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# An asynchronous child plus wait lets Bash handle signals immediately rather
# than deferring its trap until a foreground xcodebuild finally exits.
scanner_command() {
  "$@" &
  SCANNER_CHILD=$!
  local status=0
  wait "$SCANNER_CHILD" || status=$?
  SCANNER_CHILD=""
  return "$status"
}
if [ "$SCANNER_UI_RUN" = true ]; then
  scanner_command python3 scripts/prepare_ui_simulator.py create > "$SCANNER_WORK_DIR/device-id"
  DEVICE_ID=$(cat "$SCANNER_WORK_DIR/device-id")
  scanner_command python3 scripts/prepare_ui_simulator.py boot "$DEVICE_ID"
  SCANNER_TEST_SELECTION+=(-testLanguage en -testRegion US)
else
  scanner_command python3 scripts/process_budget.py --seconds "${SCANNER_SIMCTL_TIMEOUT_SECONDS:-300}" -- xcrun simctl list devices available -j > "$SCANNER_WORK_DIR/devices.json"
  DEVICE_ID=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x["name"].startswith("iPhone")))' "$SCANNER_WORK_DIR/devices.json")
fi
# Xcode 16.3/16.4's iOS 18.4/18.5 simulator omits a Swift WebKit symlink.
# Forward Apple's runtime-only workaround to XCTest; keep the app's iOS minimum.
scanner_command python3 -c '
import json, sys, os
sys.path.insert(0, "scripts")
from process_budget import run, seconds
from pathlib import Path
devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"], check=True, capture_output=True, timeout=seconds(os.environ.get("SCANNER_SIMCTL_TIMEOUT_SECONDS", 300))).stdout)["devices"]
runtime_id = next(key for key, values in devices.items() if any(device["udid"] == sys.argv[1] for device in values))
runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"], check=True, capture_output=True, timeout=seconds(os.environ.get("SCANNER_SIMCTL_TIMEOUT_SECONDS", 300))).stdout)["runtimes"]
runtime = next(value for value in runtimes if value["identifier"] == runtime_id)
root = Path(runtime["runtimeRoot"]) if runtime.get("runtimeRoot") else Path(runtime["bundlePath"]) / "Contents/Resources/RuntimeRoot"
overlay = root / "System/Cryptexes/OS/usr/lib/swift"
if runtime.get("version", "").startswith(("18.4", "18.5")) and (overlay / "libswiftWebKit.dylib").is_file():
    print(overlay)
' "$DEVICE_ID" > "$SCANNER_WORK_DIR/overlay"
SCANNER_SWIFT_OVERLAY_DIR=$(cat "$SCANNER_WORK_DIR/overlay")
if [ -n "$SCANNER_SWIFT_OVERLAY_DIR" ]; then
  export TEST_RUNNER_DYLD_FALLBACK_LIBRARY_PATH="$SCANNER_SWIFT_OVERLAY_DIR:${TEST_RUNNER_DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"
  echo "Using the simulator WebKit Swift-library compatibility path."
fi
# Running Keychain tests needs an application identifier, even on the
# simulator. Ad-hoc signing needs no Apple account or provisioning profile.
# These entitlements/settings exist only for this simulator CI invocation.
SCANNER_SIMULATOR_ENTITLEMENTS="$SCANNER_WORK_DIR/ScannerSimulatorTests.entitlements"
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
  # The destination selects one simulator architecture; retain every requested test.
  SCANNER_UI_BUILD_OPTIONS=(-parallel-testing-enabled NO -project CardShowScanner.xcodeproj
    -scheme CardShowScanner -destination "platform=iOS Simulator,id=$DEVICE_ID"
    -derivedDataPath "$SCANNER_WORK_DIR/ScannerUITestBuild"
    ONLY_ACTIVE_ARCH=YES
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$SCANNER_SIMULATOR_ENTITLEMENTS")
  scanner_command python3 scripts/process_budget.py --seconds "$SCANNER_BUILD_TIMEOUT_SECONDS" --log NativeTests.log -- xcodebuild build-for-testing "${SCANNER_TEST_SELECTION[@]}" "${SCANNER_UI_BUILD_OPTIONS[@]}"
  scanner_command python3 scripts/prepare_ui_simulator.py ready "$DEVICE_ID" >> NativeTests.log 2>&1
  scanner_command python3 scripts/process_budget.py --seconds "$SCANNER_TEST_TIMEOUT_SECONDS" --log NativeTests.log --append -- xcodebuild test-without-building "${SCANNER_TEST_SELECTION[@]}" "${SCANNER_UI_BUILD_OPTIONS[@]}" -test-timeouts-enabled YES -default-test-execution-time-allowance 360 -maximum-test-execution-time-allowance 360 -resultBundlePath TestResults.xcresult
else
  scanner_command python3 scripts/process_budget.py --seconds "$SCANNER_TEST_TIMEOUT_SECONDS" --log NativeTests.log -- xcodebuild test "${SCANNER_TEST_SELECTION[@]}" -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180 -project CardShowScanner.xcodeproj -scheme CardShowScanner -destination "platform=iOS Simulator,id=$DEVICE_ID" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$SCANNER_SIMULATOR_ENTITLEMENTS" -resultBundlePath TestResults.xcresult
fi
