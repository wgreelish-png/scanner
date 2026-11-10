# Focused, bounded validation

## Choose the smallest useful run

The iOS workflow defaults to native tests plus portable tooling checks. Pull
requests and pushes to `main` use that baseline. Work-branch pushes do not also
launch a duplicate PR run; dispatch a focused check before opening a PR.

Use the workflow's `job_scope` and `test_scope` inputs:

- `tooling`: Python, JavaScript, source membership and bundled-runtime checks on
  Ubuntu. No simulator or macOS allocation.
- `native`: native regressions, optionally restricted by the existing printer,
  label or show-readiness scope.
- `ui`, `research_ui`, `evidence_ui`, `budget_ui`: the selected UI group. Existing
  narrow `test_scope` selections remain available.
- `log_review`: the native and two manual-add UI regressions for build 106.
- `ui_diagnostic`: only the previously timed-out
  `InventoryLabelsUITests/testBatchSearchCopiesPreviewAndLeavingUnprintedQueueClearsBeforeRelaunch`.
  Its total test-command budget is 15 minutes, with the same six-minute per-case
  allowance and assertions as the original test.
- `release`: unsigned iPhone Release compilation.
- `all` with `test_scope=all`: explicitly request the complete native, UI and
  Release validation. A baseline or focused pass is never a full-suite pass.

The general UI selection excludes Research, which continues to run once in its
dedicated group. No test case or assertion is deleted. New runs supersede older
runs for the same source repository, branch and requested scopes. Different
branches, forks or focused scopes do not cancel each other. Manual groups do not
include a commit SHA, so a newer revision can replace stale work.

Push completed changes, start the relevant check, then report its commit and run
link. Do not synchronously wait for CI unless requested. Queued and running are
not passing results.

## Command and job budgets

`scripts/process_budget.py` owns a new process group for each command and kills
that group's remaining children on completion, timeout or cancellation. It does
not kill unrelated Xcode or simulator processes. Timeout returns 124; other
failures and interrupt status remain failures. Log files are written directly,
so a descendant holding a `tee` pipe cannot keep the runner alive indefinitely.

Defaults, in seconds:

- `SCANNER_BUILD_TIMEOUT_SECONDS=1800`: UI build and Release build.
- `SCANNER_TEST_TIMEOUT_SECONDS=2700` for native's combined build/test command;
  `3600` for UI execution, or `900` for the single diagnostic case.
- `SCANNER_SIMCTL_TIMEOUT_SECONDS`: optional cap on each simulator command.
  Without an override, discovery/readiness have 300-second limits, creation 120,
  boot 90, and SDK lookup 30.
- `SCANNER_CLEANUP_TIMEOUT_SECONDS=30`: each owned simulator shutdown/delete and
  temporary-directory removal. Cleanup does not replace the original result.
- Failure-diagnostic extraction is separately limited to 120 seconds.

Budgets must be positive, finite and at most one day. They are total command
limits, independent of the existing 180-second native and 360-second UI per-case
limits. A long sequence of stalled cases therefore fails within a bounded total
instead of consuming several hours. The outer jobs allow 60 minutes native,
110 minutes UI, 40 minutes Release, and 15 minutes portable tooling. A total
timeout means remaining selected tests are unverified, not passed.

Each invocation creates its own temporary directory beneath `RUNNER_TEMP`, then
`TMPDIR`, then `/tmp`. Only a newly created UI simulator is shut down/deleted;
native tests retain their existing device. `NativeTests.log` and
`TestResults.xcresult` remain outside the temporary directory for artifacts.

## Evidence and remaining UI work

Historical [UI job 128331705971](https://github.com/wgreelish-png/scanner/actions/runs/42348609106/job/128331705971)
records 25 execution-allowance timeouts and 25 runner restarts. The first case
waits approximately 60 seconds for an app-idle notification, then performs
repeated search-field, window and navigation-bar accessibility lookups before
its six-minute timeout. These records do not establish whether the original
cause is app activity, simulator slowness, or accessibility query overhead.

The diagnostic scope isolates that exact case for a fresh macOS run. No app
behavior, XCTest idling, assertion, or accessibility query is changed without a
reproduction and before/after evidence. Historical UI compilation alone took
about 22 minutes; the successful native job took about 25 minutes including
build and tests. The budgets allow those observed cold runs rather than imposing
an unsupported short timeout.

The summary parser recognizes actual execution-allowance and restart records,
labels zero-test aggregates as unverified, and retains failures across retries.
Restart records are not treated as extra failures or as proof of a specific
cause. Portable regression tests cover command hangs, process cleanup,
cancellation, selected scopes, duplicate avoidance and parser edge cases. These
checks do not substitute for Xcode compilation or simulator execution.

Local validation for this change: all 66 Python helper/workflow/parser tests,
Bash syntax, YAML parsing and whitespace checks passed. The historical UI log
replay reports 25 timeout records and 25 restart records, with zero-test records
explicitly unverified. Linux has no Xcode; native/Release compilation and fresh
simulator execution have not been verified locally. The diagnostic scope is
available but has not been run for this change.


## Linux checker dependencies

The Ubuntu tooling job explicitly selects Python 3.12 and installs
`scripts/requirements-ci.txt` before running Python checks. The pinned
`openstep-parser` package is required by the Xcode project checker on Linux;
macOS uses its built-in `plutil`. For local Linux checks, first run:

```sh
python3 -m pip install -r scripts/requirements-ci.txt
```

The first CI run at `ae772ef` passed JavaScript and all 66 Python tests, then
failed the project checker because this Linux-only dependency had not been
installed. The provisioning correction adds a regression check that setup and
installation precede the checks; it does not skip the source-membership check.

Correction validation: a fresh isolated environment installed the pinned package,
all 67 Python tests passed, and that parser read the actual project and matched
its source lists to all 115 app, 86 native-test and 14 UI-test Swift filenames in
the repository tree. Bash syntax, workflow YAML and whitespace checks passed.
The replacement GitHub run remains the verification of the full Ubuntu job.
