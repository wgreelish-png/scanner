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
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prepare_ui_simulator


FAKE_TOOL = r'''
import json, os, pathlib, sys
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["SCANNER_EVENT_LOG"], "a") as output:
    output.write(json.dumps({"tool": tool, "args": args}) + "\n")
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
        "isAvailable": True, "runtimeRoot": os.environ["RUNNER_TEMP"] + "/RuntimeRoot"}]}))
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
            for name in ("run_ios_tests.sh", "prepare_ui_simulator.py"):
                shutil.copyfile(Path(__file__).parent / name, scripts / name)
            for name in ("xcrun", "xcodebuild"):
                executable = binary / name
                executable.write_text("#!" + sys.executable + "\n" + FAKE_TOOL)
                executable.chmod(0o755)
            events = root / "events.jsonl"
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               RUNNER_TEMP=directory, SCANNER_EVENT_LOG=str(events), **settings)
            result = subprocess.run(["bash", "scripts/run_ios_tests.sh", target, *additional_targets], cwd=root,
                                    env=environment, text=True, capture_output=True, timeout=20)
            commands = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
            log = (root / "NativeTests.log").read_text() if (root / "NativeTests.log").exists() else ""
            return result, commands, log

    def actions(self, commands):
        return [row["args"][0] for row in commands if row["tool"] == "xcodebuild"]

    def assert_shutdown(self, commands):
        self.assertEqual(commands[-1]["args"],
                         ["simctl", "shutdown", "10000000-0000-0000-0000-000000000002"])

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
        seconds_per_case = int(ui_arguments[ui_arguments.index("-maximum-test-execution-time-allowance") + 1])
        self.assertGreaterEqual(budgets.pop("ui"), math.ceil(selected_cases * seconds_per_case / 60) + 30)
        budget_classes = set(re.findall(r"CardShowScannerUITests/(\w+)", job_blocks["budget_ui"]))
        self.assertTrue(budget_classes)
        budget_cases = sum(class_cases[name] for name in budget_classes)
        self.assertGreaterEqual(budgets.pop("budget_ui"), math.ceil(budget_cases * seconds_per_case / 60) + 30)
        self.assertEqual(budgets, {"native": 90, "research_ui": 120, "evidence_ui": 120,
                                   "release": 30})

        concurrency = workflow.split("\nconcurrency:\n", 1)[1].split("\njobs:\n", 1)[0]
        group = re.search(r"(?m)^  group: (.+)$", concurrency).group(1)
        for dimension in ("${{ inputs.job_scope || 'all' }}", "${{ inputs.test_scope || 'all' }}"):
            self.assertIn(dimension, group)
        self.assertRegex(concurrency, r"(?m)^  cancel-in-progress: false$")
        self.assertIn("python3 -m unittest discover -s scripts -p 'test_ui_runner_flow.py'", job_blocks["ui"])
        self.assertLess(job_blocks["ui"].index("Validate UI runner timing"),
                        job_blocks["ui"].index("Build and run UI regression tests"))
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
