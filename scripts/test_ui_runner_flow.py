"""Exercise runner ordering and failure propagation without Xcode or a device."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
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
    def run_flow(self, target="CardShowScannerUITests", **settings):
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
            result = subprocess.run(["bash", "scripts/run_ios_tests.sh", target], cwd=root,
                                    env=environment, text=True, capture_output=True, timeout=20)
            commands = [json.loads(line) for line in events.read_text().splitlines()]
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
