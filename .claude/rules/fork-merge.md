---
# The merge-danger lists the triage job and the fork-merge-triage skill both read at run time.
# They live here rather than in the skill so they are versioned with the code they describe.
#
# flagged: a conflict here clears the stomach test only when its enclosing declaration is not one of
# the constructs below. Nothing about a flagged file is an automatic stop; it raises the bar.
flagged:
  - "agterm/Commands/CustomCommandRunner.swift"
  - "agtermCore/Sources/agtermCore/Keymap.swift"
  - "agtermCore/Sources/agtermCore/BuiltinAction.swift"
  - "agtermCore/Sources/agtermCore/NormalModeState.swift"
  - "agtermCore/Sources/agtermCore/KeybindMatcher.swift"
# constructs: resolving a hunk whose enclosing declaration is one of these needs a person, whatever
# the hunk looks like. A file listed with no member means the whole file, because it is small enough
# that subdividing it buys nothing.
constructs:
  - "CustomCommandRunner.handleKeyDown"
  - "CustomCommandRunner.handleNormalModeKey"
  - "Keymap.parseKeymap"
  - "Keymap.resolveMapLines"
  - "Keymap.resolveBuiltinOverrides"
  - "Keymap.validateBindings"
  - "Keymap.unboundAfterRestoringStrandedDefaults"
  - "BuiltinAction"
  - "NormalModeState"
  - "KeybindMatcher"
# declined: files the candidate rule below offered and a human said no to. Only ever appended to by a
# merger session acting on an explicit answer, never on silence. See "Keeping the lists current".
declined:
  # Offered by the candidate rule on 2026-08-23 and declined, with the reason each time being that
  # the FORK owns no key-routing behaviour in the file — the rule matched them for naming `Chord`,
  # `BuiltinAction` or `NSEvent` in passing. GhosttySurfaceView+Input.swift was the near miss: it
  # really does hold `keyDown` and `isInterruptKeystroke`, but `git diff <merge-base> main` shows the
  # fork has changed neither, so a bad resolution there cannot kill fork behaviour.
  - "agterm/Ghostty/GhosttySurfaceView+Input.swift"
  - "agterm/Views/WindowContentView.swift"
  - "agterm/Views/WindowContentView+Titlebar.swift"
  - "agterm/Views/WorkspaceSidebar.swift"
  - "agterm/Views/SidebarRowViews.swift"
  - "agterm/Control/ControlServer.swift"
  - "agterm/Control/ControlServer+AppCommands.swift"
  - "agtermCore/Sources/agtermCore/AppStore.swift"
  - "agtermCore/Sources/agtermCore/ControlDispatcher.swift"
  - "agtermCore/Sources/agtermCore/Session.swift"
  - "agtermCore/Sources/agtermctlKit/MiscCommands.swift"
---

## Keeping the fork current with upstream

This fork sits on top of `umputun/agterm` and is kept current by MERGING `upstream/master` in, never by
rebasing onto it.
Was `fork-rebase.md`, and rebasing, until 2026-08-21.
A three-way merge diffs the merge base against each side and resolves once, so the fork's commit count
stops mattering, its history becomes permanent, and publishing is a plain fast-forward.

`origin` is the publishing remote (`p4elkin/agterm-vim`, branch `main`); `upstream` is `umputun/agterm`,
whose push URL is set to the literal `DISABLED_never_push_to_upstream` so a push there fails rather than
lands.
"Merge to main" always means this fork's own `main`, never anything toward upstream.

- Publishing is `git push origin HEAD:main`, and only after every gate below is green.
  That is the line `daily-rebase.sh` itself runs, so keep the two spelled the same.
- ⚠️ **There is no pre-merge tag, and nothing rolls back.** Under rebasing a tag was the way home; a
  merge commit is permanent, so a red gate leaves the merge on disk UNPUSHED and the fix goes on top of
  it. Do not try to restore a previous state — finish the merge instead.
- Never resolve a conflict by deleting fork behavior, and never drop an upstream fix. When both sides
  changed a line, keep upstream's change and re-apply the fork's intent on top of it.

### The gates, and why the obvious three are not enough

⚠️ `swift test`, `make lint` and `make release` do not compile `agtermTests`. A merge that breaks the
hosted test target passes all three. Run `make test-app` as well, every time.

⚠️ **The conflict count predicts nothing.** The 2026-08-10 run shipped two defects. One came out of a
resolved conflict; the other came from a file with no conflict at all — upstream added `FullScreenChordTests`
against a three-argument `CustomCommandRunner` initializer while the fork's takes `performBuiltin` too, and
git had nothing to flag. So run the full gate set on a zero-conflict merge exactly as on a messy one.

⚠️ **A libghostty patch that still APPLIES may no longer COMPILE.** `scripts/setup.sh` only runs
`git apply`, so a `GHOSTTY_REV` bump that leaves the patches applying cleanly can still break the build,
and nothing says so until someone rebuilds from scratch. Measured 2026-08-21: the bump from `4dcb09ada`
to `0ba6250` (zig 0.15 to 0.16) left `0002-link-config.patch` applying with one rejected hunk and, once
that was fixed, failing to compile on `std.ArrayList` initialization — `= .{}` must now be `= .empty`.
⚠️ **So a `GHOSTTY_REV` bump is not done until `make prep` has rebuilt from a deleted
`GhosttyKit.xcframework`.** Bump the pin and carry every patch in the same change, never separately.

### Where upstream and the fork keep colliding

- `agterm/Commands/CustomCommandRunner.swift` — the highest-risk file by far. Both sides keep restructuring
  `handleKeyDown`, and the fork inserts normal mode as an early-returning branch in the middle of it.
  ⚠️ **Anything upstream adds AFTER that branch is dead while the mode is on.** That is exactly how
  `toggle_fullscreen` broke. After any merge touching this file, read the whole function top to bottom and
  ask, per dispatch below the normal-mode branch, whether it still needs to run with the mode on.
- `agtermCore/Sources/agtermCore/{Keymap,BuiltinAction,NormalModeState}.swift` — the fork widens the keymap
  grammar (`nmap`, leader sequences, `KeybindTarget`), so an upstream keymap fix usually needs re-applying
  onto a wider type rather than taking one side.
- `.claude/rules/keymap.md`, `README.md`, `cookbook/` — text conflicts, keep both sides.
- `CHANGELOG.md` — upstream release notes only. Take upstream's version whole. Fork release notes go in
  `CHANGELOG-fork.md`, which upstream does not have and which therefore never conflicts; see [[release]].

### Keeping the lists current

The frontmatter at the top of this file holds three lists, and the triage job and the
`fork-merge-triage` skill both read them at run time rather than carrying their own copies.

`flagged` and `constructs` are the stomach test's inputs. A flagged file raises the bar for a hunk
and stops nothing by itself; a hunk whose enclosing declaration is one of the constructs needs a
person whatever it looks like. `BuiltinAction`, `NormalModeState` and `KeybindMatcher` are named
whole, at 94, 101 and 76 lines, because subdividing a file that small buys nothing.

**The lists cannot be derived, and three attempts to derive them were measured failing on
2026-08-23.** The `paths:` frontmatter across `.claude/rules/*.md` declares 127 paths while leaving
117 fork-modified Swift files undeclared, `NormalModeState.swift` among them. Fork commit density
ranks the five flagged files 10th, 25th, 28th, 47th and 48th, well below `ControlProtocol.swift`,
`Session.swift` and `AppStore.swift`, none of which are dangerous — density measures churn. A
key-path grep is the narrowest of the three and still catches `SidebarRowViews.swift` for naming
`BuiltinAction` in passing. The property being looked for is "a plausible resolution here silently
kills behaviour", and git history does not record it.

So a new entry arrives one of two ways, and the second exists because the first has already failed.

**When a feature lands.** That is the only moment anyone knows whether new behaviour is invisible to
the gates, and the author is already editing `FORK-NOTES.md` — see "The two fork docs" in
[[release]], which now carries the clause.

**When the job asks.** Every run computes candidates: files the FORK changed since the last merge
that sit on the key path, minus `flagged`, minus `declined`. A run with an empty remainder says
nothing.

⚠️ **A candidate has nothing to do with whether anything conflicted.** It asks whether the fork grew
something that would be dangerous the NEXT time upstream touched it. So the two are independent in
both directions: a clean merge can carry new candidates, and an ugly merge can carry none. Worse,
70-odd fork-added files can never conflict at all, because upstream has no version of them — zero
conflicts and maximum unwatched fork behaviour, the same inversion the silent files show one layer
up.

⚠️ **`declined` is only ever appended to on an explicit answer, never on silence.** A merger session
writes it when a person says which candidates matter and which do not, and commits that edit with
the merge. Nothing may treat an unanswered question as a no: a candidate dismissed by silence is
the failure this whole mechanism exists to remove.

Because the question rides the report rather than a failure, a green run notifies without stopping.
The floor is the backstop: once five candidates are unanswered, or one has been waiting three weeks,
a green run exits 2 instead of pushing, purely to make somebody look. Without it the asking degrades
into "the job asks when upstream happens to be awkward", which is unrelated to whether the fork grew
anything dangerous — and the better the triage gets at merging cleanly, the more runs exit 0 and the
less often the question would ever be seen.

### Delegating it

A subagent can do the mechanical merge, but its report is not evidence: the 2026-08-10 agent traced the
merged control flow correctly, then recorded the full screen dispatch sitting behind the normal-mode filter
as matching the fork's intent. Verify the result yourself — `git merge-base --is-ancestor upstream/master HEAD`,
the fork commit count, and the gates, including `make test-app`.

### The daily job, and the paused merge you may find

A scheduled job merges upstream into a dedicated clone at `~/dev/oss/agterm-vim` and pushes when every gate
is green. The scripts live in `~/dev/n8n/scripts/agterm-vim-rebase/`, symlinked into
`~/.local/bin/agterm-vim-rebase/` — outside any repo, because an early version got committed into the
branch it was operating on. n8n triggers it over ssh. `DRY_RUN=1` does everything except push and notify.

Exit codes: **0** finished · **1** stopped, nothing pushed · **2** paused for a human, the merge is on disk.

⚠️ **A merge left in progress in that clone is deliberate, not wreckage.** A conflict is never resolved
unattended: the job leaves the merge exactly where it stopped and exits 2. Resolve it, `git commit`, and
let the next run gate and push it — there is no `--resume` step any more. The flag is still accepted and
ignored, because the n8n paused-run message still names it.

⚠️ **Local `main` in that clone can legitimately be AHEAD of `origin/main`** — a merge a human resolved
yesterday, or one whose gates were red. The job fast-forwards when it is behind and gives up when the two
have diverged. It does NOT `reset --hard origin/main`; that was safe only while the job force-pushed.

`make test-app` is delegated back into agterm on purpose. An AppKit test host needs a window server, and
over ssh the job is in a Background launchd session with none, so the host CRASHES while every suite still
reports 0 failures (measured 2026-08-10). The job spawns `session new --command` so the gate runs in the
app's own Aqua session, and reads the exit code back through a file.

⚠️ **Never resolve an agterm session by name.** The agent integration rewrites a session's name to whatever
the agent inside it is doing and prefixes a live status glyph, so a pane created as `agterm-vim-rebase`
reads as `⠂ agterm-vim` in `tree --json` seconds later. Record the id at creation and match on that.
Matching on name silently created a fresh pane per call.
