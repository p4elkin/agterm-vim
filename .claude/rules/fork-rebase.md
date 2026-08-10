## Rebasing the fork onto upstream

This fork adds vim-style keys on top of `umputun/agterm` and is rebased onto `origin/master`, never merged.
`vimfork` is the publishing remote (`p4elkin/agterm-vim`, branch `main`); `origin` is upstream and is never
pushed to.

- Tag the tip before starting (`git tag pre-rebase-<date>`) and say the tag name in the report.
  Publishing is `git push --force-with-lease vimfork HEAD:main`, and only after every gate below is green.
- Never resolve a conflict by deleting fork behavior, and never drop an upstream fix. When both sides
  changed a line, keep upstream's change and re-apply the fork's intent on top of it.

### The gates, and why the obvious three are not enough

⚠️ `swift test`, `make lint` and `make release` do not compile `agtermTests`. A rebase that breaks the
hosted test target passes all three. Run `make test-app` as well, every time.

⚠️ **The conflict count predicts nothing.** The 2026-08-10 rebase shipped two defects. One came out of a
resolved conflict; the other came from a file with no conflict at all — upstream added `FullScreenChordTests`
against a three-argument `CustomCommandRunner` initializer while the fork's takes `performBuiltin` too, and
git had nothing to flag. So run the full gate set on a zero-conflict rebase exactly as on a messy one.

### Where upstream and the fork keep colliding

- `agterm/Commands/CustomCommandRunner.swift` — the highest-risk file by far. Both sides keep restructuring
  `handleKeyDown`, and the fork inserts normal mode as an early-returning branch in the middle of it.
  ⚠️ **Anything upstream adds AFTER that branch is dead while the mode is on.** That is exactly how
  `toggle_fullscreen` broke. After any rebase touching this file, read the whole function top to bottom and
  ask, per dispatch below the normal-mode branch, whether it still needs to run with the mode on.
- `agtermCore/Sources/agtermCore/{Keymap,BuiltinAction,NormalModeState}.swift` — the fork widens the keymap
  grammar (`nmap`, leader sequences, `KeybindTarget`), so an upstream keymap fix usually needs re-applying
  onto a wider type rather than taking one side.
- `.claude/rules/keymap.md`, `README.md`, `cookbook/` — text conflicts, keep both sides.
- `CHANGELOG.md` — upstream release notes only. Take upstream's version whole.

### Delegating it

A subagent can do the mechanical replay, but its report is not evidence: the 2026-08-10 agent traced the
merged control flow correctly, then recorded the full screen dispatch sitting behind the normal-mode filter
as matching the fork's intent. Verify the result yourself — `git merge-base --is-ancestor origin/master HEAD`,
the fork commit count, and the gates, including `make test-app`.
