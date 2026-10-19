---
worth: yes
where: .claude/rules/ci.md
added: 2026-10-18
---
# ci.md omits the fish steps in the test and build jobs

#761 added fish to CI, and `.claude/rules/ci.md` describes neither job's new steps:

- `test` runs `brew install fish` and sets `AGTERM_REQUIRE_FISH=1`, so the fish tests fail instead of
  skipping when fish is missing.
- `build` installs fish, passes `TEST_RUNNER_AGTERM_REQUIRE_FISH=1` to `scripts/test-app.sh`, then runs
  the "Plain fish login shell seam" step: it switches the runner account's login shell to fish with `dscl`
  and runs only `SessionHostFishSeamTests/testPlainLoginShellStartsIntegratedFish`.

The ordering matters. Moving the fish switch before the hosted tests silently skips the zsh plain-login
seam (#574); running the fish seam before the switch fails its required-login-shell check.
