# Repository rules for plan execution (agterm)

These hold for every task in this repository. They are not optional and they are not style preferences.

## Never touch the user's live terminal

agterm is the terminal the user is working in right now. A mutating control command reaches their live
session and can destroy work in progress.

- NEVER run `agterm` or `agtermctl` against the default socket. Read-only `tree` and `window list` are
  tolerable; every write requires an explicitly isolated socket.
- NEVER launch or quit the app. No `open -n`, no `pkill agterm`, no `osascript ... to quit`. Both of the
  latter also reach development instances.
- NEVER run the Help > Install installers or `AgentHooksInstaller`. They write outside
  `AGTERM_STATE_DIR` into `~/.config/agterm/`, `~/.claude/settings.json` and `~/.codex/`.
- Static reading and building only. Verify behavior through tests, never by driving the running app.

## Build and test commands

- host-free tests: `cd agtermCore && swift test`, narrowed with `--filter <TestName>`
- app build: `make build`
- hosted AppKit tests: `make test-app`, narrowed with `-only-testing:<Target>/<Class>/<test>`
- lint: `make lint` — strict SwiftLint, zero findings required
- Run the wide gates ONCE, at the end of the run. A per-task gate is the narrow command for that task's
  own module. `agtermUITests/ControlAPIUITests` alone takes about seven minutes and tells you nothing a
  targeted run does not.

## Module boundary

`agtermCore` is host-free. It must not import GhosttyKit, AppKit, Metal or CoreGraphics, and must not use
CoreGraphics geometry types (`CGSize`, `CGPoint`, `CGRect`, `CGFloat`) — those pass Debug and tests but
crash Release whole-module optimization with an unresolved CoreFoundation cross-reference. Put model,
parsing, validation, routing and decision logic there; the app target is a thin side-effect adapter.

## This worktree

`GhosttyKit.xcframework`, `agterm/Resources/ghostty` and `agterm/Resources/terminfo` are symlinks into the
main checkout. Do not delete them, do not rebuild them, and do not run `scripts/setup.sh`.

## Comments and docs

Comments are liabilities kept short. Keep only a non-obvious constraint, a rejected alternative, or the
reason the obvious implementation fails. Never narrate code, never repeat a fact across surfaces, never
preserve change history. Test comments are rare and one line: add one only when neither the test name nor
the setup reveals the goal, and never label arrange/act/assert.

## Limits

Source files stay under 1000 lines, types under 800, lines under 200 columns. Test files may reach 2000.
Do not raise a SwiftLint limit to make a change fit — put new logic in a new file instead.

## Scope

This is fork-only work on a feature branch. Do not touch `CHANGELOG.md`, which is release-only. Do not
add upstream-facing documentation or website changes unless the plan's own task list asks for it.
