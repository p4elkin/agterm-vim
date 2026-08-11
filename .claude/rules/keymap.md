---
paths:
  - "agtermCore/Sources/agtermCore/Keybind.swift"
  - "agtermCore/Sources/agtermCore/KeybindMatcher.swift"
  - "agtermCore/Sources/agtermCore/Keymap.swift"
  - "agtermCore/Sources/agtermCore/BuiltinAction.swift"
  - "agtermCore/Sources/agtermCore/CustomCommand.swift"
  - "agtermCore/Sources/agtermCore/ConfigPaths.swift"
  - "agterm/Commands/CustomCommandRunner.swift"
  - "agtermUITests/KeymapUITests.swift"
---

## Keymap

- `<configDir>/keymap.conf` (default `~/.config/agterm`) rebinds built-in menu shortcuts and defines
  custom shell commands, which appear in the action palette as `custom`. One parsed `Keymap` drives the
  menu, custom-command monitor, and palette; host-free logic lives in `agtermCore`.
- `parseKeymap` never throws. `map <chord> <action>` takes one whitespace-delimited chord token.
  `command "<name>" [chord] <shell...>` treats the token after the quoted name as a shortcut only when
  `parseKeybinds` accepts it with a modifier; a bare key is diagnosed and the command stays palette-only.
  Empty shell text is invalid. Both verbs split on spaces/tabs. Blank lines and comments are skipped;
  inline `#` starts a comment only after whitespace and outside double quotes. Each bad line yields
  `KeymapDiagnostic{line,message}` without stopping later lines. `{AGT_X}` text remains verbatim.
- `|` is the top separator tier: it splits a chord token into alternatives, `>` splits a sequence into
  chords, `+` splits a chord into modifiers and a base key. Both verbs take it, inside the single token
  with no spaces around it — `parseCommandLine` hands everything after that token to the shell.
  The first menu-bindable single-chord alternative of a `map` line becomes the key equivalent; every other
  alternative, from either verb, is dispatched by the `CustomCommandRunner` monitor via `builtinSequences`.
  A `map` line offering no menu-bindable alternative records the action in `builtinUnbound`, because
  ABSENCE from `builtinOverrides` already means "keep the shipped default". A line that bound NOTHING is
  different again: whether its alternatives fell to a rule at parse time or to the cross-section passes
  afterwards, the action goes back to its shipped default, since the file never asked to move it.
  `unboundAfterRestoringStrandedDefaults` owns the second half and skips an action whose default something
  else took meanwhile — being unbound is what freed it.
- Per-alternative grammar follows the dispatch path, not the verb. The menu-bound alternative keeps `map`'s
  own rules (bare non-arrow legal, reserved chords and modifier-less arrows rejected); every monitor-bound
  alternative requires a modifier on its first chord, since a bare first key would be swallowed everywhere
  in the terminal.
- A malformed alternative kills the whole line deliberately — `parseKeybinds` returns nil, so a typo cannot
  hide behind a line that half worked. On a `command` line that token would otherwise be swallowed as shell
  text with no diagnostic, so `hasMalformedAlternative` tells a typo from a real pipeline: a `|` token where
  at least one half parses is a binding, `ls|grep foo` is not.
- A rule violation or a conflict drops that alternative alone and leaves its siblings firing, on either
  verb. Do not turn either into the other.
- Diagnostics quote the raw substring and never re-render it: `displayString` canonicalizes spelling and
  would change `|`-free files' diagnostics. `DropScope` owns the suffix that keeps single-alternative
  wording byte-identical (`map skipped`/`keybind dropped`/`treating the line as palette-only` with one
  alternative, `alternative skipped`/`alternative dropped` with more), pinned by
  `KeymapTests.pipeFreeKeymapParsesExactlyAsItDidBeforeAlternatives`.
- Pure types live in `Keybind.swift`, `KeybindMatcher`, `CustomCommand`/`CommandContext`,
  `BuiltinAction` (43 cases, pinned by `BuiltinActionTests`), `Keymap`, and `ConfigPaths`.
  `CommandContext` owns the shared expansion/environment token table.
- Built-ins use AppKit menu key equivalents from `keymap.equivalent(for:)`; apply only non-nil
  `KeyboardShortcut`s. SwiftUI rebuilds menu shortcuts on the next activation, not immediately after
  `keymap reload`, and resolves stock collisions by unbinding agterm's item.
- `AppDelegate.applyCloseSessionChord` clears stock File > Close ⌘W while `close_session` owns it and
  restores it otherwise. Run at launch, `.agtermKeymapChanged`, asynchronously after `didBecomeActive`,
  and during menu tracking because every rebuild can reapply the collision. ⌘W is the only built-in with
  a stock competitor.
- Diagnose live shortcut state with `agtermctl keymap list`, whose `actions` and `menu` expose parsed and
  dispatched chords through host-free `namedKey(forKeyEquivalent:)`; the actions column's contract is owned
  by [[control-api]], and only its first field can appear under `menu`. `overridden` compares the resolved
  menu chord against the shipped default, so an action left with alternatives only reports `overridden` with
  no `chord` when it ships a default, and stays unmarked when it is keyless. Test the reload path, not
  only a seeded file: see `CloseSessionChordTests`,
  `CustomCommandRunnerTests.testKeymapReloadRebindsTheBuiltinAlternatives`, and
  `KeymapUITests.testCloseSessionReclaimsCommandWAfterReload`.
- `CustomCommandRunner` uses an app-wide local `.keyDown` monitor. Its `KeybindMatcher` supports simple
  chords and leaders such as `ctrl+a>g`, ignores repeats, and times leaders out after 1.5 seconds.
  `.fired` launches detached `/bin/sh -c` with cwd, selection, and `$AGT_*`; non-zero exit calls
  `notifyCommandFailure`. `.firedBuiltin` routes through `AppActions.perform(_:in:)`, a reverse lookup over
  `PaletteCommand.allCases` on `builtinAction`, falling
  back to `paletteLessHandler(for:)` — the sole listing of the actions holding no palette row, partitioned
  against `PaletteCommand` by `AppActionsPaletteTests`. Rebuild the matcher from commands AND
  `builtinSequences` on `.agtermKeymapChanged`.
- **An alternative does what its line's MENU chord does, no more and no less.** So `perform(_:in:)` runs the
  palette row's body behind `PaletteCommand.isEnabled(in:)`, the single predicate the menu item spells as
  its `.disabled(…)`; [[menu-actions]] owns it, so never restate a menu term here or in `perform`.
  `close_session` is the one row whose menu BODY differs from
  its palette row: the menu falls back to closing the key window when there was no cover and no session, so
  `perform` takes `closeActiveSessionOrWindow(_:)` with the window the chord fired in, not the palette's
  ungated `closeActiveSession()`. The `paletteLessHandler` half has no palette row to carry the predicate,
  so each of its entry
  points holds the gate itself — the three palette launchers on the full `uiActionsEnabled`, not zoom and
  picker alone, since their menu items are disabled over the dashboard. The key is
  consumed either way: the gate lives inside each action, so the runner cannot see the outcome, and passing
  a leader's last chord through after swallowing its prefix would type a stray character into the terminal.
- Fire with a focused `GhosttySurfaceView`, or in an agterm terminal window whose focus is not an `NSText`
  field editor, including a zero-session window. Pass through text fields and auxiliary windows;
  `WindowRegistry.contains(keyWindow)` gates no-surface dispatch. `handleKeyDown(_:in:)` takes the key
  window rather than reading `NSApp.keyWindow`, so hosted tests can drive the decision.
- Normal mode (`nmap`) is a FILTER inside that same monitor and owns no first responder. While it is on the
  monitor consumes every key it sees, an unmatched one included, so nothing reaches the terminal.
  Four exits, none of them first-responder observation: a focused `NSText` (palette field, inline rename,
  Settings, search bar) ends the mode and passes its key through, the modal gate failing ends it the same
  way, a click in a pane ends it from `GhosttySurfaceView.mouseDown`, and the key window resigning key ends
  it from the monitor's observer.
  ⚠️ That last one calls `abandonLeader()`, never a bare `cancelLeaderTimer()`: a yielded key arms the
  GLOBAL matcher while the mode is on, and killing the shared timeout without the matcher strands that
  prefix for good (`NormalModeKeyRoutingTests.testTheKeyWindowResigningKeyDropsAStrandedGlobalLeader`).
  A program overlay is a YIELD, not a fifth exit, and the question is an EVENT rather than a state:
  host-free `NormalModeOverlayHandover` remembers the keyboard target (active session id plus
  `focusedPane`) it saw at the previous key, and the mode yields only when
  `Session.programOverlayOwnsKeyboard` (the session-wide overlay or the FOCUSED pane's own, never a HUD)
  turned true on that same unchanged target.
  So an overlay opened from an `nmap` bind takes the keys at once and quitting it lands back in the mode,
  while walking onto a session or pane whose overlay is ALREADY running is an arrival and keeps the keys,
  so `j`/`k` carry past it instead of trapping her there.
  Entering the mode forgets the target, which is what makes the first key after `ctrl+space` the mode's
  even over a live overlay; `i` hands the keyboard over.
  A yielded key FALLS THROUGH to the global matcher rather than being dropped, so yielded means exactly
  what the mode being off means: `map` binds fire, ⌘⌃F reaches its dispatch, and `ctrl+space` takes the
  keyboard back.
  ⚠️ It abandons the MODE's half-typed leader only, never `abandonLeader()`, which resets both matchers:
  the global prefix is armed BY a yielded key, so wiping it there would kill every `map ctrl+a>g` sequence
  under an overlay while eating its first chord
  (`NormalModeKeyRoutingTests.testAGlobalLeaderSequenceStillCompletesWhileYielded`).
  `NormalModeController.stepOverlayHandover` advances that memory, so call it exactly once per key event,
  after the `uiActionsEnabled` re-check and before the branch decides who owns the key.
  Ask that predicate, never a raw `overlayActive`, and never widen `uiActionsEnabled` instead — that gate
  also disables the menu bar and the palette.
  The focus paths carry NO normal-mode gate — `focusActiveSession`/`focusSplitPane` move focus normally, so
  a bind that navigates sessions lands the responder on the pane it opened.
- **Esc leaving the mode also hands an Escape keypress to the focused pane**, so the program there — vim,
  shell vi-mode, Claude Code's vim mode — enters ITS normal mode from the same press.
  `i` means insert at both layers and Esc means normal at both.
  It is `GhosttySurfaceView.sendEscapeKey`, a keycode press through the surface's own key path, not
  `inject(text:)`; `sendKeyPress` is shared with `sendReturn` and the keycode is
  `InterruptKeystroke.escapeKeyCode`.
  ⚠️ Only `NormalModeState.escape()` returning `.exited` sends. Esc abandoning a half-typed leader stays in
  the mode, and an Escape delivered there would reach the shell from behind a mode still swallowing keys.
  `advance`'s `.exited` (the bare exit key) must send NOTHING, so the send reads `escape()`'s own result on
  its own branch rather than the outcome switch below it.
  With no focused surface Esc is the plain exit it always was, and `mode off` over control sends nothing:
  a script turning the mode off is not a user pressing Esc.
  `CustomCommandRunner.escapeSender` is the seam `NormalModeKeyRoutingTests` reads, for the reason
  `AppActions.keyWindowProvider` exists — a zero-frame test pane has no libghostty surface, so the send
  leaves no trace there. It pins the three no-pty rules: Esc exits and sends, an armed leader sends nothing,
  `i` sends nothing.
  ⚠️ That seam proves WIRING, never DELIVERY: a keycode libghostty encoded to no bytes would pass it.
  `NormalModeEscapeHandoffTests` is the delivery proof and the only hosted test that realizes a surface — a
  real frame plus `command: "cat -v"`, whose canonical-mode tty echoes the byte, then `readScreenText` looks
  for `^[`. Keycode 53 was verified this way to reach the pty; removing the send leaves the screen at the
  login banner. `destroySurface()` in `tearDown` is what ends the spawned process.
- An `nmap` target is a bare token for a built-in action or a QUOTED name for a custom command
  (`nmap e "Annotate last response"`), reusing the quoting that already marks a name on a `command` line.
  A quoted name has no id until every `command` line is read, so `parseNormalModeLine` records it
  unresolved and `resolveNormalModeBinds` resolves it; the `command` may therefore sit above or below the
  `nmap` naming it. A name matching nothing is dropped with `unknown command '<name>'` on the `nmap` line,
  BEFORE the prefix pass, so it blocks no later bind. The chord rules are the target's business either
  way: reserved monitor chords, any chord carrying Command, and a leading exit key stay rejected.
  Command is rejected at any position for the same reason the reserved chords are — the monitor hands
  every Command chord to the GLOBAL matcher, so the mode can never take one, and `nmap cmd+d new_session`
  would silently run whatever `cmd+d` already owns.
- **An action whose `BuiltinAction.leavesNormalMode` holds takes the mode off as it fires**, so the pane it
  just created is typed into with no `i`. The set is the four that hand over a brand-new pane:
  `new_session`, `new_window`, `new_workspace`, `duplicate_session`, pinned by `BuiltinActionTests`.
  The exit happens inside `NormalModeState.advance`, so `NormalModeController.publish` clears the pill with
  no app-side branch, and `.fired` still carries the action either way — only `isActive` differs.
  ⚠️ The toggles that also show a pane (`toggle_split`, `toggle_scratch`, `quick_terminal`) are excluded on
  purpose: leaving the mode there would cost the second press that closes them. The cost is that the pane
  they open is not typed into until `i` — the scratch in particular, which is a surface in the same window
  and so is not the overlay yield either (`quick_terminal` takes key away, which ends the mode by itself).
- **The mode honors OS key repeats; the global matcher still ignores them.** Holding `k` to skim back
  through sessions is what a bare-key bind is for, so the repeat guard sits AFTER the normal-mode branch,
  where it keeps a held custom-command chord to one spawned process. A command target inside the mode is
  the one exception: `.firedCommand` skips the spawn on a repeat and still CONSUMES the key, so holding a
  key bound to a command runs one process while a built-in bind beside it keeps firing per repeat.
- ⚠️ **A Command chord the mode does not own goes to the GLOBAL MATCHER, not through the mode.** Passing it
  through was enough while every Command chord had a menu item behind it, but `toggle_fullscreen` has none
  (agterm ships no full screen item) and neither does a custom command or a sequence-bound built-in, so all
  of them reached nothing and died for as long as the mode was on. The fall-through covers the whole class;
  do not restore a per-action copy inside the branch. It applies only with no normal-mode leader armed — an
  armed leader outranks a Command chord as it outranks the matcher — and a fullscreen chord rebound to a
  BARE key stays the mode's to swallow, like any other `map` bind. Pinned by
  `FullScreenChordTests.testShippedChordStillTogglesWhileNormalModeIsOn` and
  `NormalModeKeyRoutingTests.testACommandChordBoundToACustomCommandStillFiresWhileTheModeOwnsTheKeys`.
  A Command chord matching nothing still passes through, so ⌘Q reaches the menu bar.
  ⚠️ One that only ARMS a sequence (`map cmd+r>t …`) passes through too, and the matcher is reset instead of
  left armed: the next chord is bare, so the mode swallows it and the sequence could never complete. Eating
  the first chord for it lost the key AND left a prefix armed in front of the `toggle_fullscreen` dispatch,
  which is guarded on `isArmed` (`NormalModeKeyRoutingTests`
  `.testACommandLeaderThatCanNeverCompleteIsNotEatenWhileTheModeOwnsTheKeys`).
  Such a sequence is inert while the mode is on, exactly as its bare-leader sibling `map ctrl+a>s …` is.
- **A Command chord and a reserved monitor chord are never consumed BY THE MODE while it is on.** The monitor
  runs ahead of `performKeyEquivalent`, so consuming ⌘Q would trap the user in the mode; ctrl+tab and
  ctrl+1/2 belong to `SessionSwitcher`/`PaneShortcuts`, whose monitors run whatever the mode is and whose
  registration order among the four `.keyDown` monitors is not controlled. Read the second set from
  `isReservedMonitorChord`, never a fresh list. The cost is that neither is reachable as an `nmap` bind,
  which is what the parser already says. Deciding the mode's fate from what CAUSED a focus change
  instead produced three consecutive bugs (515f5f6, 7880799, and a palette that could not type), so do not
  reintroduce a view that takes first responder for the mode.
- **The mode may only be ON while `AppActions.uiActionsEnabled` holds and a key window exists**, and both
  halves are re-checked, not just gated at entry. `enterNormalMode` refuses with no key window
  (`keyWindowProvider`, a closure so hosted tests can drive it) because the monitor reads `NSApp.keyWindow`
  and does nothing without one, and the monitor re-reads the modal gate per keystroke through the type
  method `AppActions.uiActionsEnabled(for:)` — an `nmap dashboard` bind, or a control command, opens a
  modal with the mode still on, and that surface needs the arrows and Return the mode would swallow.
- Palette `run(_:)` no-ops without an active session. A no-surface chord uses the active session when
  available; otherwise `spawnSessionless` supplies empty session fields plus frontmost window/socket so
  launchers still work. If `referencesSessionScopedContext` finds any session/workspace/selection token
  in `{...}` or `$...` form, no-op with notice; empty `{AGT_SESSION_PWD}` can turn `rm -rf .../*` into a
  root glob. Commands using only `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE` may run sessionless.
- `{AGT_PANE}`/`$AGT_PANE` is `left`, `right`, or `scratch`, derived from the firing surface for keybinds
  and `splitFocused` for palette runs. Scratch is the only sessionless surface with a pane; quick terminal
  and overlays use active-session context. A single pane is always `left`. Primary exit promotes the
  split into the main slot, clears `isSplitPane`, and makes it addressable only as `left`.
- `resolveBuiltinOverrides` is order-independent: fold last-wins candidates, resolve all final chords,
  then detect collisions. An override loses to another action's unmoved default; for two overrides, the
  later line loses. Diagnostics name the owner and sort by line. Moving `toggle_split` off `cmd+d` lets
  `new_session` take it in either line order, and an action in `builtinUnbound` resolves to no chord at
  all, so it stops occupying its shipped default here too.
- Final cross-section `validateBindings` runs after parsing all lines, over every monitor-bound
  alternative of both verbs, in two passes. `dropShadowedAlternatives` drops the alternative whose first
  chord hits a final built-in menu chord or that holds a reserved chord; it reads one alternative against
  the menu chord set, nothing else. `dropConflictingAlternatives` then settles what `keybindConflicts`
  reports. A custom command whose every alternative went ends up palette-only with `shortcut == ""`.
- **The whole conflict rule, and the only one:** compute the relation ONCE over what pass 1 left, then in a
  single pass drop BOTH sides of a cross-target duplicate-or-prefix pair and the LONGER side of a same-target
  prefix pair, which is dead anyway because `KeybindMatcher` fires the shorter. Nothing is recomputed, no
  drop cascades, and no target ranking or ordering tie-break enters it, so neither `|` order nor line order
  can decide an outcome. **Accepted cost:** an alternative whose only conflict was with one that also
  dropped still dies. That is the price of determinism — never add a recovery pass, a fixpoint or a
  re-derivation to reclaim it. Pinned by
  `KeymapTests.aBindConflictingWithTwoOthersDropsBothOfThemInEitherLineOrder`,
  `anAlternativeChargedForAConflictWithADroppedOneGoesInEitherAlternativeOrder`,
  `lineOrderDoesNotDecideWhichBindingsSurvive` and
  `alternativeOrderInsideOneBindingDoesNotDecideAnotherBindingsFate`. Only the offender a diagnostic quotes
  follows file order, where a bind conflicts with several.
  `isReservedMonitorChord` covers control+tab with any extra modifiers and control+1/2 with Control alone,
  anywhere in a leader, and also rejects built-in maps. This keeps menu and monitor registrations
  disjoint without relying on dispatch order. Standard menu items such as ⌘Q/⌘C/⌘, remain AppKit's
  responsibility.
- `BuiltinAction.defaultChord` is the sole built-in default. Every menu item resolves
  override-or-default, including the six arrow actions. Three keyed actions are delivered by a monitor
  rather than a menu equivalent: `undo_close` through `UndoCloseShortcut`, so native text undo still
  works, `toggle_fullscreen` through `CustomCommandRunner`, because agterm ships no full screen menu
  item for it to ride — see [[windows]] — and `normal_mode`, which owns no menu item either, so
  `CustomCommandRunner.rebuild` feeds `keymap.binding(for: .normalMode)` into `builtinSequences` and even a
  SINGLE-chord `map ctrl+space normal_mode` is dispatched by the sequence engine. All are absent from
  `keymap list`'s `menu` by design.
- Write shifted symbols as `shift+<base>`: `shift+/` for `?`, `shift+=` for `+`, `shift+5` for `%`, and
  `shift+.` for `>`. `CustomCommandRunner` uses `characters(byApplyingModifiers: [])` to recover that
  base; keep `KeymapUITests.testCustomCommandShiftedSymbolFires`.
- Named keys are `left/right/up/down/tab/space/return/delete`. `parseMapLine` rejects modifier-less
  arrows because an always-on menu equivalent would swallow navigation in terminals, palettes,
  dashboard, and text fields. Bare non-arrow built-in maps remain legal, and a bare arrow can be a
  leader tail such as `ctrl+a>left`; custom shortcuts always require modifiers.
- Host-free `namedKey(forKeyCode:)` is shared by `CustomCommandRunner` and `UndoCloseShortcut`.
  `KeybindTests` pins its range exactly to `bindableNamedKeys`; keep
  `KeymapUITests.testCustomCommandArrowChordFires` because a private-use AppKit glyph can otherwise
  create an unspellable runtime chord.
- **Resolve chords per layout, not per produced key** (issue #306).
  `KeyboardLayout.isASCIICapable` reads
  `kTISPropertyInputSourceIsASCIICapable` on every keypress (about 0.22 microseconds, no cache/observer).
  `chordKey` uses the produced character for ASCII-capable layouts and ANSI
  `latinKey(forKeyCode:)` position for non-ASCII layouts. Do not use a per-key ASCII fallback: Greek Q
  emits `;`, Hebrew Q emits `/`, and Hebrew can collapse two physical positions to `,`, causing false
  firing plus consumed input.
- Drop ISO section key code 10 on non-ASCII layouts because Ukrainian-PC `\` and Hebrew-PC `;` collide
  with table codes 42/41. Keypad/number-row aliases are deliberate because keypad output is
  layout-independent. Keep `latinKey` disjoint from named-key codes and pin every entry individually;
  real ANSI constants are non-monotonic at 4/5, 22/23, and 25/26/28/29. Non-ASCII layouts can bind only
  Latin positions, not their produced Cyrillic glyphs.
- Do not merge this policy with `InterruptKeystroke`, which classifies one produced letter.
  The live non-Latin monitor branch cannot be unit-tested because tests cannot change the input source.
  `characters(byApplyingModifiers: [])` re-translates synthesized runner events through the live layout;
  `UndoCloseShortcut` uses verbatim `charactersIgnoringModifiers`. Hosted tests pin wiring and named-key
  precedence; host-free tests take `layoutIsASCIICapable`.
- Do not switch the runner to `charactersIgnoringModifiers`: it breaks shifted-symbol normalization and
  still cannot test the non-Latin branch. The accessor means `undo_close` cannot match shifted
  punctuation/digits on ASCII layouts (`shift+/` parses `/`, but runtime reports `?`); shifted letters
  work, and non-ASCII physical lookup works. `UndoCloseShortcutTests` skips when the machine layout is
  non-ASCII. `NormalModeKeyRoutingTests` deliberately does NOT: every key code it sends is a `latinKey`
  table position typing the letter its bind is spelled with, so a non-ASCII layout resolves the same
  chord by physical position, and the skip hid two thirds of that suite behind the current input source.
  After monitor changes, manually verify a letter, `cmd+r>t`, `ctrl+a>d`, and ⌘Z on isolated
  Russian-Phonetic and U.S. instances. Russian-Phonetic does not cover Greek/Hebrew punctuation, which
  host-free measured-data tests cover.
- `ghostty.conf` has a separate upstream grammar: bare `g` is Unicode and `key_g` physical; Unicode
  triggers cannot fire on non-Latin layouts. agterm matches Ghostty.app and cannot fix this app-side.
  Use `key_`, as `ghostty-defaults.conf` does for `super+key_c/key_v/key_a` (issue #30).
  The `ghostty` section of `site/docs.html` documents the distinction.
- A built-in reaches a leader only as an alternative, such as `map ctrl+space>s toggle_split`, never as
  its menu equivalent: an `NSMenuItem` holds exactly one key-equivalent character. Literal `+`/`>` are
  separators and not bare tokens, but bind as `shift+=`/`shift+.`. `increase_font_size`'s stored
  `Chord(key:"+")` cannot round-trip and prints `(not expressible)` in the starter file. Ctrl-Tab and
  Ctrl-1/2 are reserved, monitor-driven, and not rebindable. Palette custom hints use raw kitty syntax,
  not macOS glyphs.
- `shortcutGlyph(for:)` over `glyphHint(for:)` is the single resolver behind built-in palette hints and
  the toolbar/sidebar tooltips. It space-joins the menu chord's glyphs and each alternative's, a sequence's
  own chords joined by `>` so a run cannot read as one chord (`⌘T ⌃␣>S`),
  returns the alternatives alone for an unbound action, and nil when there is neither.
- The starter file's `map` and `command` examples are literal chords that rot when a new built-in claims
  one, as `dashboard` previously did to the shipped `cmd+shift+d` (issue #405). Keep
  `ConfigPathsTests.starterKeymapExamplesApplyWhenUncommented`, which uncomments every example, requires
  it to parse clean, and counts the chords that survive.
  Both verbs rot: `validateBindings` clears a custom shortcut a built-in has claimed just as
  `resolveBuiltinOverrides` drops the colliding `map`.
- New shipped defaults must not break a valid existing keymap. `parseKeymap` vacates the new horizontal
  split default when an old file explicitly uses `cmd+shift+d`, and vacates Dashboard's new default when
  an old file explicitly uses `cmd+shift+g`. An explicit map for the new action opts into its new chord.
- **`{AGT_X}` interpolation is intentionally raw and unquoted.** Selection, OSC title, OSC 7 pwd, and the
  session/workspace/window names and `--cwd` a caller supplies over control or the GUI can all inject
  visible shell metacharacters. `TerminalText.sanitized` strips control characters, not `;`,
  `$()`, or backticks. Prefer quoted exported `"$AGT_X"` variables for untrusted text. Do not add quoting
  to `CommandContext.expand`.
- File > Reload Keymap, the palette entry, and `keymap.reload` all call
  `AppActions.reloadKeymap()` > `SettingsModel.reloadKeymap()`, which reparses and posts
  `.agtermKeymapChanged`. Apply the Control API four-point audit.
- Edit Keymap is GUI-only. `AppActions.editKeymap()` opens a 95% floating overlay with
  `ConfigPaths.editorCommand(forPath:)`:
  `${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\''${VISUAL:-${EDITOR:-vi}} "$1"'\'' agterm-config-edit '<path>''`.
  The interactive login shell loads exported editor variables; inner POSIX `sh` handles
  `${VAR:-default}` for fish and receives the single-quoted path as `$1`. Supported shells must accept
  `-ilc` and preserve single quotes (sh/bash/zsh/fish, not csh/tcsh); non-exported editor variables fall
  back to vi. Running POSIX expansion directly under fish exits 127. `ConfigPathsTests` cover zsh,
  optional fish, VISUAL precedence, rc sourcing, and quoting.
  Overlay close reloads only the recorded edit session. No control command is needed because scripts can
  compose `session overlay open "$EDITOR <path>" --size-percent 95`.
