import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from report_xcode_test_summary import main, notice, summaries, MAX_AGGREGATES, MAX_FAILED_CASES, MAX_MIGRATION_CASES, RESTART


class XcodeTestSummaryTests(unittest.TestCase):
    def test_native_and_ui_aggregate_counts_keep_observed_results(self):
        log = '''Test Suite 'ListOutcomeTests' passed at 2026-10-27 12:00:00.
    Executed 12 tests, with 0 failures (0 unexpected) in 1.23 (1.25) seconds
Test Suite 'CardShowScannerTests.xctest' passed at 2026-10-27 12:00:00.
    Executed 188 tests, with 0 failures (0 unexpected) in 2.1 (2.2) seconds
Test Suite 'All tests' passed at 2026-10-27 12:00:00.
    Executed 188 tests, with 0 failures (0 unexpected) in 2.1 (2.2) seconds
Test Suite 'CardShowScannerUITests.xctest' failed at 2026-10-27 12:01:00.
    Executed 3 tests, with 1 failure (0 unexpected) in 2.1 (2.2) seconds
'''
        output = summaries(log)
        self.assertEqual(len(output), 3)
        self.assertIn('CardShowScannerTests.xctest passed; executed 188 tests, 0 failures (0 unexpected)', output[0])
        self.assertIn('CardShowScannerUITests.xctest failed; executed 3 tests, 1 failures', output[-1])
        self.assertFalse(any('executed 12' in item for item in output))

    def test_migration_cases_use_explicit_objc_and_parallel_swift_results(self):
        log = '''Test Case '-[CardShowScannerTests.CardShowScannerTests testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch]' passed (0.123 seconds).
Test case 'ListOutcomeTests.testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers()' passed on 'iPhone - CardShowScanner (123)' (0.123 seconds)
Test Case '-[CardShowScannerTests.OtherTests testUnrelated]' passed (0.1 seconds).
'''
        output = summaries(log)
        self.assertEqual(len(output), 3)
        self.assertIn('test completion is unverified', output[0])
        self.assertTrue(any('testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch passed.' in item for item in output))
        self.assertTrue(any('testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers passed.' in item for item in output))
        self.assertFalse(any('testUnrelated' in item for item in output))

    def test_migration_failure_and_skipped_are_never_passes(self):
        log = '''Test Case '-[Tests.MigrationTests testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch]' failed (0.1 seconds).
Test case 'MigrationTests.testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers()' skipped on 'iPhone' (0.1 seconds)
'''
        output = summaries(log)
        self.assertTrue(any('migration case:' in item and 'failed.' in item for item in output))
        self.assertTrue(any('migration case:' in item and 'skipped.' in item for item in output))
        self.assertTrue(any('failed case:' in item for item in output))
        self.assertFalse(any('passed' in item for item in output))

    def test_unstructured_logs_and_runtime_errors_do_not_invent_counts_or_passes(self):
        for log in ['', '** TEST SUCCEEDED **', 'error: Attempting to retrieve a version checksum',
                    'Executed 188 tests, with 0 failures (0 unexpected) in 0.1 seconds',
                    "Test Suite 'All tests' started at 12:00\n Executed 188 tests, with 0 failures (0 unexpected) in 0.1 seconds"]:
            with self.subTest(log=log):
                self.assertEqual(summaries(log), ['No XCTest aggregate execution counts found; test completion is unverified from this log.'])

    def test_failed_cases_are_deduplicated_and_output_is_bounded(self):
        case = "Test Case '-[Tests.ExampleTests testBroken]' failed (0.1 seconds).\n"
        log = case * 3 + ''.join(f"Test Case '-[Tests.ExampleTests testBroken{i}]' failed (0.1 seconds).\n" for i in range(30))
        output = summaries(log)
        self.assertEqual(sum('failed case:' in item for item in output), MAX_FAILED_CASES)
        self.assertEqual(sum(item.endswith('ExampleTests.testBroken.') for item in output), 1)
        self.assertIn('21 additional failed XCTest cases omitted', output[-1])
        aggregates = ''.join(f"Test Suite 'All tests' passed at 12:00\n Executed {i} tests, with 0 failures (0 unexpected) in 0.1 seconds\n" for i in range(20))
        output = summaries(aggregates)
        self.assertEqual(sum('XCTest aggregate:' in item for item in output), MAX_AGGREGATES)
        self.assertIn('executed 19 tests', [item for item in output if 'XCTest aggregate:' in item][-1])

    def test_real_execution_allowance_and_restart_records_are_reported_separately(self):
        # Record formats from Actions run 42348609106, job 128331705971.
        timeout = ("Test Case '-[CardShowScannerUITests.InventoryLabelsUITests testInventoryPrintOrderSortsNumericPricesAndRemembersSelection]' "
                   "exceeded execution time allowance of 6 minutes. The test may have hung; check Xcode's test report for additional diagnostics.")
        output = summaries(timeout + '\n' + RESTART + '\n' + RESTART)
        self.assertTrue(any('timed-out case result records: 1;' in item for item in output))
        self.assertTrue(any('runner restart records: 2 ' in item for item in output))
        self.assertEqual(sum('failed case:' in item for item in output), 1)
        self.assertTrue(any('InventoryLabelsUITests.testInventoryPrintOrderSortsNumericPricesAndRemembersSelection.' in item for item in output))
        self.assertFalse(any(' passed' in item for item in output))

    def test_zero_test_success_is_not_reported_as_a_pass(self):
        log = "Test Suite 'Selected tests' passed at 12:00\n Executed 0 tests, with 0 failures (0 unexpected) in 0.1 seconds\n"
        output = summaries(log + RESTART)
        self.assertTrue(any('executed 0 tests' in item for item in output))
        self.assertTrue(any('do not verify test execution or success' in item for item in output))
        self.assertFalse(any(' passed' in item for item in output))

    def test_timeout_then_retry_pass_does_not_erase_migration_failure(self):
        prefix = "Test Case '-[Tests.MigrationTests testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch]' "
        output = summaries(prefix + 'timed out (6 seconds).\n' + prefix + 'passed (1 second).')
        migration = next(item for item in output if 'migration case:' in item)
        self.assertIn('timed out (multiple outcomes recorded)', migration)
        self.assertNotIn('passed', migration)
        self.assertEqual(sum('failed case:' in item for item in output), 1)

    def test_runtime_timeout_diagnostics_do_not_invent_case_outcomes(self):
        log = """error: test timed out
[General] CA Telemetry timedout after 20 seconds due to app launch
A diagnostic mentioning Restarting after unexpected exit, crash, or test timeout
Test Case '-[Tests.Example testName]' exceeded execution time allowance of unknown duration
Test Suite 'All tests' passed at 12:00
unrelated diagnostic
 Executed 2 tests, with 0 failures
"""
        self.assertEqual(summaries(log), ['No XCTest aggregate execution counts found; test completion is unverified from this log.'])

    def test_timeout_and_migration_notice_output_is_bounded(self):
        log = ''.join(f"Test Case '-[Tests.Migration{i} testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch]' exceeded execution time allowance of 360 seconds.\n{RESTART}\n" for i in range(100))
        output = summaries(log)
        self.assertEqual(sum('migration case:' in item for item in output), MAX_MIGRATION_CASES)
        self.assertEqual(sum('failed case:' in item for item in output), MAX_FAILED_CASES)
        self.assertTrue(any('timed-out case result records: 100;' in item for item in output))
        self.assertTrue(any('runner restart records: 100 ' in item for item in output))

    def test_workflow_commands_escape_and_bound_untrusted_text(self):
        command = notice('100%\n::error::injected\rtext')
        self.assertEqual(command.count('\n'), 0)
        self.assertEqual(command.count('\r'), 0)
        self.assertIn('100%25%0A::error::injected%0Dtext', command)
        self.assertLess(len(notice('x' * 9000)), 1100)
        log = "Test Case '-[Tests.Fake%\n::error::bad testName]' failed (0.1 seconds)."
        self.assertFalse(any('failed case:' in item for item in summaries(log)))

    def test_cli_reports_successful_observed_counts_and_missing_file_without_false_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'native.log'
            path.write_text("\x1b[32mTest Suite 'All tests' passed at 12:00\x1b[0m\n Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds\n")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(path)]), 0)
            self.assertIn('::notice title=XCTest execution summary::XCTest aggregate: All tests passed; executed 3 tests', output.getvalue())
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main([str(Path(folder) / 'missing.log')]), 0)
            self.assertIn('missing or unreadable; XCTest results are unverified.', output.getvalue())
            self.assertNotIn('passed', output.getvalue())


if __name__ == '__main__':
    unittest.main()
