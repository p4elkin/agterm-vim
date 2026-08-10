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

Press `i` or Esc to leave the mode and get the keyboard back.

## Requirements

- agterm 0.22.0 or later, where `nmap` and normal mode ship.

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

# space leader for the rest
nmap space>s toggle_split
nmap space>n new_session
nmap space>d dashboard
nmap space>p>a command_palette
nmap space>p>s session_palette
```

Drop the lines you have no use for; each stands alone. Pick a different chord than `ctrl+space` if it
already does something on your machine — see *Limits*.

## Usage

Press ⌃Space. The titlebar shows a pill while the mode is on, and the armed leader when one is
pending (`space` alone shows as an armed prefix until the second key lands). Type a bound key or
sequence; unbound keys are swallowed and do nothing. Press `i` or Esc to leave the mode; typing goes
back to the shell immediately.

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
what `ctrl+space` is here, and Esc's only job stays leaving the mode once you are in it (`i` does the
same). Reaching for `i` mirrors vim's own insert/normal pair, which is also why entering the mode is a
separate action (`normal_mode`) rather than reusing Esc for both directions.

Command chords always pass through while the mode is on, so ⌘Q, ⌘W, and every other menu shortcut work
exactly as before. So do ⌃Tab, ⌃1 and ⌃2, which agterm reserves for the session switcher and pane focus.
A pane click, a text field taking focus (a palette's search box, an inline rename), or the window losing
key status all leave the mode too, so it never survives past the moment your attention moves somewhere
else.

`space>d` is the same story from the other side: the dashboard wants the arrows and Return, so the mode
steps aside for it, exactly as it does for the dashboard, terminal zoom or a picker opened any other way.
Holding a bound key repeats it, so `k` held down walks back through sessions.

## Limits

`ctrl+space` is a common macOS shortcut for switching input sources (System Settings ▸ Keyboard ▸
Input Sources) and for some Spotlight/launcher setups. If either owns it on your machine, agterm never
sees the key at all; pick another chord with a modifier, such as `ctrl+shift+space`.

While the mode is on, every key it does not recognize is swallowed rather than passed to the shell.
Typing `hello world` in normal mode does not send `hello world`; press `i` first.

`nmap` binds nothing outside normal mode, and `map` binds nothing inside it — the two tables never
interact, so a bare `d` typed here does not fire `space>d` and a `⌘D` still runs whatever `map` (or the
default) has it bound to.
