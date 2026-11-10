# Branch workflow

- Use one work branch per calendar day in `America/New_York`, named
  `codex/YYYY-MM-DD`.
- Reuse that day's existing local or remote branch for every request. Continue
  in its existing checkout where possible; do not create a feature branch for
  each task unless the user explicitly asks.
- When starting a new day's branch, carry forward the accumulated app changes,
  including unmerged work from the previous day. Keep existing history intact.

# Validation workflow

- Finish implementation before running checks.
- Push the completed changes and start the relevant GitHub checks, then report
  that they are running. Do not wait for CI to finish unless the user asks.

- Prefer the smallest relevant `job_scope` and `test_scope` in
  `.github/workflows/ios.yml`; use `tooling` for runner/parser/workflow-only changes.
  Full UI and Release checks remain explicit opt-ins (`job_scope=all` for all jobs).
- Automatic PR and main-push validation runs portable checks and native tests.
  Work-branch pushes do not also start duplicate checks; before a PR exists,
  dispatch the relevant focused scope after pushing.
- Report the exact commit and run link promptly. A queued/running check is not a
  passing result. Do not use synchronous `gh run watch` or poll until completion
  unless the user asks to wait.
