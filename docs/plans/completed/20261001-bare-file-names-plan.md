# Clickable bare file names — plan

Spec: `docs/plans/completed/20261001-bare-file-names-spec.md` (approved 2026-10-01).

## Contents

- [Where the work happens](#where-the-work-happens)
- [Task list](#task-list)
- [Verify](#verify)
- [Landing](#landing)

## Where the work happens

- Fork: `/Users/sasha/dev/oss/agterm-vim/.claude/worktrees/clickable-links`, branch `bare-file-names`, cut from
  `main` at `89fc6a9c`.
- Helper: `/Users/sasha/dev/agterm-agents/.worktrees/clickable-links`, branch `bare-file-names`, cut from `main`
  at `cffbce8`.
- `~/.local/bin/agterm-open-path` points at the helper worktree, so a helper commit is live at once.
- The two repos meet at one string: the rule mints `agterm-path:<name>`, and `LinkPolicy.pathScheme` reads it.

## Task list

Each task is test first: write the failing test, see it fail, make it pass with the narrow command named.
`PYT` below is `uv run --with pytest python -m pytest -q` in the helper worktree.

Fork:

1. [ ] `LinkPolicyTests`: the spec's accept, refuse and punctuation cases for `agterm-path:`, plus `README.MD`
   accepted. Narrow: `cd agtermCore && swift test --filter LinkPolicyTests`.
2. [ ] `LinkPolicy.swift`: `pathScheme`, its prefix check in `disposition(for:)` beside `refScheme`'s, and
   `bareNameDisposition`, sharing the line-suffix parsing with `openPathDisposition` rather than copying it.
   Same narrow command.
3. [ ] Docs:
   - `.claude/rules/libghostty.md` Terminal links: reword the `.openPath` bullet, which says it needs no link
     rule, to name the `agterm-path:` route;
   - the `openFilePath` doc comment in `agterm/Ghostty/GhosttySurfaceView+Input.swift`, which names only
     ghostty's built-in path link;
   - the `openPathPatterns` comment and the type's header comment (the route list) in `LinkPolicy.swift`;
   - one line in `FORK-NOTES.md`, one `CHANGELOG-fork.md` Unreleased entry.

Helper:

4. [ ] `tests/test_agterm_open_link.py`:
   - `rule_patterns()` filters on the `open:agterm-ref:$0` template instead of asserting it; a new
     `path_rule()` returns the one `open:agterm-path:$0` rule. Its three callers, recounted at acceptance:
     `test_the_rules_file_holds_three_ref_rules`, `test_the_rules_match_refs_and_skip_lookalikes`,
     `test_the_numbered_rules_stop_at_nine_digits_as_linkpolicy_does`;
   - the rule's extensions equal a literal copy of `LinkPolicy.openPathExtensions`, named as such;
   - prose cases: `see links.conf.` and `README.MD` match; `a/b.md`, `notes.md.bak`, `-x.md`, `agterm.com`,
     `~/.zshrc`, `x.swift:0` (only `x.swift`) do not; the path rule is first in the file.
   Narrow: `PYT tests/test_agterm_open_link.py -k "rule"`.
5. [ ] `share/agterm-open-link/links.conf`: the bare-name rule before the ref rules, with a one-line comment.
6. [ ] `tests/test_agterm_open_path.py`:
   - `zoxide` joins the fixture's stubs, answering `ZOXIDE_OUT`; `AGTERM_OPEN_PATH_ZOXIDE` pointing at a
     missing path is the "zoxide missing" case;
   - the `agtermctl` stub's default `window list --json` answer is one open window, so `TREE_JSON` keeps
     serving the existing tests; `calls()` drops `window list` as it drops `tree`; a two-window answer and a
     closed window are per-test;
   - cases: pane repo direct and `pick`; found in another row's repo, including a row in the second window;
     own repo wins; a closed window is never read; a failed `window list` falls back to plain `tree`;
     a pane in no repository still reaches both new steps; a `scratchpad/` path skips them; zoxide only; zoxide missing → HUD;
     far and `remoteHost` rows skipped; `--zmx-key` makes no tree call (read the raw stub log: `calls()`
     drops tree calls); `/Volumes/...` zoxide entries skipped; `links.conf` and `./links.conf` never reach
     Spotlight, `share/x/links.conf` still does after the new steps.
   Narrow: `PYT tests/test_agterm_open_path.py`.
7. [ ] `bin/agterm-open-path`:
   - `ZOXIDE = os.environ.get("AGTERM_OPEN_PATH_ZOXIDE") or "zoxide"`;
   - `row_tree(args)`: the sessions of every `open` window, a failed window dropped, plain `tree --json` when
     `window list` fails; fetched once in `main` and handed to `pane_command` and the rows step;
   - `row_repos(rows, own)` and `zoxide_repos(exclude)`, appended after the `if root:` block in `resolve`
     under `not rel.startswith("../")` and not for `scratchpad/`, sharing one 3 s deadline that every git call
     there takes its timeout from; the rows step absent under `--zmx-key`;
   - Spotlight skipped when the name, after the `./` strip, has no `/`;
   - `resolve(path, cwd, rows=None)`, so its direct caller
     `test_claude_scratchpads_of_several_sessions_go_to_the_picker_newest_first` keeps working; that test also
     sets `AGTERM_OPEN_PATH_ZOXIDE` to a missing path.
   Same narrow command.
8. [ ] `agterm-open-path` docstring: the chain line, the Spotlight note, the `--zmx-key` skip.

Both:

9. [ ] Gates (below), each once, at the end.
10. [ ] Revmux `codex-claude` on both branches; fix accepted findings here and re-run the same review.
11. [ ] Move spec and plan to `docs/plans/completed/`.
12. [ ] At landing, ask Sasha whether `LinkPolicy.swift` joins `fork-merge.md`'s `flagged` list.

## Verify

- Fork: `cd agtermCore && swift test`, `make lint`, `make test-app`.
  `HtmlOverlayRegistryTests.testAFolderGrantKeepsFilesOutsideItOut` already fails on `main`; any other failure
  stops the work.
- Helper: `uv run --with pytest python -m pytest -q tests/test_agterm_open_link.py tests/test_agterm_open_path.py`.

## Landing

Commit on `bare-file-names` in each repo as tasks complete. Merging into either `main`, deploying, and pushing
are Sasha's call and are asked for after the review.

<!-- plan-review: planning:plan-review 2026-10-01 findings=21 resolved -->
