# Clickable bare file names — spec

## Contents

- [Goal](#goal)
- [Decisions](#decisions)
- [How a click travels](#how-a-click-travels)
- [The link rule](#the-link-rule)
- [LinkPolicy](#linkpolicy)
- [The search](#the-search)
- [Out of scope](#out-of-scope)
- [Tests](#tests)
- [Docs](#docs)

## Goal

Shift+Cmd+click on a file name without a directory (`links.conf`, `README.md`, `LinkPolicy.swift:131`) opens
that file, the same way a path with a `/` opens today.
Ghostty's built-in path link needs a `/` (every path branch of `src/config/url.zig` at `683d8db` ends its
prefix in `\/`), so these names are never underlined now.
No ghostty patch: a `link` rule in agterm-agents' `links.conf` underlines them, as it does forge refs.

The same search also gets two new steps, the repositories of other agterm rows and zoxide's most-used
repositories. They apply to relative paths with a `/` too, which today fall through to Spotlight.

## Decisions

Taken with Sasha on 2026-10-01:

- Do it although more words get underlined: any `name.ext` with a known extension shows an underline on hover.
- After the pane's own directory and repository, search **the repositories of other agterm rows**, then
  **zoxide's most-used directories that are git repositories**. Not sibling directories, not Spotlight for a
  bare name.
- Several matches: **the nearest step wins**. One match in that step opens. Several in that step open the
  existing `agtermctl pick` chooser.
- p4linux (far) panes are a separate task. Nothing here is built or tested for them.

## How a click travels

1. The rule in `links.conf` matches `links.conf` and mints `agterm-path:links.conf`.
2. `LinkPolicy.disposition(for:)` sees the `agterm-path:` prefix and checks the payload as a bare name.
   A valid one becomes the existing `.openPath(path:line:)`, so the app side changes nothing.
3. `GhosttySurfaceView` runs `agterm-open-path --cwd <pane cwd> … -- links.conf`, as for any other path.
4. `agterm-open-path` resolves the name through its chain, with the two new steps.

## The link rule

One line in `share/agterm-open-link/links.conf`, BEFORE the three ref rules:

```
link = open:agterm-path:$0,(?<![\w./@~$-])[\w@+][\w.@+~-]*\.(?i:EXTS)(?::[1-9][0-9]{0,6}(?:[-:][0-9]{1,7})?)?(?![\w/-]|\.\w)
```

- `EXTS` is `LinkPolicy.openPathExtensions` written out. Order does not matter: the trailing look-ahead
  backtracks `x.json` past `js`. `(?i:…)` matches Swift, which lowercases the extension before the lookup.
- It comes first because ghostty takes the first rule covering the hovered cell, and the hash rule would
  otherwise claim `cafe123` inside `cafe123.md`. It never matches a `/`, so cross-project refs are unaffected.
- The line starts at 1, as `LinkPolicy` requires: in `x.swift:0` only `x.swift` is underlined.
  A helper test checks it against a literal copy of that Swift list, since the helper repo cannot read the fork.
- The look-behind keeps a name inside a path (`a/b.md`) to ghostty's own link and keeps `~`, `$` and `@`
  prefixes out.
- `(?!\.\w)` keeps `notes.md.bak` and `v1.2.3.json.gz` from matching a prefix.
- The name's first character is never `-`, so the payload can never read as an option.

## LinkPolicy

- `public static let pathScheme = "agterm-path"`, checked next to `refScheme` on the raw string, before
  `URL(string:)`.
- `bareNameDisposition(_ payload:)`:
  - at most 255 characters, nothing in `CharacterSet.controlCharacters` (control and format characters, so a
    hidden U+200D or U+202E is refused while `Заметки.md` is accepted, as the rule's Unicode `\w` underlines it);
  - trailing `.,;:)?!*` stripped: `openPathDisposition`'s `.*;!?` plus the `,:)` prose leaves after a name;
  - an optional `:N`, `:N-M` or `:N:M` suffix parsed into `line` by the same code as `openPathDisposition`;
  - the name must match `^[\w@+][\w.@+~-]*$` (no `/`) and carry an extension in `openPathExtensions`;
  - otherwise `.ignore`.
- A `.openPath` from this route is the same value the schemeless route returns, so
  `GhosttySurfaceView+Input` and `OpenPathLaunch` are untouched.
- The comment on `openPathPatterns` that says relative paths need a `/` gains one clause naming this route.

## The search

`agterm-open-path` keeps its chain and order. A bare name runs the same steps a relative path does:

1. pane directory · git root · main checkout · linked worktrees · repo suffix (unchanged);
2. **other rows' repos (new)**;
3. **zoxide repos (new)**;
4. claude scratchpad (unchanged; a bare name never starts with `scratchpad/`);
5. Spotlight (unchanged), **skipped for a bare name**: `mdfind -name README.md` answers with every README
   on the machine.

The repo-suffix step already matches a bare name: `f == rel or f.endswith("/" + rel)` is a match by file name.

### Other rows' repos

- `agtermctl window list --json`, then `tree --json --window <id>` for each window with `open: true`, read-only
  (an untargeted `tree` answers only the active window; a closed window's `tree` is refused). A failed window
  read drops only that window; a failed `window list` falls back to the untargeted `tree --json`. Each
  session's `cwd`, plus `splitCwd` when it has a split. The windows are read only by this step, inside its
  budget, and each window's repositories are searched before the next window is read. `pane_command` reads the
  plain `tree` once, before the pane's own steps, for the clicked pane's far check.
- Skipped: rows with `remoteHost`, a pane whose `restoreCommand` or `splitRestoreCommand` runs on a far host
  (`far_pane`'s patterns), cwds that are not directories here.
- Each cwd becomes its `git rev-parse --show-toplevel`. The pane's own repository and duplicates are dropped.
- The step's candidates are the repo-suffix matches over all of those repositories together.

- Skipped on a far host (`--zmx-key`): there `agtermctl` is the ssh shim back to the Mac, and every path it
  answers is a Mac path.

### zoxide repos

- `zoxide query -l`, best score first, first 50 lines read.
- Each directory becomes its git top level. The pane's repo, the rows' repos and duplicates are dropped.
- At most 20 repositories are searched. A missing `zoxide` makes the step empty.
- Directories under `/Volumes`, `/net` and `/Network` are skipped: a stalled mount would hold the click.

### Matches and cost

- One candidate in the first step that finds any opens directly, in plannotator for markdown and revdiff
  otherwise, as today.
- Several open `agtermctl pick`, labelled with `~`-shortened paths, as today. One tracked file open in
  three worktree rows is three candidates with distinct paths, which is right.
- The two new steps share one 3 s deadline, `rev-parse` calls included; each git call there gets the time left
  as its timeout, so one slow repo cannot hold the click longer. A `scratchpad/` path skips both steps. Measured: 50 zoxide entries, 20 repos, about 1 s. They run only after the
  pane's own steps missed, and also when the pane is in no repository at all.

## Out of scope

- Far panes. `agterm-open-path` already runs itself on the far host for them; a bare name there goes through
  the same chain on that host. The rows step finds no Mac paths there and is not tuned or tested for it.
- Sibling-directory search, recency other than zoxide's score, a ranking across steps.
- A name with no extension (`Makefile`, `Dockerfile`). Not in `openPathExtensions` today.

## Tests

Fork, `LinkPolicyTests`:

- `agterm-path:links.conf` → `.openPath("links.conf", nil)`; `README.md:12` → line 12; `a.swift:3-9` → line 3.
- Refused: a `/` in the payload, a leading `-`, an unknown extension, no extension, over 255 characters,
  a newline, an empty payload.
- Trailing punctuation stripped (only an OSC 8 link reaches it; the rule ends on an extension or digit):
  `notes.md).` → `notes.md`.

Helper, `test_agterm_open_link.py` (where the `links.conf` rule tests live):

- The rule's extension list equals `LinkPolicy.openPathExtensions`.
- Matches and non-matches in prose: `see links.conf.` → `links.conf`; `a/b.md`, `notes.md.bak`, `-x.md`,
  `agterm.com`, `~/.zshrc` → none.

Helper, `test_agterm_open_path.py`:

- A bare name in the pane's repo opens directly; two of that name in the repo go to `pick`.
- A miss in the pane's repo, found in another row's repo, opens it; the pane's own repo wins when both have it.
- Found only through zoxide; zoxide missing → step empty, HUD "File not found".
- A far row's cwd and a `remoteHost` row are never searched.
- A bare name never reaches Spotlight; a relative path with a `/` still does, after the new steps.

## Docs

- Fork `.claude/rules/libghostty.md`, Terminal links: the `agterm-path:` route in the `.openPath` bullet.
- `FORK-NOTES.md` and `CHANGELOG-fork.md` (Unreleased): one line each.
- `agterm-open-path`'s docstring: the two steps in the chain line, and that a bare name skips Spotlight.
