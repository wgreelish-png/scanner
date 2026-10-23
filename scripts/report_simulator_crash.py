#!/usr/bin/env python3
"""Publish recent CardShowScanner crash reasons without dumping simulator reports.

Accept report files or directories (searched recursively). With no paths, inspect
~/Library/Logs/DiagnosticReports. Only reports modified in the last 20 minutes
are considered. Missing or unusable evidence produces a GitHub notice.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import time
from typing import Iterable

from annotate_xcode_errors import (
    ANSI, MAX_ERRORS, MAX_MESSAGE, Annotation, bounded_unique, escape_data,
)

MAX_AGE_SECONDS = 20 * 60
MAX_REPORT_BYTES = 16 * 1024 * 1024
MAX_FIELD_VALUES = 8
TARGET_PROCESSES = {'CardShowScanner', 'CardShowScannerTests', 'CardShowScannerTests-Runner'}
TARGET_FILENAME = re.compile(r'^CardShowScanner(?:Tests(?:-Runner)?)?(?:[-_].*)?\.(?:ips|crash)$')
LEGACY_SECTION = re.compile(
    r'^\s*(Application Specific Information|Dyld Error Message|Termination Reason):\s*(.*)$',
    re.IGNORECASE,
)
LEGACY_BOUNDARY = re.compile(
    r'^(?:Thread\b|Binary Images\b|Application Specific Backtrace\b|VM Region\b|'
    r'[A-Za-z][A-Za-z 0-9_()/.-]{0,80}:)',
)
DYLD_DETAIL = re.compile(r'^(?:Library not loaded|Referenced from|Reason|Symbol not found|Expected in):', re.IGNORECASE)
RUNTIME_DETAIL = re.compile(
    r'^(?:Fatal error:|dyld(?:\[\d+\])?:|Could not cast value of type\b|Terminating app due to uncaught exception\b)',
    re.IGNORECASE,
)


def text_values(value: object, depth: int = 0) -> list[str]:
    """Read bounded message values, never arbitrary dictionary keys or dumps."""
    if isinstance(value, str):
        cleaned = ANSI.sub('', value).strip()
        return [cleaned[:MAX_MESSAGE]] if cleaned else []
    if depth >= 4:
        return []
    values: Iterable[object]
    if isinstance(value, dict):
        values = value.values()
    elif isinstance(value, list):
        values = value
    else:
        return []
    output: list[str] = []
    for item in values:
        output.extend(text_values(item, depth + 1))
        if len(output) >= MAX_FIELD_VALUES:
            break
    return output[:MAX_FIELD_VALUES]


def message_annotations(label: str, value: object) -> list[Annotation]:
    return [Annotation('Simulator crash ' + label + ': ' + detail) for detail in text_values(value)]


def scalar_details(value: dict, keys: Iterable[str]) -> str:
    details = []
    for key in keys:
        item = value.get(key)
        if isinstance(item, str):
            item = ANSI.sub('', item).strip()[:MAX_MESSAGE]
        elif isinstance(item, (int, float)) and not isinstance(item, bool):
            item = str(item)
        else:
            continue
        if item:
            details.append(key + '=' + item)
    return '; '.join(details)


def ips_annotations(text: str, filename: str) -> list[Annotation]:
    decoder = json.JSONDecoder()
    documents = []
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        value, offset = decoder.raw_decode(text, offset)
        if not isinstance(value, dict):
            raise ValueError('Expected an IPS JSON object')
        documents.append(value)
    if not documents:
        raise ValueError('Empty IPS report')
    processes = [document[key] for document in documents for key in ('app_name', 'procName') if isinstance(document.get(key), str)]
    if processes and any(process not in TARGET_PROCESSES for process in processes):
        return []
    if not processes and not TARGET_FILENAME.match(filename):
        return []
    output = []
    for document in documents:
        for key in ('applicationSpecificInformation', 'asi'):
            output.extend(message_annotations('application information', document.get(key)))
        termination = document.get('termination')
        if isinstance(termination, dict):
            output.extend(message_annotations('termination reason', termination.get('reasons')))
            details = scalar_details(termination, ('namespace', 'code', 'indicator'))
            if details:
                output.append(Annotation('Simulator crash termination: ' + details))
        exception = document.get('exception')
        if isinstance(exception, dict):
            details = scalar_details(exception, ('type', 'signal', 'codes', 'subtype', 'message'))
            if details:
                output.append(Annotation('Simulator crash exception: ' + details))
        elif isinstance(exception, str):
            output.extend(message_annotations('exception', exception))
    return output


def legacy_annotations(text: str, filename: str) -> list[Annotation]:
    process = re.search(r'^Process:\s*(.+?)\s*\[\d+\]\s*$', text, re.MULTILINE)
    if process:
        if process[1].strip() not in TARGET_PROCESSES:
            return []
    elif not TARGET_FILENAME.match(filename):
        return []
    output = []
    label: str | None = None
    details: list[str] = []

    def finish() -> None:
        if label and details:
            output.append(Annotation('Simulator crash ' + label + ': ' + '\n'.join(details)[:MAX_MESSAGE]))

    for raw in ANSI.sub('', text).splitlines():
        section = LEGACY_SECTION.match(raw)
        if section:
            finish()
            label = section[1]
            details = [section[2]] if section[2] else []
            continue
        if not label:
            continue
        stripped = raw.strip()
        if not stripped or (LEGACY_BOUNDARY.match(stripped) and not DYLD_DETAIL.match(stripped) and not RUNTIME_DETAIL.match(stripped)):
            finish()
            label, details = None, []
        elif len(details) < 12:
            details.append(stripped[:MAX_MESSAGE])
    finish()
    return output


def recent_reports(paths: Iterable[Path], now: float) -> list[Path]:
    reports: dict[Path, float] = {}
    for root in paths:
        candidates = root.rglob('*') if root.is_dir() else [root]
        for path in candidates:
            if path.suffix not in ('.ips', '.crash') or path.is_symlink():
                continue
            try:
                modified = path.stat().st_mtime
                if path.is_file() and modified >= now - MAX_AGE_SECONDS:
                    reports[path.resolve()] = modified
            except OSError:
                continue
    return sorted(reports, key=reports.get, reverse=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path)
    parser.add_argument('--root', action='append', type=Path, help='Additional report directory; may be repeated.')
    parser.add_argument('--max-errors', type=int, default=MAX_ERRORS)
    args = parser.parse_args(argv)
    paths = args.paths + (args.root or [])
    if not paths:
        paths = [Path.home() / 'Library/Logs/DiagnosticReports']
    annotations = []
    unusable = 0
    for path in recent_reports(paths, time.time()):
        try:
            with path.open('rb') as report:
                data = report.read(MAX_REPORT_BYTES + 1)
            if len(data) > MAX_REPORT_BYTES:
                raise ValueError('Report exceeds size bound')
            text = data.decode('utf-8', errors='replace')
            annotations.extend(ips_annotations(text, path.name) if path.suffix == '.ips' else legacy_annotations(text, path.name))
        except (OSError, ValueError, RecursionError):
            if TARGET_FILENAME.match(path.name):
                unusable += 1
    for annotation in bounded_unique(annotations, args.max_errors):
        print(annotation.workflow_command())
    if not annotations:
        notice = 'No usable recent CardShowScanner crash diagnostics were found; the test-abort cause remains unconfirmed.'
        if unusable:
            notice += ' Unreadable or malformed matching reports: ' + str(unusable) + '.'
        print('::notice title=Simulator crash evidence::' + escape_data(notice))
    elif unusable:
        print('::notice title=Simulator crash evidence::Unreadable or malformed matching reports: ' + str(unusable) + '.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
