#!/usr/bin/env python3
"""Publish bounded, escaped native diagnostics as public GitHub error annotations.

Usage on a failed native step:
  python3 scripts/annotate_xcode_errors.py native.log --fallback 'xcodebuild failed; see native log artifact.'
Successful logs without error lines produce no annotations. Missing/unreadable logs
produce an explicit diagnostic; this tool never reports that native checks passed.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import posixpath
import re
import sys
from typing import Iterable

MAX_ERRORS = 30
MAX_MESSAGE = 2000
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
FILE_ERROR = re.compile(r"^\s*(.+?):([0-9]+)(?::([0-9]+))?:\s*(?:fatal\s+)?error:\s*(.+)$")
GENERAL_ERROR = re.compile(r"\berror:\s*(.+)$", re.IGNORECASE)
TESTING_FAILED = re.compile(r"^\s*Testing failed:\s*(.*)$", re.IGNORECASE)
RUNTIME_FAILURE = re.compile(
    r"\b(?:Could not cast value of type\b|Fatal error:|Terminating app due to uncaught exception\b).*",
    re.IGNORECASE,
)
TEST_CRASH = re.compile(
    r"\b(?:Test crashed\b|(?:XCTest|test runner)\b.*?\bcrashed\b).*",
    re.IGNORECASE,
)


def escape_data(value: str) -> str:
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def escape_property(value: str) -> str:
    return escape_data(value).replace(':', '%3A').replace(',', '%2C')


def relative_source(path: str, repo_root: Path) -> str | None:
    """Only annotate repository files; external build paths stay out of properties."""
    path = posixpath.normpath(path.strip().strip('"').replace('\\', '/'))
    root = posixpath.normpath(str(repo_root).replace('\\', '/')).rstrip('/')
    if path.startswith(root + '/'):
        return path[len(root) + 1:]
    absolute = path.startswith('/') or re.match(r'^[A-Za-z]:/', path)
    if not absolute and path != '..' and not path.startswith('../'):
        return path.removeprefix('./')
    return None


@dataclass(frozen=True)
class Annotation:
    message: str
    file: str | None = None
    line: int | None = None
    column: int | None = None

    def workflow_command(self) -> str:
        message = self.message.strip()
        if len(message) > MAX_MESSAGE:
            message = message[:MAX_MESSAGE - 1] + '…'
        properties = ['title=Xcode native check']
        if self.file:
            properties.append('file=' + escape_property(self.file[:1024]))
            if self.line and self.line > 0:
                properties.append('line=' + str(self.line))
                if self.column and self.column > 0:
                    properties.append('col=' + str(self.column))
        return '::error ' + ','.join(properties) + '::' + escape_data(message)


def extract_annotations(text: str, repo_root: Path) -> list[Annotation]:
    annotations: list[Annotation] = []
    summary: list[str] = []
    collecting_summary = False
    failed_marker = False
    for raw in ANSI.sub('', text).splitlines():
        file_error = FILE_ERROR.match(raw)
        if file_error:
            path, line, column, message = file_error.groups()
            source = relative_source(path, repo_root)
            if source is None:
                location = posixpath.basename(path.replace('\\', '/')) + ':' + line
                if column:
                    location += ':' + column
                message = location + ': ' + message
            annotations.append(Annotation(message, source, int(line), int(column) if column else None))
            collecting_summary = False
            continue
        testing = TESTING_FAILED.match(raw)
        if testing:
            collecting_summary = True
            if testing[1]:
                summary.append(testing[1])
            continue
        runtime_failure = RUNTIME_FAILURE.search(raw)
        if runtime_failure:
            annotations.append(Annotation(runtime_failure[0]))
            collecting_summary = False
            continue
        general = GENERAL_ERROR.search(raw)
        if general:
            annotations.append(Annotation(general[1]))
            collecting_summary = False
            continue
        test_crash = TEST_CRASH.search(raw)
        if test_crash:
            annotations.append(Annotation(test_crash[0]))
            collecting_summary = False
            continue
        stripped = raw.strip()
        if '** TEST FAILED **' in raw or '** BUILD FAILED **' in raw:
            failed_marker = True
            collecting_summary = False
        elif collecting_summary:
            if raw[:1].isspace() and stripped:
                if len(summary) < 8:
                    summary.append(stripped)
            else:
                collecting_summary = False
    if not annotations and summary:
        annotations.append(Annotation('Testing failed: ' + '; '.join(summary)))
    elif not annotations and failed_marker:
        annotations.append(Annotation('Xcode reported a failed build or test run. See the native log artifact for details.'))
    return annotations


def bounded_unique(annotations: Iterable[Annotation], limit: int = MAX_ERRORS) -> list[Annotation]:
    output: list[Annotation] = []
    seen: set[tuple[str, str | None, int | None, int | None]] = set()
    for annotation in annotations:
        key = (annotation.message.strip(), annotation.file, annotation.line, annotation.column)
        if key in seen:
            continue
        seen.add(key)
        output.append(annotation)
        if len(output) >= max(1, min(MAX_ERRORS, limit)):
            break
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logs', nargs='+', type=Path)
    parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--max-errors', type=int, default=MAX_ERRORS)
    parser.add_argument('--fallback', help='Error message if a failed native run produced no recognized diagnostics.')
    args = parser.parse_args(argv)
    annotations: list[Annotation] = []
    for log in args.logs:
        try:
            annotations.extend(extract_annotations(log.read_text(errors='replace'), args.repo_root))
        except OSError:
            annotations.append(Annotation('Native diagnostic log is missing or unreadable: ' + log.name))
    if not annotations and args.fallback:
        annotations.append(Annotation(args.fallback))
    for annotation in bounded_unique(annotations, args.max_errors):
        print(annotation.workflow_command())
    return 0


if __name__ == '__main__':
    sys.exit(main())
