# Clickable forge references

## Contents

- [Overview](#overview)
- [Context (from discovery)](#context-from-discovery)
- [Development Approach](#development-approach)
- [Testing Strategy](#testing-strategy)
- [Progress Tracking](#progress-tracking)
- [What Goes Where](#what-goes-where)
- [Implementation Steps](#implementation-steps)
  - [Stage 1: Swift route](#stage-1-swift-route)
  - [Stage 2: helper core and commits](#stage-2-helper-core-and-commits)
  - [Stage 3: GitLab issues, pipelines and jobs](#stage-3-gitlab-issues-pipelines-and-jobs)
  - [Stage 4: GitHub](#stage-4-github)
  - [Stage 5: docs and gates](#stage-5-docs-and-gates)
- [Post-Completion](#post-completion)

## Overview

Shift+Cmd+click on `!482`, `#12`, a commit hash, `group/proj!12`, `group/proj#34` or `group/proj@sha`,
or on a GitLab issue, commit, pipeline or job URL, or on a GitHub PR, issue or commit URL.
The item opens in its forge's configured view. A commit always opens a plannotator review of its diff.
Anything that cannot be resolved shows a HUD.
Design, recognition regexes, views, outcomes, security and decisions: `docs/plans/20260930-forge-refs-spec.md`.
This plan does not repeat them. Each task names the spec section it implements.

## Context (from discovery)

- Fork (this worktree, branch `clickable-links`):
  - `agtermCore/Sources/agtermCore/LinkPolicy.swift`: `disposition(for:)`, `LinkDisposition`, `xchatScheme`,
    `xchatDisposition`, `openPathDisposition`. The new scheme follows the xchat shape but skips `URL(string:)`.
  - `agtermCore/Sources/agtermCore/OpenLinkLaunch.swift`: `arguments(url:session:pane:socket:)`, no `--cwd`.
    `OpenPathLaunch.arguments` is the `--cwd` pattern.
  - `agterm/Ghostty/GhosttySurfaceView+Input.swift`: `openLink` switch, `openFilePath`, `openWebLink`,
    `runAgentHelper`. The switch in `openLink` is the only production consumer of `LinkDisposition`.
  - `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`, `OpenLinkLaunchTests.swift`: the suites to extend.
  - `.claude/rules/fork-merge.md` frontmatter `flagged` already lists `LinkPolicy.swift`;
    `OpenLinkLaunch.swift` and `GhosttySurfaceView+Input.swift` are not listed.
- agterm-agents (`/Users/sasha/dev/agterm-agents/.worktrees/clickable-links`, branch `clickable-links`):
  - `bin/agterm-open-link`: `classify` returns tuples; `show` and `main` branch on `kind[0] == "jira"`;
    `read_config` checks only `jira.view` and `gitlab.view`; `gitlab_hosts` returns a set;
    `review_mr` and `review_prompt` are the plannotator pattern; `write_view` uses `mkstemp`, so a file is
    `<stem>.<random><ext>`; `fetching`, `hud`, `open_overlay`, `open_page`, `render_html` are reused.
  - `bin/agterm-open-path`: `HOST_RES`, `pane_command` and the host search in `far_pane` are the far-pane check to copy.
  - `tests/test_agterm_open_link.py`: `STUB` answers one output per tool, chosen by env vars and a few argv
    special cases for `glab`. `STUBS` already holds `less` and `agterm-plannotate`, but not `git` or `gh`.
  - `share/agterm-open-link/`: holds `github-markdown.css`; `links.conf` goes beside it.
- No local clone of `agterm-linux` exists (`wherefile agterm-linux`: no hit).
- `.claude/rules/settings.md` says agterm's loader expands `config-file` includes through
  `ghostty_config_load_recursive_files`. Whether it expands `~` is not yet known.

## Development Approach

- **testing approach**: TDD. Every task starts with a failing test, then the code, then the check command.
- The `openLink` edit is checked by `make build`. Everything that needs a running app is in Post-Completion,
  for Sasha. No task launches, quits or drives an agterm instance.
- Run only the tests a task touches. The full fork gates run once, in the last task.
- Check commands, used verbatim below:
  - helper: in `/Users/sasha/dev/agterm-agents/.worktrees/clickable-links`,
    `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`;
  - Swift: `cd agtermCore && swift test --filter <Suite>`.
- Every task ends with a commit in the repository it edited (see What Goes Where).
- Never execute `agterm`/`agtermctl` against the default socket, never launch or quit the app.
- **CRITICAL: update this plan file when scope changes during implementation.**

## Testing Strategy

- **Swift, `LinkPolicyTests` and `OpenLinkLaunchTests`**: the cases listed in the spec's Tests section, fork part.
- **pytest, `tests/test_agterm_open_link.py`**: the cases in the spec's Tests section, agterm-agents part.
  - Task 7 makes `STUB` answer by argv, so one run can call `git`, `glab api`, `gh api` or `agtermctl` several
    times with different answers. It adds `git` and `gh` to `STUBS`.
  - A stubbed `agtermctl tree --json` answers with a session whose `restoreCommand` is either empty (local pane)
    or a mosh line (far pane).
- **Failure shapes** are measured against the real tools before the tests that use them (Tasks 12, 13, 15, 19).
  Fixtures are trimmed from real answers, with names and text made neutral.
- **manual**: Sasha, after the plan, as listed in Post-Completion.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## What Goes Where

| stage | repository edited and committed to | commit command |
|---|---|---|
| 1. Swift route | the fork, this worktree | `git -C /Users/sasha/dev/oss/agterm-vim/.claude/worktrees/clickable-links commit …` |
| 2. Helper core and commits | agterm-agents worktree, plus the fork spec edit for Tasks 14, 15 and 19 | `git -C /Users/sasha/dev/agterm-agents/.worktrees/clickable-links commit …` |
| 3. GitLab issues, pipelines and jobs | agterm-agents worktree, plus the fork spec edit for Tasks 14, 15 and 19 | same as stage 2 |
| 4. GitHub | agterm-agents worktree, plus the fork spec edit for Tasks 14, 15 and 19 | same as stage 2 |
| 5. Docs and gates | Tasks 24, 25, 28: the fork. Task 26: both. Task 27: neither | as per repository |

- Never the shared main checkout of agterm-agents.
- `~/.config/agterm/ghostty.conf` and `open-link.conf` are Sasha's files. Task 27 prints the lines; Sasha adds them.

## Implementation Steps

### Stage 1: Swift route

#### Task 1: check `agterm-linux` for an exhaustive switch on `LinkDisposition`

- [ ] find which repository `agterm-linux` takes `agtermCore` from (its `Package.swift` dependency, through
      GitHub with `fork:true`, or a shallow read-only clone into the session scratchpad)
- [ ] it builds from upstream `umputun/agterm`: write that one line here; the task ends
- [ ] it builds from this fork: record each `switch` over `LinkDisposition` with no `default`, with its file.
      One found: add a ⚠️ task to tell Sasha before Task 2 lands; do not edit that repository
- [ ] check: the finding is written into this task

#### Task 2: `LinkPolicy` accepts the `agterm-ref:` scheme

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`

- [ ] failing tests first: the five accepted payloads give `.ref(payload)`, `#` stays in the payload, and every
      refused case from the spec's Tests section gives `.ignore`
- [ ] `refScheme = "agterm-ref"`, not in `permittedSchemes`; `LinkDisposition.ref(String)`
- [ ] in `disposition(for:)`, before the scheme regex: the `agterm-ref:` prefix goes to `refDisposition` with the
      rest of the raw string; the three anchored patterns, the 300-character cap, the newline guard (spec, Recognition)
- [ ] `openLink`'s switch gets a temporary `case .ref: return`, so the app target still compiles
- [ ] check: `cd agtermCore && swift test --filter LinkPolicyTests`
- [ ] commit in the fork

#### Task 3: `LinkPolicy` reclaims dotted cross-project refs from the path link

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`

- [ ] failing tests first: schemeless `group/my.proj!12` and `group/proj!12.` give `.ref`; `src/a.swift` still
      gives `.openPath`; `a/b.c#x`, schemeless `!12` and schemeless `c865bc6c` still give `.ignore`
- [ ] in the schemeless branch: when `openPathDisposition` gives `.ignore`, strip trailing `.`, `,`, `;`, `:`, `)`
      and try the cross-project pattern only
- [ ] check: `cd agtermCore && swift test --filter LinkPolicyTests`
- [ ] commit in the fork

#### Task 4: `OpenLinkLaunch.arguments(ref:session:pane:socket:)`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/OpenLinkLaunch.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/OpenLinkLaunchTests.swift`

- [ ] failing tests first: `--cwd` from `cwd(for:)` for the primary pane and for a split's right pane;
      `--socket` when given; `--pane` as for URLs; the argv ends `-- agterm-ref:<payload>`; the URL argv unchanged
- [ ] the new function, shaped like `OpenPathLaunch.arguments`
- [ ] check: `cd agtermCore && swift test --filter OpenLinkLaunchTests`
- [ ] commit in the fork

#### Task 5: `openLink` routes `.ref` to the helper

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`

- [ ] replace the temporary case with `case let .ref(payload): openRef(payload)`
- [ ] `openRef`: `guard let session else { return }`; the pane as in `openFilePath`;
      `runAgentHelper(OpenLinkLaunch.helperName, arguments: OpenLinkLaunch.arguments(ref:…), …)`; no `NSWorkspace` fallback
- [ ] check: `make build`
- [ ] commit in the fork

### Stage 2: helper core and commits

Every task in this stage edits `bin/agterm-open-link` and `tests/test_agterm_open_link.py` in agterm-agents,
unless it names more files, and ends with
`git -C /Users/sasha/dev/agterm-agents/.worktrees/clickable-links commit …`.

#### Task 6: `Item` replaces the tuples

- [ ] failing tests first: `test_classify` and the other tuple-shaped cases rewritten against `Item`
      (`kind`, `forge`, `host`, `project`, `number`, `sha`; `url` and `label` properties); the view key comes from
      `Item.forge` (`jira.view`, `gitlab.view`, `github.view`); a commit ignores every view key
- [ ] `classify` returns `Item` for Jira, MR and other; `show` dispatches on `Item.kind` through a table of builders
- [ ] no behaviour change for Jira and MR: every existing test passes
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 7: `STUB` answers by argv

- [ ] failing tests first:
  - run the stub script directly, twice, with the same `STUB_MAP` and different argv: each run gets its own
    fixture's answer;
  - with the keys `x/1` and `x/1/jobs` in one map, argv holding `x/1/jobs` gets the `x/1/jobs` answer and argv
    holding only `x/1` gets the `x/1` answer
- [ ] `STUB` reads an optional JSON map from an env var (for example `STUB_MAP`): argv substring → `{out_file, err, exit}`.
      Of the keys found in the joined argv, the LONGEST wins. The plan's own API paths nest: `pipelines/55` is inside
      `pipelines/55/jobs`, `jobs/77` inside `jobs/77/trace`, `commits/<sha>` inside `commits/<sha>/diff`, and
      `issues/12` inside `issues/12/comments`. With no map, or no key found, today's env-var behaviour holds,
      so existing tests stay as they are
- [ ] `git` and `gh` join `STUBS`; the module docstring's stub list follows
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 8: the rules file and its regex table

**Files:**
- Create: `share/agterm-open-link/links.conf`

- [ ] failing tests first: every `link =` line parses as `open:agterm-ref:$0,<regex>`; the sample lines from the
      spec's Recognition section give exactly the listed matches and non-matches
- [ ] the three rules from the spec, in order, one comment line each
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 9: `--cwd`, payload validation and the far-pane check

- [ ] failing tests first: a payload that fails the three anchored patterns gives HUD `Could not open …` and runs no
      tool; a stubbed far pane (mosh `restoreCommand`) and a set `remoteHost` give HUD `Remote pane: !482 not resolved`;
      a relative or missing `--cwd` gives its HUD; a cross-project ref in a far pane is not refused
- [ ] `--cwd` argument; `agterm-ref:` payloads go to `resolve_ref`, which raises `Unresolved(message)` for a HUD
- [ ] copy only `pane_command`, `HOST_RES` and the host search with its check from `far_pane` in `agterm-open-path`,
      with a one-line pointer to it. Not `KEY_RE`, not `ZMX_DIR_RE`
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 10: repository check, origin parsing and forge choice

- [ ] failing tests first:
  - a short ref or bare hash with `--cwd` outside a repository gives HUD `Not in a git repository: …`; a cross-project ref there does not;
    `rev-parse --show-toplevel` gets `-c core.fsmonitor=`;
  - scp, `ssh://` and `https` origins; `.git` and a trailing `/`; a lookalike host; no origin; an unknown host;
  - the cross-project host choice: origin forge, then `gitlab.default_host`, then the FIRST of `gitlab.hosts`
    in file order (tested with two hosts), then HUD `No GitLab host for …`;
  - a three-segment project never goes to GitHub;
  - `github.view` with an unknown value reads as `tui`
- [ ] `git -c core.fsmonitor= -C <cwd> rev-parse --show-toplevel`, then `remote get-url origin`;
      the two anchored origin patterns from the spec
- [ ] config keys `github.hosts`, `github.view`, `gitlab.default_host`; `github.view` joins the view check in
      `read_config`; the default host comes from an ordered parse of `gitlab.hosts`, not from the `gitlab_hosts` set
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 11: resolved refs reuse the MR view; the catch-all

- [ ] failing tests first:
  - `!482` in a GitLab checkout and `magnolia/ui!482` anywhere open the same overlay and the same `glab` calls as a
    click on the MR URL;
  - a crash before resolution gives HUD `Could not open !482`; a crash after it opens the MR URL in the browser;
  - in-process, with no dependency on Task 12: an `Item` built directly with `url = None` (the shape of a
    local-only commit: no origin, or an unknown forge), passed to the catch-all with a raised error, gives HUD
    `Could not open …` and never runs `open`
- [ ] `fallback_url`, set once an `Item` with a URL exists
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 12: local commit review

- [ ] measure first, in a scratch repository under the session scratchpad with enough commits that two share a
      4-hex-character prefix: the exit status and stderr of `rev-parse --verify --quiet <4 hex>^{commit}`
      for that ambiguous prefix. The test below uses that shape
- [ ] failing tests first:
  - a local hit runs `rev-parse --verify --quiet --end-of-options <h>^{commit}`, then `show` with
    `--no-color --no-ext-diff --no-textconv --diff-merges=first-parent --format= --patch <full sha>`;
    `show` gets the full sha from `rev-parse`, not the clicked prefix;
  - both calls get `-c core.fsmonitor=`, and `show` runs with `GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0`;
  - `agterm-plannotate --review <patch>` starts detached; the patch file name starts with `<name>-<short sha>.`
    (only the stem prefix is checked, since `write_view` adds a random part);
  - `<name>` is the origin project when known, else the basename of `rev-parse --show-toplevel`;
  - no `Fetching` HUD on the local path;
  - a local miss with no known forge gives HUD `No commit c865bc6c in agterm-vim`;
  - the ambiguous shape gives HUD `Ambiguous commit …`
- [ ] `review_commit`, shaped like `review_mr` without the overlay close; a local-only commit has `url = None`
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 13: GitLab commit fetch and commit URLs

- [ ] measure first: `glab api --hostname gitlab.magnolia-platform.com projects/<p>/repository/commits/<short sha>`
      (does a short sha resolve), the same for a missing sha, and `--paginate` output on the `/diff` endpoint
      (one array or several); trim one real answer into `tests/fixtures/gitlab-commit-diff.json`
- [ ] failing tests first: a local miss with a GitLab origin fetches from the forge; `magnolia/ui@c865bc6c` and a
      `/-/commit/<SHA>` URL (upper-case hex lower-cased) go to the forge; rebuilt headers for new, deleted and
      renamed files; missing sha gives HUD `No commit c865bc6c in magnolia/ui`
- [ ] the commit row of the URL table in the spec's Recognition section; the GitLab fetch from Commit review
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 14: check, by reading only, that `config-file` expands `~`

- [ ] fetch ghostty's `src/config/` path handling at `683d8db` raw into the session scratchpad; read how a
      `config-file` value is parsed and whether `~/` is expanded
- [ ] read agterm's loader path into `ghostty_config_load_recursive_files` for anything that changes that
- [ ] no expansion: Task 27 prints an absolute path, and the spec's Decisions entry for the rule file says so
- [ ] check: the answer, with the file and function it comes from, is written into this task and into that
      Decisions entry
- [ ] commit the spec edit in the fork

### Stage 3: GitLab issues, pipelines and jobs

Every task in this stage edits `bin/agterm-open-link`, `tests/test_agterm_open_link.py` and fixtures under
`tests/fixtures/` in agterm-agents, and ends with
`git -C /Users/sasha/dev/agterm-agents/.worktrees/clickable-links commit …`.

#### Task 15: measure the GitLab failure shapes

- [ ] `glab issue view <n> -R https://gitlab.magnolia-platform.com/<p> -F json` for a real and a missing issue:
      does the URL form work, what is the exit status and stderr
- [ ] `glab api` on a missing pipeline and a missing job: exit status and stderr
- [ ] trim one real answer each into fixtures: issue, issue discussions, pipeline, pipeline jobs, pipeline bridges,
      job, job trace (with `\r` progress lines and section markers kept)
- [ ] check: the shapes are written into the spec's Outcomes section, replacing "Unmeasured today"
- [ ] commit the fixtures in agterm-agents and the spec edit in the fork

#### Task 16: GitLab issues

- [ ] failing tests first: `/-/issues/N` and `/-/work_items/N` classify as issue; `#12` in a GitLab checkout and
      `magnolia/ui#12` resolve to it; the Markdown carries title, state, author, assignees, labels, description,
      threads without system notes, the URL; TUI and HTML views, the page runs no script; missing issue gives HUD
      `No such issue: magnolia/ui#12`
- [ ] the issue row in `classify`, `issue_markdown`, the issue builder
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 17: GitLab pipelines

- [ ] failing tests first: `/-/pipelines/N` and a tab such as `/failures` classify as pipeline; the Markdown has the
      header fields and one table per stage in pipeline order, bridges included; TUI and HTML views; missing pipeline
      gives HUD `No such pipeline: magnolia/ui pipeline 55`; the three `glab api` calls get their own answers through
      the argv map
- [ ] the pipeline row, `pipeline_markdown`, the builder; the three `glab api` calls under one `Fetching` HUD
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 18: GitLab jobs

- [ ] failing tests first: `/-/jobs/N` and `/-/jobs/N/raw` classify as job; only the text after the last `\r` of a
      line is kept; section markers are removed; the tail is 300 lines; control bytes are gone; the TUI overlay runs
      `less +G <file>`; the HTML page holds the tail in one fence; missing job gives HUD `No such job: magnolia/ui job 77`
- [ ] the job row, `job_text`, the builder
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

### Stage 4: GitHub

Every task in this stage edits `bin/agterm-open-link`, `tests/test_agterm_open_link.py` and fixtures under
`tests/fixtures/` in agterm-agents, and ends with
`git -C /Users/sasha/dev/agterm-agents/.worktrees/clickable-links commit …`.

#### Task 19: measure the GitHub failure shapes

- [ ] against a public repository: `gh api repos/O/R/issues/N` for an issue, a PR (the `pull_request` key) and a
      missing number; `gh api -H "Accept: application/vnd.github.diff" repos/O/R/commits/<sha>` for a real and a bad sha;
      `gh pr view N -R github.com/O/R --json …` for a missing PR
- [ ] trim one real answer each into fixtures: issue, issue comments, PR view, PR line comments, commit diff
- [ ] check: the shapes are written into the spec's Outcomes section
- [ ] commit the fixtures in agterm-agents and the spec edit in the fork

#### Task 20: GitHub classification and `#N` resolution

- [ ] failing tests first: the three GitHub URL rows, host spoofing on them, `O` and `R` limits; `/issues/N` and
      `#N` in a GitHub checkout call the issues API once and pick PR or issue from `pull_request`; `!12` in a GitHub
      checkout gives HUD `GitHub has no !N references: !12`; `gh` gets `GH_PAGER=cat NO_COLOR=1 GH_PROMPT_DISABLED=1
      GH_NO_UPDATE_NOTIFIER=1`
- [ ] the GitHub rows in `classify`, the GitHub branch of `resolve_ref`
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 21: GitHub issues

- [ ] failing tests first: the Markdown from the resolution answer plus the comments call, each answered through the
      argv map; TUI and HTML views, no script on the page; `github.view = browser` opens the browser; missing gives HUD
      `No such pull request or issue: owner/repo#12`
- [ ] `gh_issue_markdown`, the builder, reusing the resolution answer rather than fetching it twice
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 22: GitHub pull requests

- [ ] failing tests first: the Markdown has body, conversation comments, review bodies, and line-comment threads
      grouped by `in_reply_to_id` with `— on path:line`, oldest first; the TUI `r` prompt and the page's Review button
      run `--review`, which fetches `gh pr diff N -R H/O/R --color never` and starts plannotator; `--review` on a PR URL
      is honoured, as on an MR URL
- [ ] `pr_markdown`, the builder, `review_pr` beside `review_mr`
- [ ] `pr` joins `mr` in the review checks in `show` and `main`; `review_prompt` says "this pull request" for a PR
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

#### Task 23: GitHub commits

- [ ] failing tests first, in a stubbed GitHub checkout (`remote get-url origin` answers `git@github.com:owner/repo.git`):
      a `/commit/<SHA>` URL, `owner/repo@c865bc6c`, and a local miss all fetch the diff with the
      `application/vnd.github.diff` header and start plannotator; a bad sha gives HUD `No commit c865bc6c in owner/repo`
- [ ] one more case: the same `owner/repo@c865bc6c` clicked with `--cwd` at `$HOME` (no repository) goes to the GitLab
      default host, not to GitHub
- [ ] the GitHub branch of the forge commit fetch
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
- [ ] commit in agterm-agents

### Stage 5: docs and gates

#### Task 24: fork rules and `LinkPolicy` header

**Files:**
- Modify: `.claude/rules/libghostty.md`
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`

- [ ] `libghostty.md`, Terminal links: six dispositions; `.ref` and why it skips `URL(string:)`; the reclaim of dotted
      refs from the built-in path link; far panes are the helper's decision; the Control API exemption (spec, Control API);
      the spec cited by its final path, `docs/plans/completed/20260930-forge-refs-spec.md`
- [ ] `LinkPolicy` header comment: one clause for `.ref`
- [ ] check: `cd agtermCore && swift build`, then read the Terminal links section back against the spec
- [ ] commit in the fork

#### Task 25: `FORK-NOTES.md` and `CHANGELOG-fork.md`

**Files:**
- Modify: `FORK-NOTES.md`
- Modify: `CHANGELOG-fork.md`

- [ ] `FORK-NOTES.md`, the libghostty group: a **Clickable forge references** line beside
      **Clickable Jira keys and MR links**, pointing at the Terminal links section
- [ ] `CHANGELOG-fork.md` under `## Unreleased`, New Features: one user-facing entry naming the refs, the URL kinds,
      the commit review, the far-pane HUD, and what it needs (`gh`, `glab`, `agterm-plannotate`, the `config-file` line)
- [ ] answer the `.claude/rules/release.md` question: does this feature add a file to `flagged` in `fork-merge.md`'s
      frontmatter? `LinkPolicy.swift` is already listed. Decide for `OpenLinkLaunch.swift` and
      `GhosttySurfaceView+Input.swift`, add any that qualify, and write the answer and its reason in the commit message
- [ ] check: both entries read back against the spec's What the user does section
- [ ] commit in the fork

#### Task 26: the helper's spec docs

**Files:**
- Modify: `bin/agterm-open-link` (agterm-agents)
- Modify: `share/agterm-open-link/links.conf` (agterm-agents)
- Modify: `docs/plans/20260930-forge-refs-spec.md` (fork)

- [ ] the helper's docstring: the ref route, `--cwd`, the new kinds, and the forge-refs spec cited by its final path,
      `docs/plans/completed/20260930-forge-refs-spec.md`, beside the clickable-links one
- [ ] the spec describes the system as built: measured failure shapes in Outcomes, the `~` answer in Decisions,
      every ➕ task from this plan that changed a design point
- [ ] check: `uv run --quiet --python 3.12 --with pytest python -m pytest tests/test_agterm_open_link.py -q`
      (the docstring is in the tested file)
- [ ] commit in agterm-agents and in the fork

#### Task 27: print the config lines for Sasha

- [ ] print the `config-file` line for `~/.config/agterm/ghostty.conf` with the main-checkout path,
      `~/dev/agterm-agents/share/agterm-open-link/links.conf` (or its absolute form, as Task 14 settled),
      because the main checkout outlives the worktree
- [ ] print this note with it: "exists at that path only after agterm-agents merges `clickable-links`;
      Sasha adds the `config-file` line after that merge"
- [ ] print the new `open-link.conf` keys with their defaults (spec, Config)
- [ ] check: `test -f /Users/sasha/dev/agterm-agents/.worktrees/clickable-links/share/agterm-open-link/links.conf`
      (the worktree copy), and the printed keys match what `read_config` reads

#### Task 28: gates

- [ ] fork, once, from the worktree root: `(cd agtermCore && swift test)`, then `make test-app`, then `make lint`
- [ ] agterm-agents: `uv run --quiet --python 3.12 --with pytest --with pyyaml python -m pytest tests/ -q`;
      known base failures are recorded, not fixed
- [ ] move this plan and the spec to `docs/plans/completed/`. Nothing to repoint: Tasks 24 and 26 already cite the final path
- [ ] commit in the fork

## Post-Completion

**Manual verification (Sasha)**, in a separate isolated Debug instance, never the deployed app:

- launch with `open -n`, a short `/tmp` `AGTERM_STATE_DIR`, `mkdir -p "$AGTERM_STATE_DIR/windows"`, and copies of
  `ghostty.conf` (plus the `config-file` line from Task 27) and `open-link.conf` in `<stateDir>/config`
- Shift+Cmd hover on `c865bc6c` underlines it: this confirms the `config-file` include and Task 14's `~` answer
- one click per row of the spec's Outcomes table, in a local GitLab checkout, a local GitHub checkout, `$HOME`,
  and a mosh row
- stop only that instance's PID with SIGTERM, and check with `lsappinfo list | grep agterm.debug` that no Dock tile is left

**Follow-ups:**

- Far panes: resolve short refs on the host through `agterm-open-path --zmx-key`'s cwd lookup (spec, Decisions).
- An ssh host alias in the origin: resolve it with `ssh -G` if the `Unknown forge` HUD shows up in practice.
- Refs inside fetched descriptions: rewrite them into URLs, so they are clickable inside a view.

<!-- plan-review: planning:plan-review 2026-10-01 findings=21 resolved -->
