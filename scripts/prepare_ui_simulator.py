#!/usr/bin/env python3
"""Prepare only a new UI-test simulator; never reset an existing device."""

import argparse
import json
import re
import subprocess
import sys
import uuid
from dataclasses import dataclass


MODELS = (
    "iPhone 16 Pro", "iPhone 16", "iPhone 17 Pro", "iPhone 17",
    "iPhone 15 Pro", "iPhone 15", "iPhone 14 Pro", "iPhone 14",
    "iPhone 13 Pro", "iPhone 13",
)


@dataclass(frozen=True)
class Selection:
    name: str
    device_type: str
    runtime: str
    version: tuple[int, ...]


def version_key(value: tuple[int, ...]) -> tuple[int, ...]:
    return value + (0,) * (4 - len(value))


def select_device(devices: dict, runtimes: dict, sdk_version: str | None = None) -> Selection:
    """Choose a normal-size iPhone from actual available type/runtime pairs."""
    if sdk_version is not None and not re.fullmatch(r"\d+(?:\.\d+){0,3}", sdk_version):
        raise ValueError("The selected Xcode did not report a simulator SDK version.")
    maximum = tuple(int(part) for part in sdk_version.split(".")) if sdk_version else None
    available = {}
    for runtime in runtimes.get("runtimes", []):
        identifier, version = runtime.get("identifier", ""), runtime.get("version", "")
        if runtime.get("isAvailable") is not True:
            continue
        if not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+(?:-\d+){0,3}", identifier):
            continue
        if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", version):
            continue
        numeric = tuple(int(part) for part in version.split("."))
        if numeric[0] >= 17 and (maximum is None or version_key(numeric) <= version_key(maximum)):
            available[identifier] = numeric

    candidates = []
    for runtime, rows in devices.get("devices", {}).items():
        if runtime not in available:
            continue
        for device in rows:
            name = device.get("name")
            if device.get("isAvailable") is not True or name not in MODELS:
                continue
            # Older simctl JSON can omit the type ID. Names are allowlisted;
            # their type/runtime pair already exists on this host.
            expected_type = "com.apple.CoreSimulator.SimDeviceType." + name.replace(" ", "-")
            device_type = device.get("deviceTypeIdentifier", expected_type)
            if device_type != expected_type:
                continue
            candidates.append(Selection(name, device_type, runtime, available[runtime]))
    if not candidates:
        raise ValueError("No supported, available iPhone/iOS pair for UI tests (iOS 17+).")
    newest = max(version_key(candidate.version) for candidate in candidates)
    return min((candidate for candidate in candidates if version_key(candidate.version) == newest),
               key=lambda candidate: (MODELS.index(candidate.name), candidate.runtime))


def run(*arguments: str, timeout: int = 30) -> str:
    return subprocess.run(arguments, check=True, text=True, capture_output=True,
                          timeout=timeout).stdout.strip()


def checked_id(value: str) -> str:
    return str(uuid.UUID(value)).upper()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create", "boot", "shutdown"))
    parser.add_argument("device_id", nargs="?")
    arguments = parser.parse_args()
    stage = "device selection"
    try:
        if arguments.command == "create":
            selection = select_device(
                json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j")),
                json.loads(run("xcrun", "simctl", "list", "runtimes", "-j")),
                run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
            )
            stage = "device creation"
            name = "Scanner UI Tests " + uuid.uuid4().hex[:12]
            device_id = checked_id(run("xcrun", "simctl", "create", name,
                                       selection.device_type, selection.runtime))
            print(f"Dedicated UI simulator: {selection.name}, iOS {'.'.join(map(str, selection.version))}",
                  file=sys.stderr)
            print(device_id)
        else:
            if not arguments.device_id:
                raise ValueError("An owned UI simulator ID is required.")
            device_id = checked_id(arguments.device_id)
            if arguments.command == "boot":
                stage = "boot"
                print("Booting dedicated UI simulator and waiting for readiness.", file=sys.stderr)
                run("xcrun", "simctl", "boot", device_id)
                stage = "boot readiness"
                run("xcrun", "simctl", "bootstatus", device_id, "-b", timeout=120)
                print("Dedicated UI simulator is ready.", file=sys.stderr)
            else:
                stage = "shutdown"
                run("xcrun", "simctl", "shutdown", device_id)
                print("Stopped dedicated UI simulator; its data remains available for diagnostics.", file=sys.stderr)
    except (ValueError, KeyError, TypeError, AttributeError, OSError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        # All commands and names above are local preparation, never credentials.
        if isinstance(error, subprocess.CalledProcessError):
            detail = (error.stderr or "simctl failed").strip()[:1_000]
        else:
            detail = str(error)[:1_000]
        message = f"UI simulator {stage} failed: {detail}"
        print(message, file=sys.stderr)
        # GitHub summaries remain useful when no XCTest log was created yet.
        escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        severity = "warning" if arguments.command == "shutdown" else "error"
        print(f"::{severity} title=UI simulator preparation::{escaped}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
