"""Exercise runner ordering and failure propagation without Xcode or a device."""
from __future__ import annotations

import contextlib
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import time
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prepare_ui_simulator


FAKE_TOOL = r'''
import json, os, pathlib, sys, time
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["SCANNER_EVENT_LOG"], "a") as output:
    output.write(json.dumps({"tool": tool, "args": args}) + "\n")
if (tool == "xcodebuild" and args[0] == os.environ.get("SCANNER_HANG_ACTION")) or (tool == "xcrun" and len(args) > 1 and args[1] == os.environ.get("SCANNER_HANG_SIMCTL")):
    time.sleep(60)
if tool == "xcodebuild":
    print("Controlled build/test output")
    sys.exit(19 if args[0] == os.environ.get("SCANNER_FAIL_ACTION") else 0)
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
owned = "10000000-0000-0000-0000-000000000002"
if args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {runtime: [
        {"name": "iPhone 16 Pro", "udid": "10000000-0000-0000-0000-000000000001",
         "isAvailable": True, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
        {"name": "Scanner UI Tests", "udid": owned, "isAvailable": True}
    ]}}))
elif args[:3] == ["simctl", "list", "runtimes"]:
    print(json.dumps({"runtimes": [{"identifier": runtime, "version": "18.5",
        "isAvailable": True, "runtimeRoot": os.environ.get("RUNNER_TEMP", "/tmp") + "/RuntimeRoot"}]}))
elif args[:2] == ["--sdk", "iphonesimulator"]:
    print("18.5")
elif args[:2] == ["simctl", "create"]:
    print(owned)
elif args[:2] == ["simctl", "bootstatus"] and os.environ.get("SCANNER_FAIL_READY"):
    print("Controlled readiness failure", file=sys.stderr)
    sys.exit(7)
'''


class UIRunnerFlowTests(unittest.TestCase):
    def run_flow(self, target="CardShowScannerUITests", additional_targets=(), **settings):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts, binary = root / "scripts", root / "bin"
            scripts.mkdir(); binary.mkdir()
            for name in ("run_ios_tests.sh", "prepare_ui_simulator.py", "process_budget.py"):
                shutil.copyfile(Path(__file__).parent / name, scripts / name)
            for name in ("xcrun", "xcodebuild"):
                executable = binary / name
                executable.write_text("#!" + sys.executable + "\n" + FAKE_TOOL)
                executable.chmod(0o755)
            events = root / "events.jsonl"
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               RUNNER_TEMP=directory, SCANNER_EVENT_LOG=str(events), **settings)
            if environment.pop("SCANNER_UNSET_RUNNER_TEMP", None):
                environment.pop("RUNNER_TEMP", None)
            cancel = environment.pop("SCANNER_CANCEL_RUNNER", None)
            command = ["bash", "scripts/run_ios_tests.sh", target, *additional_targets]
            if cancel:
                process = subprocess.Popen(command, cwd=root, env=environment, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if events.exists() and '"tool": "xcodebuild"' in events.read_text():
                            break
                        time.sleep(.01)
                    else:
                        self.fail("Runner did not start xcodebuild")
                    process.send_signal(int(cancel))
                    stdout, stderr = process.communicate(timeout=5)
                    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
                finally:
                    if process.poll() is None:
                        process.kill(); process.communicate()
            else:
                result = subprocess.run(command, cwd=root, env=environment, text=True,
                                        capture_output=True, timeout=20)
            commands = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
            log = (root / "NativeTests.log").read_text() if (root / "NativeTests.log").exists() else ""
            return result, commands, log

    def actions(self, commands):
        return [row["args"][0] for row in commands if row["tool"] == "xcodebuild"]

    def assert_shutdown(self, commands):
        self.assertEqual([row["args"] for row in commands[-2:]],
                         [["simctl", action, "10000000-0000-0000-0000-000000000002"] for action in ("shutdown", "delete")])

    def test_ui_boot_overlaps_compilation_and_readiness_precedes_test_execution(self):
        result, commands, log = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.actions(commands), ["build-for-testing", "test-without-building"])
        boot = next(i for i, row in enumerate(commands) if row["args"][:2] == ["simctl", "boot"])
        build = next(i for i, row in enumerate(commands) if row["tool"] == "xcodebuild")
        ready = next(i for i, row in enumerate(commands) if row["args"][:2] == ["simctl", "bootstatus"])
        test = next(i for i, row in enumerate(commands) if row["args"][0] == "test-without-building")
        self.assertLess(boot, build); self.assertLess(build, ready); self.assertLess(ready, test)
        builds = [row["args"] for row in commands if row["tool"] == "xcodebuild"]
        self.assertNotIn("-resultBundlePath", builds[0])
        self.assertIn("-resultBundlePath", builds[1])
        self.assertEqual(log.count("Controlled build/test output"), 2)
        self.assert_shutdown(commands)

    def test_failed_build_stops_before_readiness_or_tests_and_preserves_failure(self):
        result, commands, _ = self.run_flow(SCANNER_FAIL_ACTION="build-for-testing")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(self.actions(commands), ["build-for-testing"])
        self.assertFalse(any(row["args"][:2] == ["simctl", "bootstatus"] for row in commands))
        self.assert_shutdown(commands)

    def test_failed_readiness_never_starts_tests_and_is_retained_in_log(self):
        result, commands, log = self.run_flow(SCANNER_FAIL_READY="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.actions(commands), ["build-for-testing"])
        self.assertIn("boot readiness failed", log)
        self.assert_shutdown(commands)

    def test_test_failure_survives_cleanup(self):
        result, commands, _ = self.run_flow(SCANNER_FAIL_ACTION="test-without-building")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(self.actions(commands), ["build-for-testing", "test-without-building"])
        self.assert_shutdown(commands)

    def test_native_tests_keep_original_single_action_and_existing_device(self):
        result, commands, _ = self.run_flow(target="CardShowScannerTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.actions(commands), ["test"])
        self.assertFalse(any(row["args"][:2] in (["simctl", "create"], ["simctl", "boot"],
                                                ["simctl", "shutdown"]) for row in commands))

    def test_simulator_compilation_uses_destination_architecture_without_dropping_requested_tests(self):
        for target in ("CardShowScannerUITests", "CardShowScannerTests"):
            with self.subTest(target=target):
                result, commands, _ = self.run_flow(target=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                builds = [row["args"] for row in commands if row["tool"] == "xcodebuild"]
                for arguments in builds:
                    self.assertEqual(arguments.count("ONLY_ACTIVE_ARCH=YES"), 1)
                    self.assertIn("platform=iOS Simulator,id=", arguments[arguments.index("-destination") + 1])
                    self.assertIn("-only-testing:" + target, arguments)
                    self.assertFalse(any(value.startswith("ARCHS=") for value in arguments),
                                     "The simulator destination, not a hard-coded architecture, selects the build")

    def test_ui_navigation_has_a_bounded_longer_allowance_without_relaxing_native_test_limits(self):
        label_targets = tuple("CardShowScannerUITests/InventoryLabelsUITests/" + name for name in (
            "testPaperModeCanBeChosenOfflineWithoutStartingBluetooth",
            "testPaperModePreferenceSurvivesRelaunchAfterUnprintedQueueCleanup",
            "testPaperModeQueueReplacementPreservesLabelContentAndInventory",
            "testPauseDuringUploadKeepsEveryUnconfirmedCopyAvailableForReview",
            "testPauseKeepsProgressForQueueReviewInsteadOfReturningToPriceTags",
            "testPrintingFailureStaysAvailableForReviewWithoutAutomaticRetryOrNavigation",
            "testSingleCardDraftIsIsolatedAndAcceptsZeroWithoutClampingCopies",
            "testSingleCardDraftCancelPreservesInventoryAndBudget",
            "testInventoryPrintOrderSortsNumericPricesAndRemembersSelection",
            "testLeavingCustomAndBulkPrintQueuesClearsThemAndPreservesPreferences"))
        navigation_targets = tuple("CardShowScannerUITests/AppNavigationUITests/" + name for name in (
            "testEditableCardRetainsMainTabsAndUnsavedDraftThroughResearchAndConnection",
            "testEditableCardSavesOnlyWhenExplicitlySavedAfterSwitchingTabs"))
        ui_arguments = None
        for targets, action, allowance in ((("CardShowScannerUITests",), "test-without-building", "360"),
                                           (("CardShowScannerTests",), "test", "180"),
                                           (label_targets, "test-without-building", "360"),
                                           (navigation_targets, "test-without-building", "360")):
            with self.subTest(targets=targets):
                result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = next(row["args"] for row in commands
                                 if row["tool"] == "xcodebuild" and row["args"][0] == action)
                self.assertEqual(arguments[arguments.index("-test-timeouts-enabled") + 1], "YES")
                for option in ("-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance"):
                    self.assertEqual(arguments[arguments.index(option) + 1], allowance)
                for target in targets:
                    self.assertIn("-only-testing:" + target, arguments)
                if targets == ("CardShowScannerUITests",):
                    ui_arguments = arguments
                elif targets in (label_targets, navigation_targets):
                    self.assertEqual([value for value in arguments if value.startswith("-only-testing:")],
                                     ["-only-testing:" + target for target in targets])
                    self.assertFalse(any(value.startswith("-skip-testing:") for value in arguments))

        rejected_selections = [(*targets[:-1], targets[-1] + "Typo")
                               for targets in (label_targets, navigation_targets)]
        rejected_selections.append(("CardShowScannerUITests/InventoryLabelsUITests/"
                                    "testPaperModeCanBeChosenOfflineAndPersistsAfterUnprintedQueueCleanup",))
        for targets in rejected_selections:
            rejected, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("Unknown test target", rejected.stderr)
            self.assertFalse(commands, "An unallowlisted method must fail before invoking any tool")

        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        job_blocks = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)",
                                     workflow.split("\njobs:\n", 1)[1]))
        budgets = {name: int(re.search(r"(?m)^    timeout-minutes: (\d+)$", block).group(1))
                   for name, block in job_blocks.items()}
        # Derive the full selection from the actual runner arguments rather
        # than letting a job deadline silently truncate later requested cases.
        excluded = {argument.split("/", 1)[1] for argument in ui_arguments
                    if argument.startswith("-skip-testing:CardShowScannerUITests/")}
        class_cases = {}
        for path in (root / "UITests").glob("*UITests.swift"):
            source = path.read_text()
            classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
            self.assertEqual(len(classes), 1, str(path))
            class_cases[classes[0]] = len(re.findall(r"(?m)^\s*func\s+test\w+\s*\(", source))
        selected_cases = sum(count for name, count in class_cases.items() if name not in excluded)
        self.assertGreater(selected_cases, 0)
        self.assertIn("ResearchUITests", excluded)
        self.assertGreaterEqual(budgets["ui"] * 60, 3600 + 1800 + 600)
        self.assertGreaterEqual(budgets["native"] * 60, 2700 + 600)
        concurrency = workflow.split("\nconcurrency:\n", 1)[1].split("\njobs:\n", 1)[0]
        self.assertRegex(concurrency, r"(?m)^  cancel-in-progress: true$")
        self.assertNotIn("github.sha", concurrency)
        self.assertIn("tooling", job_blocks)

        options = workflow.split("      test_scope:\n", 1)[1].split("\nconcurrency:\n", 1)[0]
        self.assertIn("          - label_controls\n", options)
        self.assertIn("          - navigation_price", options.splitlines())
        self.assertNotIn("          - paper_mode\n", options)
        controls_branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = label_controls \]; then\n'
                                    r'(.*?)(?=\n          (?:elif|else|fi)\b)', job_blocks["ui"], re.DOTALL)
        self.assertIsNotNone(controls_branch)
        self.assertEqual(controls_branch.group(1).replace("\\\n", " ").split(),
                         ["bash", "scripts/run_ios_tests.sh", *label_targets])
        self.assertIn('if [ "$SCANNER_TEST_SCOPE" = printer_transport ] || '
                      '[ "$SCANNER_TEST_SCOPE" = label_controls ]; then', job_blocks["native"])
        for name in ("research_ui", "evidence_ui", "budget_ui"):
            self.assertIn("inputs.test_scope != 'label_controls'", job_blocks[name].splitlines()[0])
        for name in ("ui", "research_ui", "budget_ui"):
            self.assertIn("inputs.test_scope != 'navigation_price'", job_blocks[name].splitlines()[0])
        self.assertNotIn("inputs.test_scope != 'navigation_price'", job_blocks["evidence_ui"].splitlines()[0])
        evidence_command = re.search(r"(?ms)^        run: \|\n(.*?)(?=^      - name:)",
                                     job_blocks["evidence_ui"]).group(1)
        with tempfile.TemporaryDirectory() as directory:
            scripts = Path(directory) / "scripts"
            scripts.mkdir()
            (scripts / "run_ios_tests.sh").write_text('printf "%s\\n" "$@"\n')
            for scope, expected in (("navigation_price", navigation_targets),
                                    ("all", ("CardShowScannerUITests/MarketEvidenceUITests",
                                             "CardShowScannerUITests/AppNavigationUITests",
                                             "CardShowScannerUITests/ReviewPresentationUITests",
                                             "CardShowScannerUITests/ListBulkDeletionUITests"))):
                selected = subprocess.run(["bash", "-c", evidence_command], cwd=directory,
                                          env=dict(os.environ, SCANNER_TEST_SCOPE=scope),
                                          text=True, capture_output=True, timeout=5)
                self.assertEqual(selected.returncode, 0, selected.stderr)
                self.assertEqual(selected.stdout.splitlines(), list(expected))
            rejected = subprocess.run(["bash", "-c", evidence_command], cwd=directory,
                                      env=dict(os.environ, SCANNER_TEST_SCOPE="navigation_priceTypo"),
                                      text=True, capture_output=True, timeout=5)
            self.assertEqual(rejected.returncode, 2)
            self.assertEqual(rejected.stdout, "", "Unknown scopes cannot start the test runner")
            self.assertIn("Unknown evidence UI test scope", rejected.stderr)
        label_source = (root / "UITests/InventoryLabelsUITests.swift").read_text()
        for target in label_targets:
            self.assertRegex(label_source, r"\bfunc\s+" + target.rsplit("/", 1)[1] + r"\s*\(")
        navigation_source = (root / "UITests/AppNavigationUITests.swift").read_text()
        for target in navigation_targets:
            self.assertRegex(navigation_source, r"\bfunc\s+" + target.rsplit("/", 1)[1] + r"\s*\(")

    def test_text_assist_keeps_exact_native_selection_without_ui_or_release(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        targets = tuple("CardShowScannerTests/" + name for name in (
            "ScannerTextRecognitionTests", "ScannerTextProviderPreferenceTests", "ScannerTextRecognitionStateTests",
            "ScannerTextRecognitionFlowTests", "PhotoScanStateTests",
            "PhotoScanProviderPreferenceTests", "ManualCatalogFilterTests", "ScannerManualSearchLifecycleTests",
            "ScannerDiagnosticsTests"))
        for name, block in jobs.items():
            self.assertEqual("inputs.job_scope == 'text_assist'" in block.splitlines()[0], name == "native")
        options = workflow.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertNotIn("          - text_assist\n", options)
        branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = text_assist \]; then\n'
                           r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs["native"], re.DOTALL)
        self.assertIsNotNone(branch)
        self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                         ["bash", "scripts/run_ios_tests.sh", *targets])
        result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
        self.assertEqual(result.returncode, 0, result.stderr)
        test = next(row["args"] for row in commands if row["tool"] == "xcodebuild" and row["args"][0] == "test")
        self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                         ["-only-testing:" + target for target in targets])
        self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
        for target in targets[:4]:
            rejected, commands, _ = self.run_flow(target=target + "Typo")
            self.assertEqual(rejected.returncode, 2); self.assertFalse(commands)

    def test_scanner_polish_keeps_exact_native_and_ui_selections_and_owned_cleanup(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        expected = {
            "native": tuple("CardShowScannerTests/" + name for name in (
                "ManualCardSearchTests", "ManualCatalogFilterTests", "LocalScannerServerTests", "ScannerDiagnosticsTests",
                "ScannerManualSearchLifecycleTests", "PhotoScanStateTests", "PhotoScanProviderPreferenceTests")),
            "ui": tuple("CardShowScannerUITests/ReviewPresentationUITests/" + name for name in (
                "testSuccessfulManualAddClosesBothSheetsAndCommitsOneRow",
                "testCancellingManualConfirmationKeepsSearchAndDoesNotSave",
                "testManualFiltersAndQuerySurviveConfirmationBack")) + (
                    "CardShowScannerUITests/PhotoScanUITests/testPhotoCaptureRequiresRetakeAndRemembersMode",)
        }
        for name, block in jobs.items():
            self.assertEqual("inputs.job_scope == 'scanner_polish'" in block.splitlines()[0], name in expected)
        options = workflow.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertNotIn("          - scanner_polish\n", options)
        for name, targets in expected.items():
            with self.subTest(job=name):
                branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = scanner_polish \]; then\n'
                                   r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs[name], re.DOTALL)
                self.assertIsNotNone(branch)
                self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                                 ["bash", "scripts/run_ios_tests.sh", *targets])
                result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
                self.assertEqual(result.returncode, 0, result.stderr)
                action = "test" if name == "native" else "test-without-building"
                test = next(row["args"] for row in commands if row["tool"] == "xcodebuild" and row["args"][0] == action)
                self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                                 ["-only-testing:" + target for target in targets])
                self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
                if name == "ui": self.assert_shutdown(commands)
        for target in expected["ui"]:
            source = (root / "UITests" / (target.split("/")[1] + ".swift")).read_text()
            self.assertRegex(source, r"\bfunc\s+" + target.rsplit("/", 1)[1] + r"\s*\(")
        for target in ("CardShowScannerTests/ManualCatalogFilterTestsTypo", expected["ui"][2] + "Typo"):
            rejected, commands, _ = self.run_flow(target=target)
            self.assertEqual(rejected.returncode, 2); self.assertFalse(commands)

    def test_photo_scan_forces_only_its_native_and_ui_cases_and_preserves_runner_safety(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        expected = {
            "native": tuple("CardShowScannerTests/" + name for name in (
                "ScannerDiagnosticsTests", "PhotoScanStateTests", "PhotoScanProviderPreferenceTests",
                "ScannerPageRecoveryTests", "ScannerManualSearchLifecycleTests")),
            "ui": ("CardShowScannerUITests/PhotoScanUITests/testPhotoCaptureRequiresRetakeAndRemembersMode",)
        }
        for name, block in jobs.items():
            self.assertEqual("inputs.job_scope == 'photo_scan'" in block.splitlines()[0], name in expected)
        options = workflow.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertNotIn("          - photo_scan\n", options)
        for name, targets in expected.items():
            with self.subTest(job=name):
                branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = photo_scan \]; then\n'
                                   r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs[name], re.DOTALL)
                self.assertIsNotNone(branch)
                self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                                 ["bash", "scripts/run_ios_tests.sh", *targets])
                result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
                self.assertEqual(result.returncode, 0, result.stderr)
                action = "test" if name == "native" else "test-without-building"
                test = next(row["args"] for row in commands if row["tool"] == "xcodebuild" and row["args"][0] == action)
                self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                                 ["-only-testing:" + target for target in targets])
                self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
                if name == "ui": self.assert_shutdown(commands)
        source = (root / "UITests/PhotoScanUITests.swift").read_text()
        self.assertRegex(source, r"\bfunc\s+testPhotoCaptureRequiresRetakeAndRemembersMode\s*\(")
        for target in ("CardShowScannerTests/PhotoScanStateTestsTypo", expected["ui"][0] + "Typo"):
            rejected, commands, _ = self.run_flow(target=target)
            self.assertEqual(rejected.returncode, 2); self.assertFalse(commands)

    def test_camera_lifecycle_scope_preserves_focused_native_selection(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        targets = tuple("CardShowScannerTests/" + name for name in (
            "ScannerDiagnosticsTests", "DeviceHealthMonitorTests", "DeviceHealthValuesTests",
            "ScannerPageRecoveryTests", "ScannerManualSearchLifecycleTests"))
        branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = camera_lifecycle \]; then\n'
                           r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs["native"], re.DOTALL)
        self.assertIsNotNone(branch)
        self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                         ["bash", "scripts/run_ios_tests.sh", *targets])
        result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.actions(commands), ["test"])
        test = next(row["args"] for row in commands if row["tool"] == "xcodebuild")
        self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                         ["-only-testing:" + target for target in targets])
        self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
        self.assertFalse(any(row["args"][:2] == ["simctl", "create"] for row in commands))
        for job in ("ui", "research_ui", "evidence_ui", "budget_ui"):
            self.assertIn("inputs.test_scope != 'camera_lifecycle'", jobs[job].splitlines()[0])

    def test_log_review_job_uses_only_its_focused_native_and_ui_selections(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        job_blocks = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        expected = {
            "native": tuple("CardShowScannerTests/" + name for name in (
                "ManualCardSearchTests", "OpenAPIMarketPricingTests", "TCGGameRegistryTests", "TCGGamePricingTests",
                "CardEditorPricingTests", "ScannerPageRecoveryTests", "ScannerManualSearchLifecycleTests",
                "NiimbotRollReadCoordinatorTests", "ScannerDiagnosticsTests")),
            "ui": tuple("CardShowScannerUITests/ReviewPresentationUITests/" + name for name in (
                "testSuccessfulManualAddClosesBothSheetsAndCommitsOneRow",
                "testCancellingManualConfirmationKeepsSearchAndDoesNotSave"))
        }
        for name, block in job_blocks.items():
            self.assertEqual("inputs.job_scope == 'log_review'" in block.splitlines()[0], name in expected)
        for name, targets in expected.items():
            with self.subTest(job=name):
                block = job_blocks[name]
                scope = "inputs.job_scope == 'text_assist' && 'text_assist' || " if name == "native" else ""
                scope += "inputs.job_scope == 'scanner_polish' && 'scanner_polish' || "
                scope += "inputs.job_scope == 'photo_scan' && 'photo_scan' || "
                scope += "inputs.job_scope == 'leftover_stock' && " + ("'leftover_stock'" if name == "ui" else "'all'") + " || "
                scope += "inputs.job_scope == 'show_polish' && " + ("'show_polish'" if name == "ui" else "'all'") + " || "
                scope += "inputs.job_scope == 'log_review' && 'log_review' || "
                if name == "ui":
                    scope += "inputs.job_scope == 'ui_diagnostic' && 'ui_diagnostic' || "
                self.assertIn("SCANNER_TEST_SCOPE: ${{ " + scope + "inputs.test_scope || 'all' }}", block)
                branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = log_review \]; then\n'
                                   r'(.*?)(?=\n          (?:elif|else|fi)\b)', block, re.DOTALL)
                self.assertIsNotNone(branch)
                self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                                 ["bash", "scripts/run_ios_tests.sh", *targets])
                result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
                self.assertEqual(result.returncode, 0, result.stderr)
                test = next(row["args"] for row in commands if row["tool"] == "xcodebuild"
                            and row["args"][0] in ("test", "test-without-building"))
                self.assertEqual([arg for arg in test if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + target for target in targets])

    def test_show_polish_routes_exactly_four_cases_and_keeps_runner_safety(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        targets = tuple("CardShowScannerUITests/InventoryLabelsUITests/" + name for name in (
            "testCustomPrintStartsFromPreviewWithoutAQueueStepAndWaitsForFinalAcknowledgement",
            "testSelectedInventoryPrintsDirectlyAndCompletedReceiptsDoNotBlockCustomTags",
            "testDirectPrintFailureRetainsUncertainLabelsAndRequiresCheckingBeforeRetry")) + (
            "CardShowScannerUITests/ReviewPresentationUITests/testMissingPricesRefreshUpdatesUnknownCardAndPreservesKnownZero",)
        for name, block in jobs.items():
            self.assertEqual("inputs.job_scope == 'show_polish'" in block.splitlines()[0], name in ("native", "ui"))
        options = workflow.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertNotIn("          - show_polish\n", options, "The focused job must not create an independent incompatible test scope")
        branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = show_polish \]; then\n'
                           r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs["ui"], re.DOTALL)
        self.assertIsNotNone(branch)
        self.assertEqual(branch.group(1).replace("\\\n", " ").split(),
                         ["bash", "scripts/run_ios_tests.sh", *targets])
        result, commands, _ = self.run_flow(target=targets[0], additional_targets=targets[1:])
        self.assertEqual(result.returncode, 0, result.stderr)
        test = next(row["args"] for row in commands if row["tool"] == "xcodebuild" and row["args"][0] == "test-without-building")
        self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                         ["-only-testing:" + target for target in targets])
        self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
        self.assertEqual(test[test.index("-maximum-test-execution-time-allowance") + 1], "360")
        self.assert_shutdown(commands)
        for target in targets:
            source = (root / "UITests" / (target.split("/")[1] + ".swift")).read_text()
            self.assertRegex(source, r"\bfunc\s+" + target.rsplit("/", 1)[1] + r"\s*\(")
        rejected, rejected_commands, _ = self.run_flow(target=targets[0] + "Typo")
        self.assertEqual(rejected.returncode, 2)
        self.assertFalse(rejected_commands)

    def test_leftover_stock_runs_only_the_focused_case_and_preserves_runner_safety(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", workflow.split("\njobs:\n", 1)[1]))
        target = "CardShowScannerUITests/LeftoverStockFlowTests/testCompletedCountExportsOnlyPositiveAbsoluteStockWithoutChangingInventory"
        for name, block in jobs.items():
            self.assertEqual("inputs.job_scope == 'leftover_stock'" in block.splitlines()[0], name in ("native", "ui"))
        options = workflow.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertNotIn("          - leftover_stock\n", options)
        branch = re.search(r'elif \[ "\$SCANNER_TEST_SCOPE" = leftover_stock \]; then\n'
                           r'(.*?)(?=\n          (?:elif|else|fi)\b)', jobs["ui"], re.DOTALL)
        self.assertIsNotNone(branch)
        self.assertEqual(branch.group(1).split(), ["bash", "scripts/run_ios_tests.sh", target])
        result, commands, _ = self.run_flow(target=target)
        self.assertEqual(result.returncode, 0, result.stderr)
        test = next(row["args"] for row in commands if row["tool"] == "xcodebuild" and row["args"][0] == "test-without-building")
        self.assertEqual([value for value in test if value.startswith("-only-testing:")], ["-only-testing:" + target])
        self.assertFalse(any(value.startswith("-skip-testing:") for value in test))
        self.assert_shutdown(commands)
        source = (root / "UITests/LeftoverStockFlowTests.swift").read_text()
        self.assertRegex(source, r"\bfunc\s+" + target.rsplit("/", 1)[1] + r"\s*\(")
        rejected, rejected_commands, _ = self.run_flow(target=target + "Typo")
        self.assertEqual(rejected.returncode, 2)
        self.assertFalse(rejected_commands)

    def test_total_build_and_test_hangs_are_bounded_and_cleaned(self):
        for action in ("build-for-testing", "test-without-building"):
            with self.subTest(action=action):
                result, commands, log = self.run_flow(SCANNER_HANG_ACTION=action,
                    SCANNER_BUILD_TIMEOUT_SECONDS="0.2", SCANNER_TEST_TIMEOUT_SECONDS="0.2")
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertIn("exceeded total budget", log)
                self.assert_shutdown(commands)
                if action == "build-for-testing":
                    self.assertEqual(self.actions(commands), [action])

    def test_native_test_and_discovery_hangs_are_bounded(self):
        result, commands, _ = self.run_flow(target="CardShowScannerTests",
            SCANNER_HANG_ACTION="test", SCANNER_TEST_TIMEOUT_SECONDS="0.2")
        self.assertEqual(result.returncode, 124)
        self.assertFalse(any(row["args"][:2] == ["simctl", "shutdown"] for row in commands))
        result, commands, _ = self.run_flow(target="CardShowScannerTests",
            SCANNER_HANG_SIMCTL="list", SCANNER_SIMCTL_TIMEOUT_SECONDS="0.2")
        self.assertEqual(result.returncode, 124)
        self.assertFalse(self.actions(commands))

    def test_runner_signals_preserve_status_and_clean_owned_simulator(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            result, commands, _ = self.run_flow(SCANNER_HANG_ACTION="build-for-testing",
                SCANNER_CANCEL_RUNNER=str(sig))
            self.assertEqual(result.returncode, 128 + sig, result.stderr)
            self.assert_shutdown(commands)

    def test_cleanup_hang_does_not_override_test_failure(self):
        # A 200 ms budget can expire before a cold Python fake tool even starts
        # on macOS. Allow interpreter startup while still timing out its 60 s
        # hang; the real runner's production cleanup budget remains unchanged.
        result, commands, _ = self.run_flow(SCANNER_FAIL_ACTION="test-without-building",
            SCANNER_HANG_SIMCTL="shutdown", SCANNER_CLEANUP_TIMEOUT_SECONDS="2")
        self.assertEqual(result.returncode, 19)
        self.assertIn("UI simulator shutdown failed: Command exceeded", result.stderr)
        self.assertIn("Dedicated UI simulator delete completed.", result.stderr)
        self.assert_shutdown(commands)

    def test_local_invocation_without_runner_temp(self):
        result, commands, _ = self.run_flow(SCANNER_UNSET_RUNNER_TEMP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = next(row["args"] for row in commands if row["tool"] == "xcodebuild")
        build_path = arguments[arguments.index("-derivedDataPath") + 1]
        self.assertIn("scanner-tests.", build_path)
        self.assertFalse(Path(build_path).parent.exists())

    def test_invalid_budgets_fail_before_starting_tools(self):
        for value in ("0", "-1", "nan", "inf", "bogus"):
            result, commands, _ = self.run_flow(SCANNER_TEST_TIMEOUT_SECONDS=value)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(commands)

    def test_readiness_timeout_reports_bounded_progress_and_nonzero_status(self):
        failure = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus"], 300,
                                            output=b"Waiting for DataMigrator")
        with patch.object(sys, "argv", ["prepare_ui_simulator.py", "ready",
                                       "10000000-0000-0000-0000-000000000002"]), \
             patch.object(prepare_ui_simulator, "run", side_effect=failure) as run, \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(prepare_ui_simulator.main(), 1)
        self.assertEqual(run.call_args.kwargs["timeout"], 300)
        self.assertIn("Waiting for DataMigrator", errors.getvalue())
        self.assertIn("::error title=UI simulator preparation", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
