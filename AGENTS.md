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
