import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from annotate_xcode_errors import Annotation, bounded_unique, extract_annotations, main


class XcodeAnnotationTests(unittest.TestCase):
    root = Path('/Users/runner/work/scanner/scanner')

    def test_compiler_and_xctest_diagnostics_keep_repository_locations(self):
        log = '''/Users/runner/work/scanner/scanner/CardShowScanner/ScannerView.swift:42:87: error: Cannot convert value of type 'String'
/Users/runner/work/scanner/scanner/Tests/CustomOfferTests.swift:91: error: -[CustomOfferTests testSavedOffer] : XCTAssertEqual failed: ("70") is not equal to ("90")
'''
        errors = extract_annotations(log, self.root)
        self.assertEqual(len(errors), 2)
        self.assertEqual((errors[0].file, errors[0].line, errors[0].column), ('CardShowScanner/ScannerView.swift', 42, 87))
        self.assertEqual((errors[1].file, errors[1].line, errors[1].column), ('Tests/CustomOfferTests.swift', 91, None))
        self.assertIn('XCTAssertEqual failed', errors[1].message)

    def test_annotations_escape_untrusted_workflow_command_data_and_properties(self):
        command = Annotation('first%\r\n::warning::second', 'Tests/a,b:%.swift', 5, 2).workflow_command()
        self.assertIn('file=Tests/a%2Cb%3A%25.swift', command)
        self.assertIn('line=5,col=2', command)
        self.assertTrue(command.endswith('first%25%0D%0A::warning::second'))
        self.assertEqual(command.count('\n'), 0)
        self.assertEqual(command.count('\r'), 0)

    def test_duplicate_errors_and_output_are_bounded(self):
        same = Annotation('duplicate', 'App.swift', 1, 2)
        errors = bounded_unique([same, same] + [Annotation(str(n)) for n in range(50)])
        self.assertEqual(len(errors), 30)
        self.assertEqual(errors.count(same), 1)
        self.assertLessEqual(len(Annotation('x' * 9000).workflow_command()), 2100)
        self.assertEqual(len(bounded_unique(errors, 2)), 2)

    def test_general_and_testing_failed_errors_are_available_without_source_paths(self):
        errors = extract_annotations('xcodebuild: error: Unable to find a destination matching the provided destination specifier.\n', self.root)
        self.assertEqual(errors, [Annotation('Unable to find a destination matching the provided destination specifier.')])
        summary = extract_annotations('Testing failed:\n    Cannot find type OfferLine in scope\n    Testing cancelled because the build failed.\n\n** TEST FAILED **\n', self.root)
        self.assertEqual(len(summary), 1)
        self.assertIn('Cannot find type OfferLine', summary[0].message)
        self.assertEqual(len(extract_annotations('** TEST FAILED **\n', self.root)), 1)

    def test_test_startup_runtime_failures_preserve_the_abort_reason(self):
        diagnostics = [
            "Could not cast value of type '(ScannerTests.OfferTests) -> @Swift.MainActor () -> ()' to '(ScannerTests.OfferTests) -> () -> ()'.",
            'Fatal error: Unexpectedly found nil while unwrapping an Optional value',
            "Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'Invalid test invocation'",
        ]
        for diagnostic in diagnostics:
            with self.subTest(diagnostic=diagnostic):
                log = '2026-10-23 10:00:00.000 ScannerTests-Runner[123:456] *** ' + diagnostic + '\n** TEST FAILED **\n'
                self.assertEqual(extract_annotations(log, self.root), [Annotation(diagnostic)])

    def test_xctest_crash_summaries_are_available_before_tests_start(self):
        diagnostics = [
            'Test crashed with signal abrt before starting test execution.))',
            'XCTest (123) crashed with signal SIGABRT.',
            'Test runner crashed before running any tests.',
        ]
        for diagnostic in diagnostics:
            with self.subTest(diagnostic=diagnostic):
                self.assertEqual(extract_annotations('    ' + diagnostic + '\n', self.root), [Annotation(diagnostic)])
        general = 'Failed to establish communication. (Test crashed with signal abrt before starting test execution.))'
        self.assertEqual(extract_annotations('xcodebuild: error: ' + general + '\n', self.root), [Annotation(general)])

    def test_runtime_failure_prefix_does_not_publish_external_source_paths(self):
        errors = extract_annotations('/Users/runner/Library/Developer/DerivedData/Generated.swift:2: Fatal error: Invalid invocation\n', self.root)
        self.assertEqual(errors, [Annotation('Fatal error: Invalid invocation')])

    def test_cli_deduplicates_and_escapes_runtime_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'native.log'
            diagnostic = 'Fatal error: 100% ::warning:: untrusted detail'
            log.write_text('\x1b[31m' + diagnostic + '\x1b[0m\n' + diagnostic + '\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main([str(log)])
            self.assertEqual(output.getvalue(), '::error title=Xcode native check::Fatal error: 100%25 ::warning:: untrusted detail\n')

    def test_outside_build_paths_are_not_published_as_repository_files(self):
        errors = extract_annotations('/Users/runner/Library/Developer/DerivedData/Generated.swift:2:3: error: Generated failure\n../outside.swift:4: error: Outside failure\n', self.root)
        self.assertEqual(len(errors), 2)
        self.assertIsNone(errors[0].file)
        self.assertIn('Generated.swift:2:3', errors[0].message)
        self.assertIsNone(errors[1].file)
        self.assertNotIn('Users/runner', errors[0].message)

    def test_cli_success_logs_emit_nothing_and_failed_missing_logs_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'native.log'
            log.write_text('** TEST SUCCEEDED **\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(log)]), 0)
            self.assertEqual(output.getvalue(), '')
            with contextlib.redirect_stdout(output):
                main([str(log), '--fallback', 'xcodebuild failed with exit 65'])
            self.assertIn('xcodebuild failed with exit 65', output.getvalue())
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main([str(Path(directory) / 'missing.log')])
            self.assertIn('missing or unreadable: missing.log', output.getvalue())

    def test_cli_deduplicates_multiple_logs_and_strips_ansi(self):
        with tempfile.TemporaryDirectory() as directory:
            one, two = Path(directory) / 'one.log', Path(directory) / 'two.log'
            diagnostic = '\x1b[31mCardShowScanner/ScannerView.swift:7:2: error: bad argument\x1b[0m\n'
            one.write_text(diagnostic); two.write_text(diagnostic)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main([str(one), str(two), '--repo-root', str(self.root)])
            self.assertEqual(output.getvalue().count('::error '), 1)
            self.assertIn('file=CardShowScanner/ScannerView.swift,line=7,col=2', output.getvalue())
            self.assertNotIn('\x1b', output.getvalue())


if __name__ == '__main__':
    unittest.main()
