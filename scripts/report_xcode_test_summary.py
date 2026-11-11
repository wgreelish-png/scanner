#!/usr/bin/env python3
"""Publish bounded XCTest counts and named migration results as public CI notices.

Only recognized XCTest result records are summarized. Runtime diagnostics and
xcodebuild's exit status are not evidence that any particular test passed.
"""
from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path
import re

from annotate_xcode_errors import ANSI, escape_data

MAX_AGGREGATES = 8
MAX_FAILED_CASES = 10
MAX_MIGRATION_CASES = 10
MAX_NOTICE = 1000
MIGRATION_CASES = {
    'testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch',
    'testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers',
}
SUITE = re.compile(r"^Test Suite '([A-Za-z_][A-Za-z0-9_.]*\.xctest|All tests|Selected tests)' (passed|failed) at\b")
COUNTS = re.compile(r'^\s*Executed (\d{1,6}) tests?, with (\d{1,6}) failures?(?: \((\d{1,6}) unexpected\))?(?:\s|$)')
CASE = re.compile(
    r"^Test [Cc]ase '(?:-\[([A-Za-z_][A-Za-z0-9_.]*) ([A-Za-z_][A-Za-z0-9_]*)\]|"
    r"([A-Za-z_][A-Za-z0-9_.]*)\(\))' (passed|failed|skipped|timed out|exceeded execution time allowance of \d{1,6}(?:\.\d{1,3})? (?:seconds?|minutes?))\b"
)
RESTART = (
    'Restarting after unexpected exit, crash, or test timeout; '
    'summary will include totals from previous launches.'
)


def summaries(log: str) -> list[str]:
    aggregates: deque[str] = deque(maxlen=MAX_AGGREGATES)
    aggregate_count = 0
    failures: dict[str, None] = {}
    migrations: dict[str, set[str]] = {}
    migrations_limited = False
    timeout_count = 0
    restart_count = 0
    zero_aggregate_count = 0
    pending_suite: tuple[str, str] | None = None
    for line in ANSI.sub('', log).splitlines():
        if line == RESTART:
            restart_count += 1
        suite = SUITE.match(line)
        counts = COUNTS.match(line)
        if counts and pending_suite:
            name, status = pending_suite
            tests, failed, unexpected = counts.groups()
            if int(tests) == 0:
                zero_aggregate_count += 1
                status = 'reported zero tests (not a test pass)'
            message = f'XCTest aggregate: {name} {status}; executed {tests} tests, {failed} failures'
            if unexpected is not None:
                message += f' ({unexpected} unexpected)'
            aggregates.append(message + '.')
            aggregate_count += 1
        # A count belongs only to the immediately preceding recognized suite.
        # Never associate an unrelated later diagnostic/count with a stale suite.
        pending_suite = suite.groups() if suite else None
        case = CASE.match(line)
        if not case:
            continue
        pending_suite = None
        owner, method, swift_name, status = case.groups()
        if status.startswith('exceeded execution time allowance'):
            status = 'timed out'
        name = f'{owner}.{method}' if owner else swift_name
        if len(name) > 250:
            continue
        method = method or name.rsplit('.', 1)[-1]
        if status == 'timed out':
            timeout_count += 1
        if status in ('failed', 'timed out'):
            failures[name] = None
        if method in MIGRATION_CASES:
            if name in migrations or len(migrations) < MAX_MIGRATION_CASES:
                migrations.setdefault(name, set()).add(status)
            else:
                migrations_limited = True

    messages = list(dict.fromkeys(aggregates))
    if aggregate_count > MAX_AGGREGATES:
        messages.append(f'XCTest aggregate output limited to the last {MAX_AGGREGATES} records.')
    if not aggregate_count:
        messages.append('No XCTest aggregate execution counts found; test completion is unverified from this log.')
    if zero_aggregate_count:
        messages.append(f'XCTest reported {zero_aggregate_count} zero-test aggregate records; these do not verify test execution or success.')
    if timeout_count:
        messages.append(f'XCTest timed-out case result records: {timeout_count}; these are failures, not completed passes.')
    if restart_count:
        messages.append(f'XCTest runner restart records: {restart_count} after unexpected exit, crash, or test timeout; restart records do not identify a specific cause or additional failed cases.')
    for name, statuses in sorted(migrations.items()):
        # A later retry must not erase an earlier failure or timeout.
        status = next(value for value in ('timed out', 'failed', 'skipped', 'passed') if value in statuses)
        suffix = ' (multiple outcomes recorded)' if len(statuses) > 1 else ''
        messages.append(f'XCTest migration case: {name} {status}{suffix}.')
    if migrations_limited:
        messages.append(f'XCTest migration case output limited to the first {MAX_MIGRATION_CASES} names; see the native log artifact.')
    messages.extend(f'XCTest failed case: {name}.' for name in list(failures)[:MAX_FAILED_CASES])
    if len(failures) > MAX_FAILED_CASES:
        messages.append(f'{len(failures) - MAX_FAILED_CASES} additional failed XCTest cases omitted from notices; see the native log artifact.')
    return messages


def notice(message: str) -> str:
    if len(message) > MAX_NOTICE:
        message = message[:MAX_NOTICE - 1] + '…'
    return '::notice title=XCTest execution summary::' + escape_data(message)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    args = parser.parse_args(argv)
    try:
        messages = summaries(args.log.read_text(errors='replace'))
    except OSError:
        messages = ['Native test log is missing or unreadable; XCTest results are unverified.']
    for message in messages:
        print(notice(message))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
