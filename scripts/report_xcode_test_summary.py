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
MAX_NOTICE = 1000
MIGRATION_CASES = {
    'testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch',
    'testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers',
}
SUITE = re.compile(r"^Test Suite '([A-Za-z_][A-Za-z0-9_.]*\.xctest|All tests)' (passed|failed) at\b")
COUNTS = re.compile(r'^\s*Executed (\d{1,6}) tests?, with (\d{1,6}) failures?(?: \((\d{1,6}) unexpected\))?(?:\s|$)')
CASE = re.compile(
    r"^Test [Cc]ase '(?:-\[([A-Za-z_][A-Za-z0-9_.]*) ([A-Za-z_][A-Za-z0-9_]*)\]|"
    r"([A-Za-z_][A-Za-z0-9_.]*)\(\))' (passed|failed|skipped)\b"
)


def summaries(log: str) -> list[str]:
    aggregates: deque[str] = deque(maxlen=MAX_AGGREGATES)
    aggregate_count = 0
    failures: dict[str, None] = {}
    migrations: dict[str, str] = {}
    pending_suite: tuple[str, str] | None = None
    for line in ANSI.sub('', log).splitlines():
        suite = SUITE.match(line)
        if line.startswith('Test Suite '):
            pending_suite = suite.groups() if suite else None
        counts = COUNTS.match(line)
        if counts and pending_suite:
            name, status = pending_suite
            tests, failed, unexpected = counts.groups()
            message = f'XCTest aggregate: {name} {status}; executed {tests} tests, {failed} failures'
            if unexpected is not None:
                message += f' ({unexpected} unexpected)'
            aggregates.append(message + '.')
            aggregate_count += 1
            pending_suite = None
        case = CASE.match(line)
        if not case:
            continue
        pending_suite = None
        owner, method, swift_name, status = case.groups()
        name = f'{owner}.{method}' if owner else swift_name
        if len(name) > 250:
            continue
        method = method or name.rsplit('.', 1)[-1]
        if status == 'failed':
            failures[name] = None
        if method in MIGRATION_CASES:
            migrations[name] = status

    messages = list(dict.fromkeys(aggregates))
    if aggregate_count > MAX_AGGREGATES:
        messages.append(f'XCTest aggregate output limited to the last {MAX_AGGREGATES} records.')
    if not aggregate_count:
        messages.append('No XCTest aggregate execution counts found; test completion is unverified from this log.')
    messages.extend(f'XCTest migration case: {name} {status}.' for name, status in sorted(migrations.items()))
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
