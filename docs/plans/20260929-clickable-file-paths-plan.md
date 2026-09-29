# Clickable file paths

## Contents

- [Overview](#overview)
- [Context (from discovery)](#context-from-discovery)
- [Development Approach](#development-approach)
- [Testing Strategy](#testing-strategy)
- [Progress Tracking](#progress-tracking)
- [What Goes Where](#what-goes-where)
- [Implementation Steps](#implementation-steps)
- [Post-Completion](#post-completion)

## Overview

Shift+Cmd+click on a file path in terminal output opens the file in an overlay over the clicked pane:
markdown in plannotator, code in revdiff.
A path relative to some other directory is found through a fixed resolution chain.
Several candidates go through the native picker; none shows a self-hiding HUD.
Design, measured hit rate and security boundary: `docs/plans/20260929-clickable-file-paths-spec.md`.

## Context (from discovery)

- Ghostty's built-in link already matches paths and, on click, delivers either the pwd-resolved absolute
  path or the raw text (upstream `src/config/url.zig`, `Surface.processLinks` → `resolvePathForOpening`,
  at the pinned `GHOSTTY_REV`). The built-in link is matched before user `link` rules, so no custom rule
  is added.
- `agtermCore/Sources/agtermCore/LinkPolicy.swift`: `disposition(for:)` returns `.ignore` for schemeless
  input today (`guard let url = URL(string: raw), let scheme = url.scheme…`).
- `agterm/Ghostty/GhosttySurfaceView+Input.swift`: `openLink` switches on the disposition;
  `openXchatMessage` finds `xchat-open` in `~/.local/bin` or `/opt/homebrew/bin` and runs it with an argv
  array and `AGTERM_SESSION_ID` in the environment.
- `agterm/Ghostty/GhosttySurfaceView.swift`: `isSplitPane`; `session.cwd(for: .right)` / `effectiveCwd`
  give the clicked pane's directory (the terminal-title code does the same).
- `agtermCore/Sources/agtermCore/Session.swift`: `cwd(for:)`, `isSplit`.
- `agterm/Commands/CustomCommandRunner.swift`: its `socketProvider` resolves to
  `controlServer.resolvedSocketPath`; the new launch passes the same path.
- `.claude/rules/libghostty.md`, the `link` section: states the number of `LinkPolicy` dispositions.
- `~/dev/agterm-agents/bin/xchat-open`: the PATH append a GUI-spawned script needs.
- `~/dev/agterm-agents/bin/agterm-plannotate`: `file --target [--pane left|right] [--socket]`.
- `~/dev/agterm-agents/bin/agterm-open-at`: its docstring shows a `run:` link action that does not exist.
- `~/dev/agterm-agents/install.sh` symlinks `bin/` into `~/.local/bin`.
- `plugins/agterm/skills/agterm/reference.md`: `session hud … --hide-after`; `session overlay open` runs
  its command through `sh -c` with the app's PATH, so a bare Homebrew or `~/.local/bin` name exits 127;
  `agtermctl pick` has no `--target` (frontmost window), reads choices on stdin, exits 2 on cancel.
- revdiff single-file mode is `revdiff --only=<file>`; it has no start-line option.
- ⚠️ `LinkDisposition` is `public`, and `agtermCore` is consumed by the `agterm-linux` fork. A new case
  breaks an exhaustive `switch` there. No local clone exists.

## Development Approach

- **testing approach**: TDD for `LinkPolicy` and the argv builder in `agtermCore`, and for the script in
  `agterm-agents` pytest. The `openLink` glue is a thin launch, checked by hand in an isolated Debug
  instance.
- run only the tests a task touches; the full gates run once, in the verification task.
- `agtermCore` stays free of AppKit.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy

- **unit tests (`LinkPolicyTests`)**: accepted: relative, one-segment `~/x.md` and `/x.md`, deeper `~/`
  and absolute paths; an absolute path with a space; `:N`, `:N-M`, `:N:C`; a trailing `.`, `**`, `;`, `?`;
  `x.tsx` and `x.json` keep their full extension. Refused: bare `x.md`, a relative path with a space,
  leading `-`, a character outside the class, a schemeless OSC 8-style target outside these rules, an extension outside the allowlist, over 1024 characters, a newline, a line
  of `0`. Existing web, `file://` and xchat rows unchanged.
- **unit tests (argv builder)**: unsplit left pane → no `--pane`, `effectiveCwd`; split right → `--pane
  right`, right cwd; `--line` present or absent; the path always last, after `--`.
- **pytest (`tests/test_agterm_open_path.py`)**: each chain step in a temporary git repo with a worktree;
  first-step-wins ordering; suffix unique vs several; Spotlight filtered by full suffix (`mdfind` stubbed
  on PATH); outcome routing to HUD, picker (cancel exit 2 is quiet) and each viewer with `agtermctl`,
  `agterm-plannotate` and `revdiff` stubbed and their argv recorded; a run with a stripped PATH still
  finds the stubs through the appended directories; the overlay command names revdiff by absolute path.
  Follow the stub pattern of `tests/test_xchat_open.py`.
- **manual**: isolated Debug instance, one click per outcome.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## What Goes Where

- Tasks 1, 2, 4 and 5: this repo, one feature branch in a worktree off `main`.
- Task 3: `~/dev/agterm-agents`, its own branch in a worktree off its `main`. Other sessions switch the
  branch of that main checkout, so never work in it directly.

## Implementation Steps

### Task 1: schemeless paths in `LinkPolicy`, argv builder

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Create: `agtermCore/Sources/agtermCore/OpenPathLaunch.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/OpenPathLaunchTests.swift`

- [x] find the `agterm-linux` fork (`gh search repos agterm-linux --include-forks=true`), shallow-clone it
      into the scratchpad, grep for a `switch` over `LinkDisposition`; if one exists, note it in the PR
      description
- [x] failing `LinkPolicyTests` rows first, as listed in Testing Strategy
- [x] `LinkDisposition.openPath(path: String, line: Int?)`; in `disposition(for:)`, schemeless input goes
      to `openPathDisposition(_:)` before the scheme guard. Rules from the spec's Security boundary.
      Extension allowlist: `md markdown swift py go ts tsx js jsx java kt sh zsh zig rs c h m mm yaml yml
      json toml conf`
- [x] extend the type doc comment by one clause; do not repeat the xchat reasoning
- [x] failing `OpenPathLaunchTests` first, then `OpenPathLaunch.arguments(path:line:cwd:sessionID:
      pane:isSplit:socket:)` returning the script argv, path last after `--`
- [x] `swift test --filter 'LinkPolicyTests|OpenPathLaunchTests'` passes

### Task 2: app launch of `agterm-open-path`

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: the file that makes `controlServer.resolvedSocketPath` reachable, only if the surface cannot
  reach it already

- [x] make the control socket path reachable from the surface (already there: the surface's `env["AGTERM_SOCKET"]`)
- [x] fold `openXchatMessage`'s helper lookup and launch into one private `runAgentHelper(_ name:,
      arguments:)` so both links share it
- [x] `.openPath` case in `openLink`: builds argv with `OpenPathLaunch.arguments`, pane cwd is
      `session.cwd(for: .right)` for a split surface, else `effectiveCwd`
- [x] missing helper logs a warning, like the xchat path
- [x] `make build` compiles

### Task 3: `agterm-open-path` script, `agterm-open-at` docstring (agterm-agents)

**Files:**
- Create: `~/dev/agterm-agents/bin/agterm-open-path`
- Create: `~/dev/agterm-agents/tests/test_agterm_open_path.py`
- Modify: `~/dev/agterm-agents/bin/agterm-open-at` (docstring only)

- [x] failing pytest cases first, as listed in Testing Strategy
- [x] PATH append of `~/.local/bin` and `/opt/homebrew/bin`, as in `xchat-open`
- [x] argparse: `--cwd`, `--target`, `--pane`, `--socket`, `--line`, then `--` and the path
- [x] `resolve(path, cwd) -> (candidates, step)`: the chain from the spec, first non-empty step wins,
      regular files only, git calls with `-c core.fsmonitor=`, Spotlight capped at 20 and filtered by full
      `/<path>` suffix
- [x] outcomes: none → `session hud "File not found: <path>" --hide-after 4 --target`; one from a repo step
      → open; one from Spotlight or several → `agtermctl pick` with full paths, exit 2 ends quietly
- [x] open: `.md`/`.markdown` → `agterm-plannotate <abs> --target [--pane] [--socket]`, detached;
      other → `agtermctl session overlay open "<shutil.which('revdiff')> --only=<quoted abs>" --cwd <dir>
      --target [--pane] [--socket]`
- [x] every `agtermctl` call passes `--socket` when given, so a Debug instance never reaches the live one
- [x] `--line` is accepted and ignored for now (spec, Open points)
- [x] `pytest tests/test_agterm_open_path.py` passes
- [x] `agterm-open-at` docstring: replace the `run:` example with a pointer to `agterm-open-path`
- [ ] run `./install.sh` only after merge, so the `~/.local/bin` link points at `main`

### Task 4: documentation

**Files:**
- Modify: `FORK-NOTES.md`, `CHANGELOG-fork.md`, `.claude/rules/libghostty.md`

- [x] `FORK-NOTES.md`: one or two lines next to the clickable xchat entry
- [x] `CHANGELOG-fork.md`: user-facing entry under `## Unreleased`
- [x] `libghostty.md`, `link` section: update the disposition count and add the path disposition in one
      sentence, pointing at the spec
- [ ] ask Sasha whether `LinkPolicy.swift` joins the `flagged` list in `.claude/rules/fork-merge.md`
      (answer recorded either way, never assumed)

### Task 5: verify acceptance criteria

- [ ] isolated Debug instance (short `/tmp` `AGTERM_STATE_DIR`, `windows/` marker), one click per outcome:
      md in pane dir, `x.swift:12` in a subfolder via suffix, file in main checkout from a worktree pane,
      several candidates → picker, missing → HUD that hides itself, split right pane opens over the right
      pane, a plain `https://` link still opens in the browser, a path printed by a live Claude Code
      session (`cd ~/dev.umputun/agterm && claude`) opens — if it arrives as an OSC 8 `file://` link, record
      it and ask Sasha before widening scope (spec, Open points)
- [ ] revdiff on a tracked file with local changes: whole file or diff? If diff, switch the code viewer
      to `--stdin --stdin-name` (spec, Open points) and update the script and its test
- [ ] full gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

- Line jump in revdiff and plannotator, if either gains a start-line option.
- After a week of use, re-run the transcript measurement from the spec and decide on bare file names.

<!-- plan-review: planning:plan-review 2026-09-29 findings=16 resolved -->
