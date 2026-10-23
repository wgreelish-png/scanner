import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from report_simulator_crash import ips_annotations, legacy_annotations, main


class SimulatorCrashReportTests(unittest.TestCase):
    def ips(self, payload, process='CardShowScanner'):
        return json.dumps({'app_name': process}) + '\n' + json.dumps(payload)

    def run_reporter(self, *paths):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main([str(path) for path in paths]), 0)
        return output.getvalue()

    def test_consecutive_ips_json_reports_cast_and_dyld_reasons_only(self):
        payload = {
            'procName': 'CardShowScanner',
            'asi': {'libswiftCore.dylib': ['Could not cast value of type actor test method']},
            'applicationSpecificInformation': 'abort() called',
            'exception': {'type': 'EXC_CRASH', 'signal': 'SIGABRT', 'codes': '0x0, 0x0', 'private': 'DO_NOT_PUBLISH'},
            'termination': {
                'namespace': 'DYLD', 'code': 1, 'indicator': 'Library missing',
                'reasons': ['Library not loaded: @rpath/XCTest.framework/XCTest', 'Reason: image not found'],
                'byProc': 'DO_NOT_PUBLISH', 'details': ['DO_NOT_PUBLISH'],
            },
            'threads': [{'frames': ['DO_NOT_PUBLISH']}],
            'procPath': '/DO_NOT_PUBLISH/private/app',
            'environment': {'TOKEN': 'DO_NOT_PUBLISH'},
            'arguments': ['DO_NOT_PUBLISH'],
        }
        messages = '\n'.join(annotation.message for annotation in ips_annotations(self.ips(payload), 'report.ips'))
        self.assertIn('Could not cast value', messages)
        self.assertIn('abort() called', messages)
        self.assertIn('@rpath/XCTest.framework/XCTest', messages)
        self.assertIn('Reason: image not found', messages)
        self.assertIn('namespace=DYLD; code=1; indicator=Library missing', messages)
        self.assertIn('type=EXC_CRASH; signal=SIGABRT; codes=0x0, 0x0', messages)
        self.assertNotIn('DO_NOT_PUBLISH', messages)

    def test_legacy_sections_stop_before_threads_and_other_private_sections(self):
        report = '''Process: CardShowScanner [123]
Application Specific Information:
Could not cast value of type test invocation
Thread 0 Crashed:
DO_NOT_PUBLISH_STACK

Dyld Error Message:
  Library not loaded: @rpath/XCTest.framework/XCTest
  Referenced from: test host
  Reason: image not found
Binary Images:
DO_NOT_PUBLISH_IMAGES

Termination Reason: Namespace DYLD, Code 1 Library missing
Environment Variables:
DO_NOT_PUBLISH_TOKEN
'''
        messages = '\n'.join(annotation.message for annotation in legacy_annotations(report, 'export.crash'))
        self.assertIn('Could not cast value', messages)
        self.assertIn('Library not loaded: @rpath/XCTest.framework/XCTest', messages)
        self.assertIn('Reason: image not found', messages)
        self.assertIn('Termination Reason: Namespace DYLD, Code 1 Library missing', messages)
        self.assertNotIn('DO_NOT_PUBLISH', messages)

    def test_report_identity_overrides_misleading_target_filename(self):
        wrong = self.ips({'procName': 'OtherProcess', 'asi': 'unrelated crash'})
        self.assertEqual(ips_annotations(wrong, 'CardShowScanner-2026.ips'), [])
        self.assertEqual(ips_annotations(json.dumps({'asi': 'unrelated crash'}), 'OtherProcess.ips'), [])
        legacy = 'Process: OtherProcess [123]\nTermination Reason: unrelated crash\n'
        self.assertEqual(legacy_annotations(legacy, 'CardShowScanner-2026.crash'), [])
        target = json.dumps({'procName': 'CardShowScannerTests-Runner', 'asi': 'target runner crashed'})
        self.assertEqual(len(ips_annotations(target, 'nested-export.ips')), 1)

    def test_legacy_runtime_reason_prefixes_are_not_section_boundaries(self):
        report = '''Process: CardShowScanner [123]
Application Specific Information:
Fatal error: Invalid test invocation
dyld[123]: Library not loaded: @rpath/XCTest.framework/XCTest
Arguments:
DO_NOT_PUBLISH
'''
        messages = '\n'.join(annotation.message for annotation in legacy_annotations(report, 'report.crash'))
        self.assertIn('Fatal error: Invalid test invocation', messages)
        self.assertIn('dyld[123]: Library not loaded:', messages)
        self.assertNotIn('DO_NOT_PUBLISH', messages)

    def test_cli_recurses_multiple_roots_and_ignores_old_or_unrelated_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = root / 'diagnostics', root / 'export' / 'nested'
            first.mkdir(); second.mkdir(parents=True)
            (first / 'CardShowScanner-current.ips').write_text(self.ips({'asi': 'current failure'}))
            (second / 'exported.ips').write_text(self.ips({'asi': 'exported failure'}, 'CardShowScannerTests'))
            (second / 'OtherProcess.ips').write_text(self.ips({'asi': 'DO_NOT_PUBLISH'}, 'OtherProcess'))
            old = first / 'CardShowScanner-old.ips'
            old.write_text(self.ips({'asi': 'DO_NOT_PUBLISH_STALE'}))
            os.utime(old, (time.time() - 3600, time.time() - 3600))
            output = self.run_reporter(first, root / 'export')
            self.assertIn('current failure', output)
            self.assertIn('exported failure', output)
            self.assertNotIn('DO_NOT_PUBLISH', output)
            self.assertEqual(output.count('::error '), 2)

    def test_cli_missing_or_malformed_reports_emit_notices_without_fake_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = self.run_reporter(root / 'missing')
            self.assertIn('::notice ', missing)
            self.assertNotIn('::error ', missing)
            (root / 'CardShowScanner-broken.ips').write_text('{"app_name":"CardShowScanner"}\n{"asi":')
            malformed = self.run_reporter('--root', root)
            self.assertIn('Unreadable or malformed matching reports: 1', malformed)
            self.assertNotIn('::error ', malformed)

    def test_cli_bounds_deduplicates_and_escapes_public_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            detail = 'cast 100%\n::warning::injected'
            payload = {'asi': [detail] * 20 + ['x' * 9000], 'termination': {'reasons': ['Library missing']}}
            text = self.ips(payload)
            (root / 'CardShowScanner-one.ips').write_text(text)
            (root / 'CardShowScanner-two.ips').write_text(text)
            output = self.run_reporter(root)
            self.assertEqual(output.count('::error '), 2)
            self.assertIn('cast 100%25%0A::warning::injected', output)
            self.assertIn('Library missing', output)
            (root / 'CardShowScanner-long.ips').write_text(self.ips({'asi': 'x' * 9000}))
            bounded = self.run_reporter(root, '--max-errors', 1)
            self.assertEqual(bounded.count('::error '), 1)
            self.assertLessEqual(len(bounded), 2200)


if __name__ == '__main__':
    unittest.main()
