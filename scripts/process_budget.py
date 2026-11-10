#!/usr/bin/env python3
"""Bound an owned command and its process group, including inherited output pipes."""
from __future__ import annotations
import argparse
import math
import os
import signal
import subprocess
import sys


def seconds(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0 or value > 86400:
        raise ValueError("Command budgets must be finite seconds in (0, 86400].")
    return value


def run(arguments, *, timeout, check=False, text=True, capture_output=False, **kwargs):
    timeout = seconds(timeout)
    process = None
    previous = {}

    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    def kill_group(sig):
        if process is not None:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass

    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        process = subprocess.Popen(arguments, start_new_session=True, text=text,
                                   **({"stdout": subprocess.PIPE, "stderr": subprocess.PIPE} if capture_output else {}), **kwargs)
        stdout, stderr = process.communicate(timeout=timeout)
        result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
    finally:
        # Kill only this invocation's group, even if the direct child exited and
        # left a worker behind. SIGKILL avoids adding an unbounded grace period.
        kill_group(signal.SIGKILL)
        if process is not None:
            process.wait(timeout=5)
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", required=True)
    parser.add_argument("--log")
    parser.add_argument("--append", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        budget = seconds(args.seconds)
    except ValueError as error:
        parser.error(str(error))
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A command is required")
    # Redirect directly to a file: no unowned tee process or pipe can keep the
    # runner alive after the command budget expires. Logs remain artifact-ready.
    output = open(args.log, "a" if args.append else "w") if args.log else None
    try:
        result = run(command, timeout=budget, **({"stdout": output, "stderr": subprocess.STDOUT} if output else {}))
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    except subprocess.TimeoutExpired:
        message = f"Command exceeded total budget of {budget:g} seconds: {command[0]}"
        print(message, file=sys.stderr)
        if output:
            print(message, file=output, flush=True)
        return 124
    finally:
        if output:
            output.close()


if __name__ == "__main__":
    raise SystemExit(main())
