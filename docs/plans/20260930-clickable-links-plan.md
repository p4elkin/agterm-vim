# Clickable Jira keys and GitLab MR links

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

Shift+Cmd+click on a Jira key or a GitLab merge request URL opens the item in a terminal view in an overlay
over the clicked pane; per kind, config switches that to a rendered HTML overlay or the browser.
Every other URL still opens in the browser.
Design, views, outcomes and security boundary: `docs/plans/20260930-clickable-links-spec.md`.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/LinkPolicy.swift`: `disposition(for:)` returns `.open(url)` for
  `permittedSchemes` (`http`, `https`, `mailto`, `ftp`); its header comment says `.open` is `NSWorkspace.open`.
- `agterm/Ghostty/GhosttySurfaceView+Input.swift`: `openLink` runs `NSWorkspace.shared.open(url)` for
  `.open`, the only consumer of `.open`; `openFilePath` and `openXchatMessage` launch through the private
  `runAgentHelper(_:arguments:sessionID:)`, which looks in `~/.local/bin` then `/opt/homebrew/bin`, logs a warning
  when neither exists, and returns nothing.
- Overlay surfaces have no `session` (only `wirePane` in `agterm/agtermApp.swift` sets it), and the HTML overlay
  sends its link clicks to the system browser through `HtmlOverlayRegistry`, never `openLink`.
- `agtermCore/Sources/agtermCore/OpenPathLaunch.swift` and `agtermCore/Tests/agtermCoreTests/OpenPathLaunchTests.swift`:
  the argv-builder shape to copy.
- `patches/ghostty/0002-link-config.patch`: `link = open:<template with $0>,<regex>`; the built-in URL link is
  matched before user rules (`.claude/rules/libghostty.md`, the `link` section).
- `FORK-NOTES.md` (by feature) and `CHANGELOG-fork.md` (by release): a feature landing needs a line in both.
- `~/.config/agterm/ghostty.conf`: holds the xchat `link` rule; the Jira rule goes beside it (Sasha's file).
- `~/dev/agterm-agents/bin/agterm-open-path`: `ctl()`, `pick()`, `show_not_found` (HUD `--hide-after 4`),
  the one-shot overlay wrapper under `~/.local/state/`, the PATH append; `tests/test_agterm_open_path.py`: the
  stub pattern.
- `~/dev/agterm-agents/install.sh`: `scripts()` symlinks every file in `bin/` into `~/.local/bin`, so a new
  script needs no install change.
- Measured (spec, Views and Outcomes):
  - `acli` plain view drops comments, `--json` has them; missing or hidden key: exit 1,
    `Issue does not exist or you do not have permission to see it.`
  - `glab mr view <url>` fails outside a GitLab checkout; `glab mr view <n> -R <host>/<project>` works anywhere;
    missing MR: exit 1, `404 Not Found`.
  - `acli` site `magnolia-cms.atlassian.net`; `glab` logged in to `gitlab.magnolia-platform.com`;
    `glow`, `pandoc`, `bat` in `/opt/homebrew/bin`.

## Development Approach

- **testing approach**: TDD for `OpenLinkLaunch` in `agtermCore` and for `agterm-open-link` in pytest.
  The `openLink` change is a thin launch, checked by hand in an isolated Debug instance.
- run only the tests a task touches; the full gates run once, in the verification task.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy

- **unit tests (`OpenLinkLaunchTests`)**: `handles` true for `http`/`https`, false for `mailto`/`ftp`;
  argv: unsplit → no `--pane`; split right → `--pane right`; socket present or absent; the URL always last,
  after `--`; no `--cwd`.
- **pytest (`tests/test_agterm_open_link.py`)**, with `agtermctl`, `acli`, `glab`, `glow`, `pandoc`, `less` and
  `open` stubbed on PATH and their argv recorded:
  - classification: Jira `/browse/KEY`; MR; MR tab `/diffs`, with a query, with a fragment; host outside
    `gitlab.hosts`; lookalike host (`gitlab.magnolia-platform.com.evil.test`); `user@host`; `:port`; upper-case
    host; Jira host with another path; lowercase or malformed key; `mailto:` and `file:` never reach `open`;
  - the MR canonical URL and the `-R <host>/<project>` argument are rebuilt from the parts;
  - config: missing file gives the defaults; each `view` value; an unknown `view` value means `tui`;
  - `tui` MR: the helper runs `glab mr view <n> -R <host>/<project> --comments` with `GLAB_PAGER=cat` and a
    timeout, glab by absolute path; the view file ends with the canonical URL and has no control bytes from an
    ESC planted in the stub's output; the overlay runs `less -R <file>`;
  - the `Fetching <item>…` HUD is opened before a fetch and closed on every path; view files older than a day
    are removed on start;
  - `tui` Jira: `acli … --json` fetched once with a timeout; the Markdown carries summary, status, assignee,
    description, every comment and the browse URL; the overlay runs `glow -p <file>` with `PAGER='less -R'`;
  - ADF to Markdown on `tests/fixtures/jira-workitem.json`: paragraph, heading, both list kinds, code block,
    quote, link, mention, the four inline marks, an unknown node falling back to its text, and an ESC and a C1
    byte in text that do not survive;
  - `html`: `pandoc -f markdown-raw_html-raw_attribute --standalone` with the CSP header; a raw `<img>` in a
    description does not reach the page as a tag; the page carries `default-src 'none'`; shown with
    `session overlay open --html`, no `--js`;
  - outcomes, from the measured shapes: Jira not found → HUD, nothing opened; MR 404 → HUD; tool missing →
    `open` plus HUD; other failure or timeout → `open`; an exception inside the helper → `open`.
- **manual**: isolated Debug instance, one click per row of the spec's Outcomes table.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## What Goes Where

- Tasks 1, 2, 6 and 7: this repo (the fork), one feature branch in a worktree off `main`.
- Tasks 3 to 5: `~/dev/agterm-agents`, branch `clickable-links` in a worktree off `clickable-file-paths`
  (it reuses that branch's helpers and lands after it). Never in the shared main checkout.
- The ghostty `link` rule and `open-link.conf` are Sasha's files: Task 7 prints them, Sasha adds them.

## Implementation Steps

### Task 1: `OpenLinkLaunch`

**Files:**
- Create: `agtermCore/Sources/agtermCore/OpenLinkLaunch.swift`
- Create: `agtermCore/Tests/agtermCoreTests/OpenLinkLaunchTests.swift`

- [x] failing `OpenLinkLaunchTests` first, as listed in Testing Strategy
- [x] `helperName = "agterm-open-link"`; `handles(_ url: URL) -> Bool`; `arguments(url:session:pane:socket:)`,
      shaped like `OpenPathLaunch.arguments` without `--cwd` and `--line`
- [x] `swift test --filter OpenLinkLaunchTests` passes

### Task 2: route web clicks from a pane to the helper

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`

- [ ] `runAgentHelper` returns `Bool` (`@discardableResult`): true once `process.run()` succeeded
- [ ] `.open(url)`: when `OpenLinkLaunch.handles(url)` and the surface has a session,
      `runAgentHelper(OpenLinkLaunch.helperName, …)`; `NSWorkspace.shared.open(url)` when it returns false or
      either condition fails
- [ ] `make build` compiles

### Task 3: `agterm-open-link` skeleton, classification, browser view (agterm-agents)

**Files:**
- Create: `bin/agterm-open-link`
- Create: `tests/test_agterm_open_link.py`

- [ ] failing pytest cases first: classification, host spoofing, canonical MR URL, config, the browser outcomes,
      the catch-all
- [ ] argparse `--target`, `--pane`, `--socket`, then `--` and the URL; PATH append as in `agterm-open-path`
- [ ] `classify(url, config) -> ("jira", key) | ("mr", host, project, number) | ("other", url)`, using
      `urlparse(url).hostname` compared exactly
- [ ] `~/.config/agterm/open-link.conf` reader, `key = value`, defaults from the spec, unknown view means `tui`
- [ ] `open_browser(url)`: re-checks `http`/`https`, runs `open`
- [ ] `main` wraps everything; any exception ends in `open_browser` when the URL is `http`/`https`
- [ ] `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q` passes

### Task 4: TUI views (agterm-agents)

**Files:**
- Modify: `bin/agterm-open-link`
- Modify: `tests/test_agterm_open_link.py`
- Create: `tests/fixtures/jira-workitem.json`

- [ ] capture `acli jira workitem view MGNLPN-823 --fields summary,status,assignee,description,comment --json`,
      trim it to one example of each ADF node the converter covers, replace names and text with neutral ones,
      and add an ESC and a C1 byte to one text node
- [ ] failing cases first: ADF conversion, control stripping, the Jira and MR overlay commands, and the
      measured not-found, tool-missing, failure and timeout outcomes
- [ ] `adf_to_markdown(node)`: the nodes and marks from the spec; unknown nodes give their text; every text run
      stripped of C0 controls except newline and tab, and of C1 controls
- [ ] Jira: fetch once (timeout 10 s), write `~/.local/state/agterm-open-link/<KEY>.md` (title, status line,
      assignee, description, comments with author and date, the browse URL), overlay `glow -p <file>` with
      `PAGER='less -R'`
- [ ] MR: the helper runs `glab mr view <n> -R <host>/<project> --comments` (`GLAB_PAGER=cat`, timeout 10 s),
      strips control bytes, appends the canonical URL, writes `<project>-<n>.txt`; overlay `less -R <file>`
- [ ] `strip_controls(text)` shared by the Jira converter and the MR capture
- [ ] `Fetching <item>…` HUD before a fetch, closed before the view opens or the fallback runs
- [ ] ➕ the HUD and the overlay share one slot and `overlay open` is refused while a HUD holds it, so a test
      asserts `session hud close` comes before `session overlay open`
- [ ] ➕ glab runs with `NO_COLOR=1`, and `strip_controls` removes whole CSI and OSC sequences before single
      control bytes, so no `[1m` remnant survives
- [ ] on start, delete files older than one day in `~/.local/state/agterm-open-link/`
- [ ] outcome detection from exit status plus the measured stderr text; HUD texts from the spec
- [ ] overlay wrapper reuses the `agterm-open-path` pattern; every value through `shlex.quote`; tools by absolute path
- [ ] `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q` passes

### Task 5: HTML view (agterm-agents)

**Files:**
- Modify: `bin/agterm-open-link`
- Modify: `tests/test_agterm_open_link.py`

- [ ] failing cases first: Jira and MR `html` views, a raw `<img>` that does not survive as a tag, the CSP header,
      and an MR `html` fetch timing out: the HUD closes and the browser opens
- [ ] MR Markdown from `glab mr view <n> -R <host>/<project> -F json` (title, state, author, description)
      plus the `--comments` text; Jira reuses Task 4's Markdown
- [ ] `pandoc -f markdown-raw_html-raw_attribute --standalone --metadata title=<item> --include-in-header <csp>`,
      the header holding `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">`, to
      `~/.local/state/agterm-open-link/<name>.html`, shown with `session overlay open --html <file>`, never `--js`
- [ ] ➕ a minimal `--template` instead of pandoc's default, whose hard-coded light background fights a dark overlay
- [ ] `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q` passes

### Task 6: fork docs

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `.claude/rules/libghostty.md`
- Modify: `FORK-NOTES.md`
- Modify: `CHANGELOG-fork.md`

- [ ] `LinkPolicy` header comment: one clause, a pane's web link goes through `agterm-open-link` when installed
- [ ] `libghostty.md`, the `link` section: the same fact, and that clicks inside an overlay still go to the browser
- [ ] `FORK-NOTES.md`: a **Clickable Jira keys and MR links** line beside **Clickable file paths**
- [ ] `CHANGELOG-fork.md`: an entry in the next release section

### Task 7: verify

- [ ] fork: `swift test`, `make test-app`, `make lint`, `make build`
- [ ] agterm-agents: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/ -q`
- [ ] isolated Debug instance with a copy of `ghostty.conf` plus the Jira rule; one click per Outcomes row
- [ ] measure the delay a plain web link now pays (helper start to `open`), write it into the spec's Open points
- [ ] print for Sasha: the `link` line for `ghostty.conf` and a sample `open-link.conf`
- [ ] move this plan and the spec to `docs/plans/completed/`

## Post-Completion

- After a week of use, decide whether the generic Jira key pattern is too noisy and switch to a key list.
- If `glab mr view` does not style comments, move the MR TUI view to the JSON-to-Markdown-to-`glow` route.
- GitLab issues and pipelines: add a classifier row each.

<!-- plan-review: planning:plan-review 2026-09-30 findings=19 resolved -->
