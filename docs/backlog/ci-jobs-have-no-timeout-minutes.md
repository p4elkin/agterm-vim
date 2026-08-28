---
worth: later
where: .github/workflows/ci.yml
added: 2026-08-28
---
# no job in ci.yml sets timeout-minutes, so every one inherits the six-hour default

`timeout-minutes` appears nowhere in `.github/workflows/ci.yml`, at workflow, job or step level, so all six
jobs (`changes`, `test`, `coverage`, `lint`, `build`, `cookbook`) fall back to GitHub's 360-minute default.
That is not unbounded, but it is far looser than any of them needs, and a job that wedges holds its check in
a pending state for six hours rather than failing in a way anyone notices.

Several steps execute code from the pull request head: `swift test` at :54, `scripts/build.sh` at :129 and
`scripts/test-app.sh` at :195, and since #496 the cookbook job runs every `cookbook/**/test_*.py` through
`python3` at :277. A test that loops or blocks on any of those paths costs the full default before the check
reports. `concurrency.group` keys on `github.ref` (:10), which is `refs/pull/N/merge` for a pull request, so
a hung fork job cannot block master's own CI: the cost is a check that never reports and has to be cancelled
by hand.

The fix is a job-level `timeout-minutes` on each of the six, sized to what that job actually takes, rather
than a single step-level timeout. A lone timeout bolted onto the newest step would be inconsistent with the
other five jobs and would not close the larger gap.

Surfaced reviewing PR #496, which added the `python3` execution step. Deferred because it predates that
change and belongs to the workflow as a whole.
