import contextlib
import io
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

import prepare_ui_simulator
from prepare_ui_simulator import select_device


class SelectUISimulatorTests(unittest.TestCase):
    def runtime(self, version="18.5", available=True):
        return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
                "version": version, "isAvailable": available}

    def device(self, name="iPhone 16 Pro", available=True):
        return {"name": name, "isAvailable": available,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + name.replace(" ", "-")}

    def select(self, devices, runtimes):
        return select_device({"devices": devices}, {"runtimes": runtimes})

    def test_selection_is_independent_of_device_and_runtime_listing_order(self):
        runtime = self.runtime()
        choices = [self.device("iPhone 16 Pro Max"), self.device("iPhone SE"),
                   self.device("iPhone 16"), self.device("iPhone 16 Pro")]
        for rows in [choices, list(reversed(choices))]:
            selected = self.select({runtime["identifier"]: rows}, [runtime])
            self.assertEqual(selected.name, "iPhone 16 Pro")
            self.assertEqual(selected.runtime, runtime["identifier"])

    def test_newest_available_compatible_pair_wins_over_old_preferred_model(self):
        old, newest = self.runtime("18.5"), self.runtime("26.1")
        selected = self.select({old["identifier"]: [self.device()],
                                newest["identifier"]: [self.device("iPhone 17 Pro")]}, [newest, old])
        self.assertEqual(selected.name, "iPhone 17 Pro")
        self.assertEqual(selected.version, (26, 1))

    def test_selected_xcode_sdk_excludes_newer_installed_runtime(self):
        supported, newer = self.runtime("18.5"), self.runtime("26.1")
        devices = {"devices": {supported["identifier"]: [self.device()],
                               newer["identifier"]: [self.device("iPhone 17 Pro")]}}
        selected = select_device(devices, {"runtimes": [newer, supported]}, "18.5")
        self.assertEqual(selected.runtime, supported["identifier"])
        with self.assertRaises(ValueError):
            select_device({"devices": {newer["identifier"]: [self.device()]}}, {"runtimes": [newer]}, "18.5")
        with self.assertRaises(ValueError):
            select_device(devices, {"runtimes": [supported]}, "unknown")

    def test_runtime_and_sdk_trailing_zero_versions_are_equivalent(self):
        runtime = self.runtime("18.5.0")
        selected = select_device({"devices": {runtime["identifier"]: [self.device()]}},
                                 {"runtimes": [runtime]}, "18.5")
        self.assertEqual(selected.runtime, runtime["identifier"])

    def test_unavailable_and_non_ios_and_unsupported_devices_do_not_become_candidates(self):
        available, unavailable, too_old = self.runtime(), self.runtime("26.1", False), self.runtime("16.4")
        tv = {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-1", "version": "26.1", "isAvailable": True}
        selected = self.select({available["identifier"]: [self.device("iPhone 16 Pro", False), self.device("iPhone 15")],
                                unavailable["identifier"]: [self.device()],
                                too_old["identifier"]: [self.device()],
                                tv["identifier"]: [self.device()]}, [tv, unavailable, too_old, available])
        self.assertEqual(selected.name, "iPhone 15")
        self.assertEqual(selected.runtime, available["identifier"])

    def test_empty_or_unknown_or_mismatched_pair_fails_instead_of_using_arbitrary_device(self):
        runtime = self.runtime()
        wrong_type = self.device()
        wrong_type["deviceTypeIdentifier"] = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"
        for rows in [[], [self.device("iPhone 16 Pro Max")], [self.device("Arbitrary renamed phone")], [wrong_type]]:
            with self.assertRaises(ValueError):
                self.select({runtime["identifier"]: rows}, [runtime])

    def test_older_simctl_json_can_use_the_allowlisted_existing_device_name(self):
        runtime, device = self.runtime(), self.device()
        del device["deviceTypeIdentifier"]
        selected = self.select({runtime["identifier"]: [device]}, [runtime])
        self.assertEqual(selected.device_type, "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro")

    def test_cold_discovery_and_device_creation_have_bounded_startup_budgets(self):
        runtime = self.runtime()
        device_id = "10000000-0000-0000-0000-000000000002"
        calls = []

        def cold_command(arguments, *, timeout, **options):
            calls.append((arguments, timeout))
            operation = arguments[1:3]
            if operation == ("simctl", "list"):
                # Simulate a cold CoreSimulator service that would exceed the
                # old 30-second deadline, without sleeping in a portable test.
                required = 45
                value = ({"devices": {runtime["identifier"]: [self.device()]}}
                         if arguments[3] == "devices" else {"runtimes": [runtime]})
                output = json.dumps(value)
            elif operation == ("simctl", "create"):
                required, output = 75, device_id
            else:
                required, output = 0, "18.5"
            if timeout < required:
                raise subprocess.TimeoutExpired(arguments, timeout)
            self.assertLessEqual(timeout, 120, "Cold setup must remain bounded")
            return subprocess.CompletedProcess(arguments, 0, stdout=output)

        with patch.object(sys, "argv", ["prepare_ui_simulator.py", "create"]), \
             patch.object(prepare_ui_simulator.subprocess, "run", side_effect=cold_command), \
             contextlib.redirect_stdout(io.StringIO()) as output, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(prepare_ui_simulator.main(), 0)
        self.assertEqual(output.getvalue().strip(), device_id)
        self.assertEqual([timeout for arguments, timeout in calls if arguments[1:3] == ("simctl", "list")],
                         [90, 90])
        self.assertEqual(calls[-1][0][1:3], ("simctl", "create"))
        self.assertEqual(calls[-1][1], 120)

    def test_cold_boot_request_has_a_bounded_budget_and_does_not_reset_the_device(self):
        device_id = "10000000-0000-0000-0000-000000000002"
        calls = []

        def cold_boot(arguments, *, timeout, **options):
            calls.append((arguments, timeout))
            if timeout < 45:
                raise subprocess.TimeoutExpired(arguments, timeout)
            self.assertLessEqual(timeout, 120)
            return subprocess.CompletedProcess(arguments, 0, stdout="")

        with patch.object(sys, "argv", ["prepare_ui_simulator.py", "boot", device_id]), \
             patch.object(prepare_ui_simulator.subprocess, "run", side_effect=cold_boot), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(prepare_ui_simulator.main(), 0)
        self.assertEqual(calls, [(("xcrun", "simctl", "boot", device_id), 90)])


if __name__ == "__main__":
    unittest.main()
