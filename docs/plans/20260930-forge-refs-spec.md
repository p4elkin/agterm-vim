# Clickable forge references: short refs, commits, issues, pipelines, jobs, GitHub — spec

Builds on `docs/plans/completed/20260930-clickable-links-spec.md` (Jira keys and GitLab MR URLs).
Read that one first. This spec only says what changes.

## Contents

1. [Problem](#problem)
2. [What is true today](#what-is-true-today)
3. [What the user does](#what-the-user-does)
4. [Design](#design)
5. [Recognition](#recognition)
6. [Forge resolution](#forge-resolution)
7. [Items and views](#items-and-views)
8. [Commit review](#commit-review)
9. [Outcomes](#outcomes)
10. [Config](#config)
11. [Security boundary](#security-boundary)
12. [Control API](#control-api)
13. [Tests](#tests)
14. [Docs to update](#docs-to-update)
15. [Stages and size](#stages-and-size)
16. [Out of scope](#out-of-scope)
17. [Decisions](#decisions)
18. [Open points](#open-points)

## Problem

Agents print short forge references all the time: `!482`, `#12`, `c865bc6c`, `magnolia/ui!482`.
None of them is clickable today.
Full GitLab URLs for issues, commits, pipelines and jobs are clickable, but they open the browser.
GitHub URLs also open the browser.

The Jira and MR work already has the shape: a click reaches `agterm-open-link`, which picks a view.
This work adds more kinds of item to that helper, and a way for text that is not a URL to reach it.

## What is true today

Swift, in this fork:

- `openLink` in `agterm/Ghostty/GhosttySurfaceView+Input.swift` switches over `LinkPolicy.disposition(for:)`.
  `openWebLink` sends a pane's `http`/`https` link to `agterm-open-link` and falls back to `NSWorkspace`.
  `runAgentHelper` returns whether it launched.
- `LinkPolicy` already has one private scheme, `xchatScheme` (`agterm-xchat`), minted only by a user `link` rule.
  It parses the link with `URL(string:)`.
  A ref payload cannot take that path: in `agterm-ref:group/proj#34`, Foundation moves `34` into the fragment.
- `OpenLinkLaunch.arguments(url:session:pane:socket:)` passes no `--cwd`.
  `OpenPathLaunch.arguments` passes `--cwd` from `Session.cwd(for:)` (`agtermCore/Sources/agtermCore/Session.swift:686`).
- `LinkPolicy.LinkDisposition` has one production consumer, the switch in `openLink`, plus `LinkPolicyTests`.
  ⚠️ It is `public` in `agtermCore`, which the `agterm-linux` fork consumes. A new case breaks any exhaustive
  switch there. Check that clone for `LinkDisposition` before landing.

Ghostty, at `GHOSTTY_REV` `683d8db` plus `patches/ghostty/0002-link-config.patch`:

- `link = open:<template>,<regex>` substitutes `$0` with the whole match, verbatim (`expandTemplate` in the patch).
  The template ends at the first comma, so a regex may hold `{7,40}`.
- Upstream `src/Surface.zig:4366` (`linkAtPin`) runs each configured link's regex over the whole line,
  in config order, and returns the FIRST link whose match covers the mouse cell.
  The built-in URL/path link comes before every user rule (`.claude/rules/libghostty.md`, Terminal links).
- The built-in link's bare-path branch (`src/config/url.zig:103`, `bare_relative_path_branch`) matches any
  `word/…` token that has a dot somewhere. Its path characters include `!`, `#` and `@`.
  So `group/proj!12.` at the end of a sentence, or `group/ui-6.3#5`, is claimed by the built-in path link.
  Our rule never fires on it. The click arrives as schemeless raw text and `LinkPolicy` ignores it.
- A `#` inside a config value is safe. Only a line that starts with `#` is a comment (`src/cli/args.zig:1460`).

The helper, `bin/agterm-open-link` in agterm-agents (`.worktrees/clickable-links`):

- `classify` returns tuples: `("jira", key)`, `("mr", host, project, number)`, `("other", url)`.
  `show` and `main` branch on `kind[0] == "jira"` and treat everything else as an MR.
- `review_mr` fetches `glab mr diff … --raw`, closes the overlay, and starts
  `agterm-plannotate --review <patch> --target … [--pane] [--socket] --out <file>` detached.
- `agterm-plannotate --review <dir>` reviews a checkout's commits since a merge base
  (`/Users/sasha/dev/agterm-agents/bin/agterm-plannotate:340`). That is not one commit.
  `--review <patch-file>` shows a unified diff as it is (same file, line 346). Commit review uses the patch form.

Remote panes. ⚠️ This is where the brief's premise needs a correction.

- Most agent panes are p4linux shells in a Mac pane through mosh and zmx.
  `Session.remoteHost` does NOT mark them. It is set only by an agterm-to-agterm attach
  (`docs/plans/completed/20260929-clickable-file-paths-spec.md:175`).
- The Mac-side cwd of such a pane is a stale local directory. It can be a real local clone of the same repo.
  A naive `git -C <cwd>` would then resolve `!482` against the wrong checkout, silently.
- `agterm-open-path` already detects these panes from the pinned restore command in `tree --json`:
  `pane_command` and `far_pane` (`bin/agterm-open-path:219`, `:238`), using `HOST_RES` (`:55`).
  Swift cannot make this decision. The helper must.
- `tree --json` also carries `cwd` and `splitCwd` per session (`agtermCore/Sources/agtermCore/ControlProjection.swift:152`).

Prior art: `jbcontext search -p agtermCore/Sources "resolve short reference against the pane git remote origin url"`
found nothing relevant, only remote-presentation code. A grep of agterm-agents `bin/`, `hooks/` and `scripts/`
for `remote get-url` found no origin parser either. What is reused: `OpenPathLaunch`'s `--cwd`,
the shape of `LinkPolicy.xchatDisposition`, and `agterm-open-path`'s far-pane check.

## What the user does

1. Shift+Cmd+click one of:
   - `!482`, `#12`, or a commit hash `c865bc6c` in a local pane;
   - `magnolia/ui!482`, `magnolia/ui#12`, `magnolia/ui@c865bc6c` in any pane;
   - a GitLab URL for an issue, commit, pipeline or job;
   - a GitHub URL for a pull request, issue or commit.
2. An MR, PR, issue, pipeline or job opens in the view configured for its forge (`tui`, `html` or `browser`).
3. A commit always opens plannotator's review of that commit's diff.
4. Anything that cannot be resolved shows a HUD for 4 seconds, naming what failed.

## Design

```mermaid
flowchart TD
  T[ref text in a pane] -- user link rule --> R[agterm-ref:payload]
  P[dotted ref claimed by the built-in path link] -- LinkPolicy reclaims --> R
  U[forge URL in a pane] -- built-in URL link --> H
  R -- LinkPolicy .ref, OpenLinkLaunch adds --cwd --> H[agterm-open-link]
  H --> F{short ref or bare hash?}
  F -- no --> I[item: forge, host, project, kind]
  F -- yes --> A{local pane with a git origin?}
  A -- no --> X[HUD, nothing opens]
  A -- yes --> I
  I --> C{a commit?}
  C -- yes --> V[plannotator review of the diff]
  C -- no --> W[tui, html or browser view]
```

**The route is a private scheme, as the brief proposed.**
User rules template refs into `agterm-ref:$0`.
`LinkPolicy` validates the payload and returns `.ref(payload)`.
`openLink` runs `agterm-open-link` with `--cwd` and the payload.

**A resolved ref becomes the same item a URL click gives.**
The helper turns `!482` in `magnolia/ui` into `Item(kind=mr, forge=gitlab, host, project=magnolia/ui, number=482)`.
From there it takes the same path as a click on the MR URL: the same view, the same fallback to the browser.
So the only new failure class is "could not resolve", which is a HUD.

**Swift changes, in the fork:**

- `LinkPolicy`:
  - `refScheme = "agterm-ref"` beside `xchatScheme`, NOT in `permittedSchemes`;
  - a new case `LinkDisposition.ref(String)`;
  - in `disposition(for:)`, before any URL parsing: a raw string starting with `agterm-ref:` goes to
    `refDisposition` with the rest of the raw string. No `URL(string:)`, because of the fragment problem;
  - in the schemeless branch: when `openPathDisposition` returns `.ignore`, strip trailing `.`, `,`, `;`, `:`, `)`
    and try the cross-project pattern. A match is `.ref`. This is the reclaim of dotted refs;
  - the header comment gains one clause for `.ref`.
- `OpenLinkLaunch.arguments(ref:session:pane:socket:)`:
  `--cwd <session.cwd(for: pane)> --target <uuid> [--socket S] [--pane left|right] -- agterm-ref:<payload>`.
  The URL form stays as it is. Only refs get `--cwd`: a URL never resolves against a directory.
- `openLink` gets `case let .ref(payload): openRef(payload)`.
  `openRef` needs a session, as `openFilePath` does. A click in an overlay surface does nothing.
  A missing helper is a log line, as for xchat. There is no URL to hand to `NSWorkspace`.

Swift passes `--cwd` always. It cannot tell a p4linux pane from a local one.
The helper calls `tree --json` once, as `agterm-open-path` does, and refuses the cwd of a far pane.

**Helper changes, in agterm-agents:**

- `classify` returns an `Item` dataclass instead of tuples: `kind`, `forge`, `host`, `project`, `number`, `sha`,
  plus `url` and `label` properties. Seven kinds on positional tuples would be `kind[3]` everywhere.
  `test_classify` changes shape with it.
- New `--cwd` argument. A positional `agterm-ref:<payload>` goes to `resolve_ref`, which returns an `Item`
  or raises `Unresolved(message)`.
- `show` dispatches on `Item.kind` through a table of view builders, one per kind.
- The far-pane check copies `HOST_RES` and `pane_command` from `agterm-open-path`, with a one-line pointer.
  `agterm-open-path` itself copied them from `agterm-zmx`, so this is the existing pattern.
- The catch-all keeps a `fallback_url`, set once an item is known.
  Before that, a crash shows HUD `Could not open <payload>`. After it, the browser opens the item's URL.

**Rejected: a fake `https` host instead of a scheme.**
A rule `open:https://ref.agterm.invalid/$0` would need no Swift change at all, because every pane `https` click
already reaches the helper, and the helper could read the cwd from `tree --json`.
It was rejected for three reasons.
A click in an overlay, or with the helper not installed, opens the browser on a dead `.invalid` page.
The hover preview shows a URL that does not exist.
And the reclaim of dotted refs needs `LinkPolicy` anyway.

**Rejected: templating refs straight into forge URLs, as Jira does.**
A template has only `$0`. It cannot know which project `!482` belongs to.

## Recognition

Three user rules, in this order. They ship as one file in agterm-agents,
`share/agterm-open-link/links.conf`, and `~/.config/agterm/ghostty.conf` includes it
(see Decisions, the rule file). The pytest reads the same file.

```
# cross-project: group/proj!12, group/sub/proj#34, owner/repo@c865bc6c
link = open:agterm-ref:$0,(?<![\w./-])[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+(?:[!#][0-9]+|@[0-9a-f]{7,40})(?![\w-])
# short MR or issue: !12, #34
link = open:agterm-ref:$0,(?<![\w/.!#&$-])[!#][0-9]+(?![\w-])
# bare commit hash, 7 to 40 lowercase hex
link = open:agterm-ref:$0,(?<![\w./@-])[0-9a-f]{7,40}(?![\w-])
```

Why each boundary is there, checked with Python `re` on sample lines:

- `(?<![\w./-])` and `(?![\w-])`: no match inside a word, a path or a UUID.
  `3f2a9c1e-1b2c-…` matches nothing. `v1.2-3-gabc1234` matches nothing.
- A hash of 41 or more hex characters matches nothing, so a sha256 is not cut into a 40-character "commit".
- `&#1234;`, `x#12`, `y!3` and `!!12` match nothing. `#` after `&` is an HTML entity.
- `step #1`, `color #123456`, `echo !123` and `ts 1727712345` still match. That noise is accepted:
  the underline shows only while Shift+Cmd is held, and a click shows a HUD (see Decisions, digit-only hashes).
- The Jira rule and the xchat rule do not overlap these. Jira keys are upper case. An xchat id has 4 hex characters.
- A ref inside a URL is never matched twice. The built-in URL link is checked first.

`LinkPolicy.refDisposition` accepts a payload only when it matches one of these, anchored,
at most 300 characters, and with no newline:

```
^[!#][0-9]{1,9}$
^[0-9a-f]{7,40}$
^[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+(?:[!#][0-9]{1,9}|@[0-9a-f]{7,40})$
```

The helper checks the same three patterns again before it runs anything.
A project segment cannot start with `.`, so `..` is never a segment.

New URL shapes in `classify`. `P` is the project pattern above. Hosts are compared exactly, as today.

| forge | path | kind |
|---|---|---|
| GitLab | `^/(P)/-/merge_requests/([0-9]+)(/.*)?$` | mr (today) |
| GitLab | `^/(P)/-/(?:issues\|work_items)/([0-9]+)(/.*)?$` | issue |
| GitLab | `^/(P)/-/commit/([0-9a-fA-F]{7,40})(/.*)?$` | commit |
| GitLab | `^/(P)/-/pipelines/([0-9]+)(/.*)?$` | pipeline |
| GitLab | `^/(P)/-/jobs/([0-9]+)(/.*)?$` | job |
| GitHub | `^/(O)/(R)/pull/([0-9]+)(/.*)?$` | pr |
| GitHub | `^/(O)/(R)/issues/([0-9]+)(/.*)?$` | issue or pr, resolved |
| GitHub | `^/(O)/(R)/commit/([0-9a-fA-F]{7,40})(/.*)?$` | commit |

`O` is `[A-Za-z0-9][A-Za-z0-9-]{0,38}`. `R` is `[A-Za-z0-9_.-]{1,100}`, not `.` or `..`.
A hash is lower-cased after the match. The helper rebuilds the canonical URL from the parts, as for MRs.
GitHub Actions URLs stay "other" and open the browser.

## Forge resolution

Short refs (`!N`, `#N`) and bare hashes need the pane's repository. Cross-project refs need only a host.

For a short ref or a bare hash:

1. Read the pane from `tree --json`. A far pane (`far_pane` finds a host) or a set `remoteHost` → HUD, stop.
2. `--cwd` must be an absolute directory. Else HUD.
3. A bare hash first tries the local repository (see Commit review). Only a miss goes on to step 4.
4. `git -c core.fsmonitor= -C <cwd> remote get-url origin`. No origin → HUD.
5. Parse the URL with anchored patterns:
   - `^(?:ssh://)?[^@/\s]+@([^:/\s]+)(?::[0-9]+)?[:/](P)(?:\.git)?/?$` (scp form and `ssh://`);
   - `^https?://(?:[^@/\s]+@)?([^:/\s]+)(?::[0-9]+)?/(P)(?:\.git)?/?$`.
6. Host lower-cased. In `gitlab.hosts` → GitLab. In `github.hosts` → GitHub, and the project must be exactly
   `owner/repo`. Anything else → HUD `Unknown forge <host>`.

Per forge:

- GitLab: `!N` → mr, `#N` → issue, hash → commit.
- GitHub: `#N` → issue or pr. `gh api repos/O/R/issues/N` answers both; a `pull_request` key means a PR.
  `!N` → HUD `GitHub has no !N references: !12`.

For a cross-project ref, the host is:

1. the cwd origin's forge host, when the pane is local and has one, and the ref fits that forge.
   `!` never fits GitHub. A project of three or more segments never fits GitHub;
2. otherwise `gitlab.default_host`, which defaults to the first entry of `gitlab.hosts`.

So `magnolia/ui!482` works in any pane, far panes included.

## Items and views

Every fetch keeps today's rules: 10 second timeout, the `Fetching <label>…` HUD, `strip_controls` on all
fetched text, a unique view file under `~/.local/state/agterm-open-link/`, and `--resolved` on every overlay open.
`glab` runs with `GLAB_PAGER=cat NO_COLOR=1`.
`gh` runs with `GH_PAGER=cat NO_COLOR=1 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1`.

TUI means the existing `revdiffm`, else `glow`, viewer. HTML means the existing cmark-gfm page with its CSP.
Every Markdown view ends with the canonical URL, as today.

| kind | fetch | Markdown | extra |
|---|---|---|---|
| GitLab mr | today | today | today: `r` prompt, Review button |
| GitHub pr | `gh pr view N -R H/O/R --json number,title,state,author,body,url,comments,reviews`, plus `gh api --hostname H repos/O/R/pulls/N/comments?per_page=100` | title, state, author, body; then conversation comments, review bodies, and line-comment threads (grouped by `in_reply_to_id`, headed `— on path:line`), oldest first | `r` prompt and Review button: `gh pr diff N -R H/O/R --color never` → plannotator |
| GitLab issue | `glab issue view N -R https://H/P -F json`, plus `glab api --hostname H projects/<P>/issues/N/discussions?per_page=100` | title, state, author, assignees, labels, description, threads with system notes skipped | none; the page runs no script |
| GitHub issue | the resolution call `gh api --hostname H repos/O/R/issues/N`, plus `…/issues/N/comments?per_page=100` | title, state, author, assignees, labels, body, comments | none |
| GitLab pipeline | `glab api --hostname H projects/<P>/pipelines/N`, plus `…/pipelines/N/jobs?per_page=100` and `…/pipelines/N/bridges` | status, ref, short sha, source, duration, who started it; one section per stage with a table: job, status, duration, job URL | none |
| GitLab job | `glab api --hostname H projects/<P>/jobs/N`, plus `…/jobs/N/trace` | a header with name, stage, status, failure reason, pipeline; then the last 300 lines of the log | see below |
| commit | see Commit review | none | always plannotator |

A job log is not Markdown, and its end is what matters.
So the job TUI view is a plain text file shown with `less +G`, which opens at the last line.
The job HTML view is a page with the tail in one fenced block (`fence()` already guards backtick runs).
Before the tail is cut, each line keeps only its text after the last `\r`,
and GitLab's `section_start:<ts>:<name>` and `section_end:…` markers are removed.

A URL clicked inside any view opens the browser, as today. A job URL in a pipeline view is no exception.

## Commit review

1. Find the diff.
   - Bare hash in a local pane: `git -c core.fsmonitor= -C <cwd> rev-parse --verify --quiet --end-of-options <h>^{commit}`.
     Found → `git -c core.fsmonitor= -C <cwd> show --no-color --no-ext-diff --no-textconv --diff-merges=first-parent --format= --patch <sha>`,
     with `GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0`.
     Not found and origin is a known forge → the forge fetch below (see Decisions, forge fallback).
     Not found otherwise → HUD.
   - Cross-project `P@sha` and commit URLs: the forge fetch. There is no cwd for them.
2. Forge fetch.
   - GitLab: `glab api --hostname H projects/<P>/repository/commits/<sha>` for the full id and the title,
     then `glab api --hostname H --paginate projects/<P>/repository/commits/<sha>/diff?per_page=100`.
     The JSON gives `old_path`, `new_path`, `new_file`, `deleted_file` and `diff` per file.
     The helper rebuilds `diff --git`, `---` and `+++` headers (`/dev/null` for new and deleted files).
   - GitHub: `gh api --hostname H -H "Accept: application/vnd.github.diff" repos/O/R/commits/<sha>`.
3. Write the patch as `<project>-<short sha>.patch`, stripped of control bytes. plannotator shows that name.
4. Start `agterm-plannotate --review <patch> --target … [--pane] [--socket] --out <file>` detached, as `review_mr` does.
   No overlay close first: no preview overlay is open for a commit.

The local path shows no `Fetching` HUD. It is fast, and a HUD would only flash.
`--diff-merges=first-parent` keeps a merge commit's diff a plain unified diff. A combined `diff --cc` would not parse.

## Outcomes

Existing outcomes stay. New ones:

| case | result |
|---|---|
| short ref or bare hash in a far pane or an attached Mac row | HUD `Remote pane: !482 not resolved` |
| cwd is not a git repository | HUD `Not in a git repository: ~/dev/x` |
| no `origin` remote | HUD `No origin remote in agterm-vim` |
| origin host in neither list | HUD `Unknown forge gitlab-work for !482` |
| `!N` in a GitHub repository | HUD `GitHub has no !N references: !12` |
| cross-project ref and no GitLab host configured | HUD `No GitLab host for magnolia/ui!482` |
| hash not in the local repository, no forge fallback | HUD `No commit c865bc6c in agterm-vim` |
| hash not local and not on the forge | HUD `No commit c865bc6c in magnolia/ui` |
| hash prefix matches several commits | HUD `Ambiguous commit c865bc6 in agterm-vim` |
| issue, PR, pipeline or job does not exist | HUD `No such issue: magnolia/ui#12`, `No such pull request or issue: owner/repo#12`, `No such pipeline: magnolia/ui pipeline 55`, `No such job: magnolia/ui job 77` |
| a resolved item fails later (tool missing, auth, timeout) | the browser on the item's URL, as for a URL click |
| the helper crashes before an item is known | HUD `Could not open !482` |
| the helper is not installed, or the ref was clicked inside an overlay | nothing; a log line |

`<repo>` in a HUD is the origin project when known, else the basename of `git rev-parse --show-toplevel`.
Every HUD text goes through `hud_text`, so it fits.

The failure shapes these rely on must be measured when each builder is written, and the tests use them.
Unmeasured today: `glab issue view` on a missing issue, `gh api` on a missing issue and on a bad sha,
GitLab's commit endpoint on a short sha, `glab api --paginate` output for a JSON array,
and `git rev-parse --verify --quiet` stderr for an ambiguous prefix.

## Config

`~/.config/agterm/open-link.conf`, new keys:

```
github.hosts = github.com
github.view = tui
gitlab.default_host =
```

- `github.hosts` is a list like `gitlab.hosts`. It makes GitHub Enterprise work, since `gh` takes `-R HOST/OWNER/REPO`
  and `--hostname`. Default `github.com`.
- `github.view` covers PRs and issues. `gitlab.view` now covers MRs, issues, pipelines and jobs.
- `gitlab.default_host` empty means the first of `gitlab.hosts`.
- A commit ignores every `view` key. It is always a review.

## Security boundary

Everything in the parent spec still holds. Additions:

- A ref payload is untrusted terminal text. `LinkPolicy` and the helper both check it against the anchored patterns.
  It travels as one argv element after `--`, never through a shell.
- `--cwd` is only ever `git -C <cwd>`. The helper never runs a program from it.
  Every git call passes `-c core.fsmonitor=`. `git show` also passes `--no-ext-diff --no-textconv`,
  so a repository's diff driver or textconv program never runs.
  A hash always comes after `--end-of-options` in `rev-parse`, and the full sha from `rev-parse` is what `show` gets.
- The origin URL is parsed with anchored patterns. Its host must equal an entry in a configured list.
  Its project must match the segment pattern. A GitHub project must be exactly two segments.
- `glab` and `gh` get only validated parts. API paths are built from them, the GitLab project with `quote(project, safe="")`.
- A job log is the most hostile text here. It goes through `strip_controls` like every other fetched text.
  In the HTML view it sits inside a fence, so cmark-gfm renders it as code.
- A PR page admits only the existing review script by its hash. Issue, pipeline and job pages run no script.

## Control API

No new control command.
The capability is a click route into a script, not app state.
The script uses existing commands that already have read-back: `tree`, `session hud`, `session overlay open`.
This exemption is recorded in the Terminal links section of `.claude/rules/libghostty.md`.

## Tests

Fork, `agtermCore`, Swift Testing:

- `LinkPolicyTests`:
  - each accepted shape → `.ref(payload)`: `agterm-ref:!12`, `agterm-ref:#34`, `agterm-ref:c865bc6c`,
    `agterm-ref:group/sub/proj#34`, `agterm-ref:owner/repo@c865bc6c`;
  - `#` stays in the payload, not in a fragment;
  - refused → `.ignore`: an empty payload, `!12a`, `#0x1`, a 6- and a 41-character hash, upper-case hex,
    `../x!1`, `.x/y!1`, a literal and a `%0A` newline, a 301-character payload, `AGTERM-REF:!1`, `agterm-ref:!1?x`;
  - the reclaim: schemeless `group/my.proj!12` and `group/proj!12.` → `.ref`; `src/a.swift` still `.openPath`;
    `a/b.c#x` still `.ignore`.
- `OpenLinkLaunchTests`: `arguments(ref:…)` carries `--cwd` from `cwd(for:)` for the primary pane and for a split's
  right pane, `--socket` when given, and ends `-- agterm-ref:<payload>`. The URL argv is unchanged.
- App: the `.ref` case in `openLink`, checked by hand in an isolated Debug instance.

agterm-agents, `tests/test_agterm_open_link.py`, with stubs for `agtermctl`, `git`, `glab`, `gh`,
`agterm-plannotate`, `less`, `cmark-gfm` and `open`, in the existing style:

- the rules file: every rule line parses, and a table of lines gives the expected matches and non-matches
  (the samples in Recognition). Python `re` stands in for Oniguruma here; a hover check in Debug covers the rest;
- `classify` for every URL shape in the table, host spoofing on the new shapes, canonical URLs;
- `resolve_ref`: scp, `ssh://` and `https` origins; a lookalike host; GitHub with three segments;
  `!N` on GitHub; the cross-project host choice; a far pane (a stubbed `tree` with a mosh restore command);
  a set `remoteHost`; no origin; not a repository;
- GitHub `#N`: a `pull_request` key gives the PR view, none gives the issue view;
- each new Markdown builder on fixtures trimmed from real answers, with control bytes stripped;
- the job log: `\r` progress lines, section markers, the 300-line tail, `less +G`;
- commit: local hit runs `rev-parse` then `show` with the safety flags and starts plannotator with the patch;
  local miss uses the forge; ambiguous and missing give their HUDs; a GitLab diff rebuilds headers for new,
  deleted and renamed files; a merge commit passes `--diff-merges=first-parent`;
- PR `r` prompt and Review button start plannotator with `gh pr diff`;
- every HUD text in Outcomes, and the fetching HUD closed on every path;
- the catch-all: a crash before resolution shows `Could not open`, after it opens the item's URL;
- the existing tests still pass after the `Item` change.

## Docs to update

- Fork, `.claude/rules/libghostty.md`, Terminal links: six dispositions now; `.ref` and why it skips `URL(string:)`;
  the reclaim of dotted refs from the built-in path link; far panes are the helper's decision; the Control API exemption.
- Fork, `LinkPolicy` header comment: one clause for `.ref`.
- Fork, `FORK-NOTES.md`, the libghostty group: one line, "Clickable forge references", pointing at the same section.
- Fork, `CHANGELOG-fork.md` under `## Unreleased`: one user-facing entry.
- agterm-agents: the helper's docstring; `share/agterm-open-link/links.conf` with one comment line per rule.
- User config, outside both repos: one `config-file` line in `~/.config/agterm/ghostty.conf`.

## Stages and size

Overall **L**: two repositories, seven item kinds, five new Markdown builders, and failure shapes still to measure.
Each stage lands and is verified on its own.

1. **Swift route** (S). `LinkPolicy.ref`, the reclaim, `OpenLinkLaunch.arguments(ref:…)`, `openRef`.
   Verify: `cd agtermCore && swift test --filter 'LinkPolicyTests|OpenLinkLaunchTests'`.
2. **Helper core and commits** (M). `Item`, `--cwd`, `resolve_ref`, the far-pane check, local and GitLab commit review,
   the rules file. Verify: `python3 -m pytest tests/test_agterm_open_link.py`, then a click on a hash in a Debug instance.
3. **GitLab issues, pipelines and jobs** (M). URL shapes and three builders. Verify: pytest, then one click per kind.
4. **GitHub** (M). Resolution, PR, issue, commit. Verify: pytest, then clicks in a GitHub checkout.
5. **Docs and gates** (S). The docs above, then `swift test`, `make test-app` and `make lint` once.

If most clicks happen in p4linux panes, stage 4 is worth less than the far-pane follow-up in Decisions.

## Out of scope

- Resolving short refs in far panes (see Decisions).
- GitLab epics (`&N`), snippets, milestones, labels; GitHub Actions runs, discussions, releases.
- Turning refs inside a fetched description into links. The helper knows the project and could rewrite `!12`
  into a URL; that is a later, separate change.
- Following a job URL from a pipeline view into the job view. Clicks inside views open the browser.
- Any upstream agterm change.

## Decisions

**Digit-only hashes.** Anna runs `git log --oneline` in a local pane. One commit reads `4051227`.
If the hash rule requires a letter, that hash has no underline, and she cannot click it.
About one short hash in 27 is all digits.
Ben's build log reads `took 1727712345 ms`. Without the letter rule, the number underlines under Shift+Cmd,
and a click shows HUD `No commit 1727712345 in agterm-vim`.
**require a letter a–f in a bare hash?** Decided 2026-09-30: no. A missed hash has no workaround, while the noise
costs a hover underline and a HUD on a deliberate click. This matches the Jira rule, which accepts `UTF-8`.
Scope: the bare hash rule only; `@sha` in a cross-project ref is unaffected either way.

**Far panes.** Anna's Claude on p4linux prints `fixed in c865bc6c, see !482`. She clicks `!482`.
The Mac-side cwd is `~/dev/oss/agterm-vim`, which is also a real local clone.
With this spec she gets HUD `Remote pane: !482 not resolved`. Without the far-pane check she would get the
wrong repository's MR 482, silently.
**ship the HUD now, and resolve on the host later?** Decided 2026-09-30: yes. Resolving on the host means ssh to
the host, the zmx cwd lookup that `agterm-open-path --zmx-key` already has, and `git` there. That is its own M-sized
change. Scope: short refs and bare hashes in far panes only; cross-project refs and URLs work in far panes now.

**Commit not in the local clone.** Ben pushed `c865bc6c` from p4linux a minute ago. Anna has not fetched.
She clicks the hash in her local pane. Local `rev-parse` misses.
Without a forge fallback she gets HUD `No commit c865bc6c in agterm-vim`.
**fetch the diff from the forge when the local lookup misses?** Decided 2026-09-30: yes, through the origin's forge
API, never `git fetch`, which would change her repository. Scope: bare hashes in local panes with a known origin forge.

**Default host for a cross-project ref.** Ben is in a pane at `$HOME`. He clicks `octo/tool#12`, a GitHub issue.
There is no origin to read, so the ref goes to the default host, `gitlab.magnolia-platform.com`.
He gets HUD `No such issue: octo/tool#12`.
**default an unplaced cross-project ref to GitLab?** Decided 2026-09-30: yes. GitLab is the main forge here, `!` is
GitLab-only, and in a GitHub checkout a two-segment `#` or `@` ref already goes to GitHub.
Scope: only refs with no local origin to decide from.

**The rule file.** The three rules could be pasted into `~/.config/agterm/ghostty.conf` by hand,
or live in agterm-agents and be included with one `config-file = ?<path>` line.
Pasted, the copy the tests check and the copy ghostty reads can drift apart.
**include the rules file from agterm-agents?** Decided 2026-09-30: yes. `link` is a repeatable key, so included rules
add to the Jira and xchat rules; nothing replaces them. Check first that `config-file` expands `~` in agterm's
loader; if not, the line takes an absolute path.

## Open points

- An ssh host alias in the origin (`git@gitlab-work:group/proj.git`) reads as an unknown forge.
  `ssh -G <alias>` prints the real `hostname` without connecting. Add it if the HUD shows up in practice.
- A very large commit or job log can reach the 10 second timeout. Both then fall back like any other fetch failure.
- GitLab `work_items/N` URLs are treated as issues. A work item that is not an issue (a task, an epic) may 404.
- `glab issue view -R https://H/P` is assumed to accept the URL form, as `glab mr view` does. Measure it in stage 3.
