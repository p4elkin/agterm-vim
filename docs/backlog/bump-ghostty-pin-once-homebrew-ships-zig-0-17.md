---
worth: later
where: scripts/setup.sh
added: 2026-10-27
---
# bump GHOSTTY_REV to ghostty 1.4.0 or later once Homebrew ships zig@0.17

Ghostty 1.4.0 (`v1.4.0`, `83fb956`) requires zig 0.17. Homebrew has 0.17 only as the rolling `zig`
formula, and `ZIG_FORMULA` names a minor line on purpose, so the bump waits for `zig@0.17`. Pinning an
upstream 0.17 toolchain in `setup.sh` instead is a separate decision, not a way around that wait.

The scrollback compression, 50 MB default limit, reflow and throughput work is already in `683d8db`.
The bump adds the fixed-memory trims (ghostty PRs 14130, 14137, 14138) and the idle display-link pause
(14035), which the embedded build reaches.

Cost:

- `ZIG_FORMULA` also builds zmx, whose patches pin `minimum_zig_version` 0.16.0, and neither
  `ZMX_STAMP` nor the CI zmx cache key records the compiler. Keep a separate 0.16 for zmx, or move it to
  0.17 with its stamp and cache invalidated and a cold build tested.
- `scripts/ghostty-patches/0001` no longer applies to v1.4.0 (`src/App.zig`, `src/Surface.zig`). Rebase
  it per its README, unless PR 14444 has landed in the form
  `remove-surface-free-backport-after-ghostty-pin-bump.md` requires.
- Re-test the font-size-increase scrollback case, and do the `ghostty.h` check that
  `program-status-waits-on-an-upstream-app-action.md` asks for on a bump.
