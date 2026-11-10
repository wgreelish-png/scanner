"""Portable real-process regressions for deadlines and cancellation ownership."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import process_budget


class ProcessBudgetTests(unittest.TestCase):
    def test_validation(self):
        for value in (0, -1, 'nan', 'inf', 86401):
            with self.assertRaises(ValueError):
                process_budget.seconds(value)

    def test_exit_status(self):
        result = process_budget.run([sys.executable, '-c', 'raise SystemExit(19)'], timeout=2)
        self.assertEqual(result.returncode, 19)

    def test_inherited_output_pipe_is_bounded(self):
        code = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"])'
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            process_budget.run([sys.executable, '-c', code], timeout=.2, capture_output=True)
        self.assertLess(time.monotonic() - start, 3)

    def test_signals_kill_only_owned_children(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'ready'
            survivor = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
            try:
                for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    marker.unlink(missing_ok=True)
                    code = ('import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                            f'pathlib.Path({str(marker)!r}).write_text("ready"); time.sleep(60)')
                    runner = subprocess.Popen([sys.executable, str(Path(process_budget.__file__)),
                                               '--seconds', '60', '--', sys.executable, '-c', code])
                    try:
                        deadline = time.monotonic() + 3
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue(marker.exists())
                        runner.send_signal(sig)
                        self.assertEqual(runner.wait(timeout=3), 128 + sig)
                        self.assertIsNone(survivor.poll())
                    finally:
                        if runner.poll() is None:
                            runner.kill(); runner.wait()
            finally:
                survivor.kill(); survivor.wait()


if __name__ == '__main__':
    unittest.main()
