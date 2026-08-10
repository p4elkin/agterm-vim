# Vim-style normal mode

A `keymap.conf` preset that turns j/k/h/l, a `g>g`/`G` pair, and a `space` leader into vim-flavored
navigation, using normal mode so the bare keys never reach a shell.

## What it does

One entry point, `map ctrl+space normal_mode`, arms a mode where keys stop reaching the terminal and
bare-key binds become legal. Everything else is `nmap`, live only while the mode is on:

- `j` / `k` — next / previous session
- `h` / `l` — focus the left / right split pane
- `g` then `g` — first session; `shift+g` (`G`) — last session
- `s` — toggle the scratch terminal; `t` — quick terminal
- `space` then `s` — toggle split; `n` — new session; `d` — dashboard
- `space` then `p` then `a` — command palette; `space` then `p` then `s` — session palette
- `space` then `y` — a custom command, to show that an `nmap` target can be one

Press `i` to leave the mode and get the keyboard back, or Esc to leave it and put the program in the pane
into its own normal mode.

## Requirements

- agterm 0.22.0 or later, where `nmap` and normal mode ship. The quoted `space>y` target needs the build
  where an `nmap` line gained custom-command targets; drop that line and the `command` above it on an
  older one. Esc handing its keypress down to the pane is newer still — on an older build every bind here
  works and Esc simply leaves the mode.

## Setup

Add the lines to `~/.config/agterm/keymap.conf` and apply the file with File ▸ Reload Keymap or
`agtermctl keymap reload`.

```
# ctrl+space arms normal mode. It ships with no default chord, so nothing binds until this line exists.
map ctrl+space normal_mode

# session and pane navigation
nmap j next_session
nmap k previous_session
nmap h focus_left_pane
nmap l focus_right_pane
nmap g>g first_session
nmap shift+g last_session

# bare-key toggles
nmap s toggle_scratch
nmap t quick_terminal

# `/` is vim's search, and the session palette IS the session search
nmap / session_palette

# `dd` deletes the line; here it closes the session. Note close_session is the Command-W
# ladder: with the quick terminal or the scratch up it dismisses THAT first and leaves the
# session alone, so press it at a bare pane.
nmap d>d close_session

# space leader for the rest
nmap space>s toggle_split
nmap space>n new_session
nmap space>d dashboard
nmap space>p>a command_palette
nmap space>p>s session_palette

# a quoted target names a custom command instead of a built-in action
command "Copy pwd" printf %s "$AGT_SESSION_PWD" | pbcopy
nmap space>y "Copy pwd"

# `Y` then `p` MOVES a session rather than cutting it, so nothing is destroyed in between.
# Y records the id; p relocates that session next to wherever you are. `--after active`
# relocates and positions in one shot, carrying the anchor's workspace, so p needs no
# workspace lookup and works across workspaces.
command "Yank session" printf %s "{AGT_SESSION_ID}" > "${TMPDIR:-/tmp}/agterm-session-yank"
command "Paste session here" id=$(cat "${TMPDIR:-/tmp}/agterm-session-yank" 2>/dev/null); [ -n "$id" ] && agtermctl session move --after active --target "$id"
nmap shift+y "Yank session"
nmap p "Paste session here"
```

Drop the lines you have no use for; each stands alone. Pick a different chord than `ctrl+space` if it
already does something on your machine — see *Limits*.

## Usage

Press ⌃Space. The titlebar shows a pill while the mode is on, and the armed leader when one is
pending (`space` alone shows as an armed prefix until the second key lands). Type a bound key or
sequence; unbound keys are swallowed and do nothing.

`Y` and `p` are the one pair that carries state between presses: `Y` records the session you are on,
then `p` moves it beside whichever session you are on when you press it, across workspaces. Nothing is
closed in between, so a `Y` you never paste costs nothing.

Two ways out, and they are not the same. `i` leaves the mode and typing goes back to the shell
immediately. Esc leaves the mode and also sends an Escape to the pane, so vim, zsh vi-mode at a prompt and
Claude Code's vim mode all end up in their own normal mode — the mode carries down instead of stopping at
agterm. No extra `nmap` line makes that happen; it is what Esc does.

## How it works

Normal mode is a second binding namespace, live only while the mode is on, so `nmap` can bind bare
keys that would otherwise be swallowed by every keystroke reaching the shell. `map` still needs a
modifier on its first chord for exactly that reason.

`s` and `space>s` do not conflict, and that pairing is the clearest example of why: a leader sequence
is matched by its first chord, and `s` and `space` are different first chords. The matcher arms on
`space`, waits for the next key, and only then decides between `space>s`, `space>n`, `space>d`, and
the two `space>p>*` sequences; a bare `s` press never enters that wait at all. The same binding table
holds both tiers, one keyed on `s` directly and the others keyed on `space`, and there is no ambiguity
between them.

Esc never arms the mode from the terminal, on purpose. If it did, no program running inside agterm
could see a plain Esc again — vim's insert-mode exit, `less`, and `fzf` all depend on it reaching them
unmodified. So the mode has to be entered from a chord the terminal never uses for anything, which is
what `ctrl+space` is here. Esc's job starts once you are already in the mode, and there it means what it
means in vim: leave agterm's normal mode and be in normal mode, so the pane gets the Escape too. `i` is the
other half of the pair and means insert at both layers, so it sends nothing. Entering stays a separate
action (`normal_mode`) rather than reusing Esc for both directions.

One case sends nothing on purpose: Esc while a leader is half-typed (`space` pressed, waiting for the next
key) only abandons the sequence and keeps you in the mode. Sending an Escape there would put a stray
keystroke in your shell while the mode still swallows everything else.

Command chords always pass through while the mode is on, so ⌘Q, ⌘W, and every other menu shortcut work
exactly as before. So do ⌃Tab, ⌃1 and ⌃2, which agterm reserves for the session switcher and pane focus.
A pane click, a text field taking focus (a palette's search box, an inline rename), or the window losing
key status all leave the mode too, so it never survives past the moment your attention moves somewhere
else.

`space>d` is the same story from the other side: the dashboard wants the arrows and Return, so the mode
steps aside for it, exactly as it does for the dashboard, terminal zoom or a picker opened any other way.
Holding a bound key repeats it, so `k` held down walks back through sessions. A key bound to a custom
command is the exception: the repeats are swallowed and the command runs once, so a held key cannot pile
up processes.

A quoted `nmap` target is the name of a `command` line, which is why `space>y` above works whether that
`command` sits before or after it — names are resolved once the whole file has been read. A target
naming no command shows up as `unknown command '<name>'` on that line in Settings ▸ Key Mapping and in
`agtermctl keymap list`, and only that one bind is dropped.

## Limits

`ctrl+space` is a common macOS shortcut for switching input sources (System Settings ▸ Keyboard ▸
Input Sources) and for some Spotlight/launcher setups. If either owns it on your machine, agterm never
sees the key at all; pick another chord with a modifier, such as `ctrl+shift+space`.

While the mode is on, every key it does not recognize is swallowed rather than passed to the shell.
Typing `hello world` in normal mode does not send `hello world`; press `i` first.

`nmap` binds nothing outside normal mode, and `map` binds nothing inside it — the two tables never
interact, so a bare `d` typed here does not fire `space>d` and a `⌘D` still runs whatever `map` (or the
default) has it bound to.
