---
worth: later
where: scripts/setup.sh
added: 2026-10-31
---
# fork libghostty patches keep their own directory and stamp beside upstream's

Upstream (merged 2026-10-31, `4cfb58c8`) added `scripts/ghostty-patches/` with a build stamp of
`GHOSTTY_REV` plus a digest of those patches. The fork already carried `patches/ghostty/`
(`0001-surface-realize-api.patch`, `0002-link-config.patch`) with its own `build_key`. The merge kept both:
`setup.sh` applies upstream's directory, then the fork's, and `build_key` prints
`"$GHOSTTY_STAMP patches:<fork sha>"`.

## What happened

Derived from reading the merged `scripts/setup.sh`, not reproduced. A fork patch dropped into
`scripts/ghostty-patches/` instead would ride upstream's stamp, apply loop, CI cache key
(`.github/workflows/ci.yml` keys only on `scripts/ghostty-patches/*.patch`) and the worktree stamp rule in
`CLAUDE.md`, which today all ignore `patches/ghostty/`. Moving the two patches there (numbered after
upstream's `0001-drain-mailbox-during-surface-teardown.patch`) would delete the fork's `build_key`
branch and the second apply loop. Cost: every patch-number collision on a later upstream patch becomes a
rename conflict, which is why it is not done inside a merge.
