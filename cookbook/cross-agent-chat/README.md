# Cross-agent chat

Let your Claude Code sessions message each other without a long message landing as a wall of text in the middle of the receiver's work, keep every exchange as a conversation, and read it back in an overlay with one chord.

## What it does

Claude Code sessions can message each other with `SendMessage`, addressing a peer by the name `ListAgents` shows. It works, and it has one problem: the message arrives spliced into the receiving session's turn. A three-line question is fine. A 2000-character handover is not — the receiving agent has to read the whole thing before it can go back to what it was doing, and you have to scroll past it afterwards.

This recipe puts a hook in front of every outgoing message. A short one travels whole. A long one is written to disk and replaced on the wire by one line:

```
msg-142907-3f1a from d1-stack-prep: the migration needs a second index before it can run
Full text: ~/.local/state/agterm-xchat/msgs/msg-142907-3f1a.md
Read it when your current step finishes. It does not need to interrupt you. Reply with
SendMessage to "d1-stack-prep".
```

The receiving agent opens that file when it reaches a gap, instead of being interrupted mid-step. Both sides get the same message recorded in full, as a thread with that one peer.

The chord opens the threads for the row you pressed it in, as an overlay. One conversation opens straight away; several go through an fzf picker with each thread previewed as it will look. What you get is a conversation, wrapped to the window, with the markdown agents write rendered rather than shown:

```
Conversation with d1-stack-prep   6 messages

14:29:07 you [normal] msg-142907-3f1a the migration needs a second index
The plan lands the index in the same task as the backfill. That is the wrong
order — the backfill is the thing that needs it.
────────────────────────────────────────────────────────────────────────────
14:31:44 d1-stack-prep [urgent] msg-143144-b0c2 split into two tasks, please
Agreed. Splitting task 4 in two...
```

The sending agent sets how soon a message wants reading with a marker at the start of the text: `[urgent]` says read it now, `[fyi]` says no reply needed, and no marker means read it when the current step finishes.

Nothing is pushed at you. The hook writes the record and stops there: no split stolen, no overlay forced, no panel drawn over what a session was showing. The chord is what pulls a conversation up, when you want it.

## Requirements

- agterm 0.10.0 or later. The floating sized overlay — `session overlay open --size-percent` — shipped in that release, and it is what makes this a panel over the session instead of a full-pane takeover. Everything else the recipe uses is older: `overlay open --target`, the `{AGT_SESSION_ID}` keymap token, and the `AGTERM_SESSION_ID` an overlay surface inherits from the session it opens on.
- Claude Code. The recipe hooks `SendMessage` and reads Claude Code's own registry of running sessions, so no other agent works without being ported.
- Python 3.8 or later, which macOS ships as `/usr/bin/python3`. Standard library only.
- [fzf](https://github.com/junegunn/fzf), used only when a row has more than one conversation. A row with one goes straight in and never calls it.

`AGTERMCTL`, `PYTHON` and `FZF` take an absolute path if any of those sits somewhere unusual. `XCHAT_HOME` moves the record off `~/.local/state/agterm-xchat`.

## Setup

Copy the five files into one directory and make the two shell scripts executable. They look for each other in their own directory, so keep them together:

```sh
mkdir -p ~/.local/bin/agterm-xchat
cp xchat_store.py xchat-hook.py xchat-read.py xchat-view.sh xchat.sh ~/.local/bin/agterm-xchat/
chmod +x ~/.local/bin/agterm-xchat/xchat-view.sh ~/.local/bin/agterm-xchat/xchat.sh
```

Register the hook twice in `~/.claude/settings.json`, alongside whatever is already there. The `PreToolUse` entry is the one that does the work; the `SessionStart` entry only records which agterm row a session is running in, which is what lets the chord find its conversations:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.local/bin/agterm-xchat/xchat-hook.py",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "SendMessage",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.local/bin/agterm-xchat/xchat-hook.py",
            "timeout": 10,
            "statusMessage": "Parking cross-agent message"
          }
        ]
      }
    ]
  }
}
```

Leave the `PreToolUse` entry synchronous. The rewrite is this hook's answer to Claude Code, so it only takes effect if Claude Code is waiting for it when the tool call goes out; adding `async: true` there keeps the record and quietly drops the rewriting.

Then add the chord to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Cross-agent chat" ctrl+a>m /usr/local/bin/agtermctl session overlay open ~/.local/bin/agterm-xchat/xchat-view.sh --size-percent 85 --target {AGT_SESSION_ID}
```

`ctrl+a>m` is a leader sequence: press ⌃A, release, then press M. Pick a chord that is free in your own keymap — a custom command cannot shadow a built-in, so one that collides is quietly demoted to palette-only and the chord appears to do nothing. `agtermctl keymap list` reports what every chord resolved to. Either way the command is reachable by name from the action palette, which is the quickest way to tell a bad chord from a broken script.

The absolute `/usr/local/bin/agtermctl` is deliberate. A custom command runs as a detached `/bin/sh -c` under launchd's `PATH`, which before agterm 0.22.0 held neither `/usr/local/bin` nor Homebrew, so a bare `agtermctl` there exits 127 with its diagnostic thrown away and the chord looks dead. `/usr/local/bin` is where **Help ▸ Install Command Line Tool…** puts the binary.

Last, put the shell command on your `PATH` if you want to read the record from a plain shell or over ssh:

```sh
ln -s ~/.local/bin/agterm-xchat/xchat.sh ~/.local/bin/xchat
```

Two settings, both read from the environment. Put them in front of the command in the hook entry, or export them where your agents start:

- `XCHAT_THRESHOLD=400` is the size in characters at which a message is replaced by a pointer. Below it, the message travels whole and is still recorded.
- `XCHAT=off`, or a file named `xchat-hook.off` beside the script, stands the hook down completely without editing `settings.json`.

Your agents will not use the priority markers unless they know about them. One paragraph in your `CLAUDE.md` is enough:

```markdown
When you message another session, start the text with `[urgent]` if it must be read before
the receiver continues, or `[fyi]` if no reply is needed. No marker means it can wait for
the end of the current step. Long messages are parked automatically and arrive as a pointer.
```

## Usage

Press the chord in a row that is running an agent. With one conversation you land in it; with several you pick first, each previewed on the right. `q` closes the pager, Escape closes the picker, and closing the overlay changes nothing — you are reading a record, not holding it open.

From a shell, the same record without the overlay:

```sh
xchat list                       # conversations this row has, newest first
xchat log                        # print the one conversation this row has
xchat log d1-stack               # print one, named by any prefix of the peer
xchat read msg-142907-3f1a       # one message in full, as the receiver sees it
xchat who                        # which Claude sessions this row resolves to
xchat show                       # open the overlay picker, same as the chord
```

`--session NAME` reads for a session other than the one you are sitting in, which is what you want over ssh or in a shell outside agterm.

A message the hook parked is a file. Any agent can read it with the path in the pointer, and so can you — `xchat read` prints it with its headers.

## How it works

**The interception has to happen on the sender.** There is no hook event for an incoming cross-session message. `MessageDisplay` fires on assistant text, is display-only, and cannot suppress anything. So nothing on the receiving side can keep a long message out of its own chat, and the only lever left is `PreToolUse` on the session doing the sending: it returns `updatedInput`, and Claude Code sends the rewritten tool input instead of the original. That single fact shapes everything else here — the record is written by the sender, for both sides, before the message travels.

**A pane is joined to its agent by the hook, not by a search.** The chord knows only `AGTERM_SESSION_ID`, the agterm row it fired on. The record is keyed by Claude session. Nothing on disk connects the two by itself, and finding out by scanning processes means reading another process's environment with `ps -E`, which prints that process's *entire* environment — API keys and tokens included — for the sake of two variables. The hook makes the scan unnecessary: it runs as a child of the Claude process, which was started by the row's own shell, so the `AGTERM_*` variables agterm exported into that shell are already in its environment, next to the `session_id` the payload hands it. It writes the pairing down at `SessionStart` and again on every message sent, and the chord reads it. That is the whole join, and it is why the `SessionStart` entry is not optional.

**A session is identified by its id, and named only for display.** Claude Code renames a session as the work in it changes, so a thread keyed on the name would split in two the first time that happened. Threads are keyed on the Claude session id instead. The one place a name still has to be resolved is the recipient of a `SendMessage`, which is a name by definition: that goes through `~/.claude/sessions/<pid>.json`, Claude Code's own registry of running sessions, which is the same file set `ListAgents` reads. A `<pid>.json` is never deleted when its process dies and pids get reused, so a live entry wins over a dead one and the newest wins within each group.

**One thread per peer, two copies.** A session can be talking to several agents at once, and a single merged log makes each exchange unfollowable — you cannot read one without reading all of them interleaved. Each side gets its own copy of each message, under its own session id, so each reads its own view without depending on the other still existing. A row that has restarted its agent holds several session ids; the reader merges their threads by peer name, so restarting `claude` in a tab does not take yesterday's conversation off the screen.

**Messages are stored structured and rendered at view time.** The width text should wrap to belongs to the window it is being read in, which the sender cannot know. So nothing is pre-formatted. The reader wraps prose to the real width, renders the markdown agents actually write, and leaves fenced code, indented code and table rows alone, because wrapping those destroys them.

Four details cost real time to find:

**An overlay starts under the app's `PATH`**, measured as `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:` plus the agterm bundle. No `/opt/homebrew/bin` and no `~/.local/bin`, so a bare `fzf` reads as not installed, the script exits 127, and the overlay flashes shut with nothing on screen to say why. `xchat-view.sh` widens `PATH` on its first line.

**`overlay open` takes a program, not a program plus arguments.** That is the only reason `xchat-view.sh` is a file rather than a line in `keymap.conf`.

**`tput cols` reports 79 inside an overlay** however wide the window is, which wrapped every message into a narrow column and wasted most of the screen. Ask the tty instead, with `stty size < /dev/tty`. Wrap the whole thing in braces, not just the `stty`: when there is no controlling terminal the *redirect* is what fails, and the shell reports that on its own stderr, outside anything you redirected.

**Session names are not identifiers.** They carry spaces, Cyrillic and status glyphs, so the fallback filename slug keeps unicode word characters and drops back to a hash when nothing usable survives — an ASCII-only sanitizer turns a Cyrillic name into a row of dashes. For the same reason every shell pipeline here stays tab-separated and is never re-split on spaces: running the rows through `column -t` and taking the second word returns the second word of somebody's *name*, which is how a picker ends up opening a file that does not exist.

## Limits

- **It rewrites what your agents say to each other.** A message at or above the threshold does not arrive as you wrote it: the receiving agent gets a pointer and has to open a file to read the rest. An agent that ignores the pointer never reads the message at all. `XCHAT_THRESHOLD` sets the size, and a very high value turns the rewriting off while keeping the record.
- **It keeps every cross-agent message on disk, in the clear**, under `~/.local/state/agterm-xchat`. Whatever your agents say to each other is in those files, twice — once as the message and once in each side's thread. Nothing prunes them and nothing expires. Delete the directory to clear it.
- The hook sits in the path of every `SendMessage`. It fails open on every path, so a failure means a message travels unchanged rather than not at all, but it is one more thing between two agents.
- A session started before you installed the hook is unpaired, so the chord finds nothing for its row until it sends its first message or is restarted. `xchat who` says which sessions a row resolves to.
- Two live sessions with the same name cannot be told apart. `SendMessage` disambiguates them with a `[ref]` suffix, which nothing else on disk carries, so the receiver's copy is filed under whichever of the two the registry resolves first. Your own copy is always right.
- A peer that is not in the registry at all — already gone, or renamed between the send and the hook — still gets your copy recorded, keyed on its name instead of its id. It just does not get a copy of its own.
- Claude Code only. Another agent would need its own hook, and its own answer to which session a row is running.
- Reading is one direction only. The overlay shows the conversation; replying is something you ask the agent in the pane to do.
