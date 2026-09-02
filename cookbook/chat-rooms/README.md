# Chat rooms

Split one conversation into rooms held as files, read them in the pane next to the agent, and keep the chat carrying one line per room instead of every answer.

## What it does

Ask an agent six questions in one message and you get six answers in one reply, competing for the same space. Measured over the 60 largest session transcripts in one setup, 6884 user turns: 44% of annotation batches carry more than one note, and the answer per note falls from about 2300 characters when a note arrives alone to about 740 in a batch of six. Nothing is lost — the agent comes back to a dropped note in 0.07% of turns — but each answer gets thinner as the batch grows, while the tool calls behind it go from 2 to 11.

The cause is that every answer competes for one reply. This recipe gives an answer its own destination.

The agent writes a long answer into a **room**, which is a file, and keeps one line in the chat:

```
[room] "the overlay PATH trap" — msg-142907-3f1a — why the plain revdiff wins
```

The pane beside the agent runs a viewer that lists the rooms with their unread counts and previews the selected one. It updates on its own when the agent writes, with no keypress:

```
room >                                        │ the overlay PATH trap
> the overlay PATH trap            2          │
  what the cursor file is for      1          │ 19:41:02 claude — why the plain revdiff wins
  where the follow-up goes                    │ An overlay starts under the app's PATH, which
                                              │ holds no ~/.local/bin, so the Homebrew build
                                              │ wins and it has no markdown preview...
```

`enter` reads a room in a pager and marks it read. `ctrl-o` opens it in revdiff, where tables are drawn as tables and a mermaid block as box art. `ctrl-s` replies: your text goes into the room and one line goes into the agent's pane as real keystrokes, so a long reply never lands as a wall of text in the middle of the agent's work.

The agent never reads a room back. The answer was already in its context on the way out, so a re-read would carry the whole file for the rest of the session. The viewer is a separate process reading files, so it costs nothing in tokens.

## Requirements

- agterm 0.22.0 or later. `tree --json` reports `hasSplit` beside `split` in that release, which is how the restore hook tells a session whose second pane is hidden with ⌘D from one with no split at all — without it the hook opens a second split over a viewer that is already running. Everything else it uses is older: `session split`, `session type --stdin --pane`, and the `pickPending` and `overlay` read-backs on `tree`.
- Claude Code. The hook is a Claude Code `SessionStart` hook, and rooms are keyed on the Claude session id read from Claude Code's own registry, so another agent needs porting.
- Python 3.8 or later, which macOS ships as `/usr/bin/python3`. Standard library only.
- [fzf](https://github.com/junegunn/fzf) 0.42.0 or later. The viewer is one long-lived fzf; `--listen` with no port and the `$FZF_PORT` it exports are what let the watcher push a reload into it, and both shipped in 0.42.0.
- `curl`, to post that reload to the port. Both `curl` and `less` come with macOS.
- [revdiff](https://github.com/umputun/revdiff), optional, for `ctrl-o`. Without it the key falls back to the pager.

`AGTERMCTL`, `PYTHON`, `FZF`, `CURL` and `REVDIFF` each take an absolute path when the binary sits somewhere unusual. `XCHAT_HOME` moves the record off `~/.local/state/agterm-xchat`, which is the same directory the `cross-agent-chat` recipe uses; the two share a home and do not share code.

## Setup

Copy the six files into one directory. They find each other by their own path, so keep them together. Three are executed directly and carry the executable bit; `rooms-read.py` and `rooms-restore-hook.py` are run through `python3`, and `xchat_store.py` is imported by the others and never run at all:

```sh
mkdir -p ~/.local/bin/agterm-rooms
cp xchat_store.py rooms-write.py rooms-read.py rooms-view.sh rooms-send.sh rooms-restore-hook.py \
   ~/.local/bin/agterm-rooms/
chmod +x ~/.local/bin/agterm-rooms/rooms-write.py \
         ~/.local/bin/agterm-rooms/rooms-view.sh \
         ~/.local/bin/agterm-rooms/rooms-send.sh
```

Register the hook in `~/.claude/settings.json`, alongside whatever is already there. It opens the viewer in the right pane when a session starts and that pane is not already running it, and it records which agterm row the Claude session runs in, which is the only join the viewer has:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.local/bin/agterm-rooms/rooms-restore-hook.py",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

Then teach the agent when to open a room. Nothing in the code enforces any of this — the writer opens whatever room it is told to — so this paragraph in your `CLAUDE.md` is the whole policy:

```markdown
Long answers go into a chat room instead of the reply. Write one with
`~/.local/bin/agterm-rooms/rooms-write.py "<room title>" --summary "<one line>"`,
body on stdin, and put the line it prints in the reply.

- Open a room for a note only when the answer will run past about a screen AND it has
  its own follow-up life. A decision, a rejection or a one-paragraph answer has neither,
  so it stays in the chat. When in doubt, answer in the chat: a room nobody needed is
  worse than a paragraph nobody wanted.
- Read a whole batch of notes before writing anything, and route each note separately.
  Wanting more than about three rooms from one batch means the work should have been a
  plan document rather than a chat.
- A question asked in the chat is answered in the chat. A question asked inside a room is
  answered in that room, by writing to the same room title.
- Never move an AskUserQuestion option list or a TodoWrite list into a room, and never
  move the question a long answer ends in. Put the argument in the room and keep the
  question in the reply.
- When a follow-up arrives in a room whose contents are no longer in your context, read
  that one room file before answering it. That is the only time you read a room.
```

Two settings, both from the environment: `XCHAT=off`, or a file named `rooms-restore-hook.off` beside the script, stands the hook down without editing `settings.json`. `XCHAT_ROOM_PREFIX` changes the `[room]` prefix the reply path types into the pane.

## Usage

The viewer comes up on its own at session start. In it:

| key | what it does |
|---|---|
| ↑ ↓ | move the selection; previewing never marks a room read |
| enter | read the room in a pager, and mark it read |
| ctrl-o | open the room in revdiff — real tables, mermaid as box art, annotatable |
| ctrl-s | reply in the selected room, and type one line into the agent's pane |
| esc | close the viewer |

The agent writes a room as it writes the answer:

```sh
rooms-write.py "the overlay PATH trap" --summary "why the plain revdiff wins" <<'EOF'
...the answer...
EOF
```

It prints the pointer line for the chat. `--body-file` reads the answer from a file, `--session` writes to a named Claude session instead of the one in the process tree, and `--paths` prints the body's path on a second line.

From a shell, the same record without the viewer:

```sh
rooms-read.py list                       # rooms of this row, with unread counts
rooms-read.py show --room "the trap"     # print one room, wrapped
rooms-read.py markdown --room "the trap" # write it out as markdown, print the path
rooms-send.sh --room "the trap" --session <id> --text "why not the other one?"
```

`--row ID` or `XCHAT_SESSION=<claude-session>` reads for a session other than the one you are sitting in, which is what you want over ssh or in a shell outside agterm.

## How it works

**The record splits, the context does not.** This is one Claude session throughout. The answer text passes through the transcript exactly as it would have in a chat reply, so writing it to a room costs nothing extra; what changes is where it lands. The chat keeps a short index in place of the full answers.

**Unread counts are a byte offset.** A room is `rooms/<claude-session>/<slug>.jsonl`, one JSON line per message, appended. Beside it sits `<slug>.cursor` holding the offset already read. The unread count is the number of lines after that offset, and opening a room writes the cursor forward. That is the whole badge mechanism, and it is why the count drops the moment you press enter and comes back the moment the agent appends.

**Rooms key on the Claude session id, never on its name.** Claude Code rewrites a session's name as the work in it changes, so a room keyed on the name would split in two the first time that happened. The hook writes the id-to-row pairing down at session start, because it runs as a child of the Claude process and the row's `AGTERM_SESSION_ID` is already in its environment. Reading another process's environment to find that out means `ps -E`, which prints that process's entire environment, tokens included.

**Reading to stay correct, never to stay current.** The agent does not poll rooms. If it did, every room would become a recurring tax on the rest of the session. There is one exception, and it is required rather than allowed: when a follow-up arrives in a room whose answer is no longer in context, the agent reads that one room file before answering. A compact drops room answers, because they left the session through a tool call rather than as reply text, so without that read the agent answers a thread it does not remember writing. It is one bounded read of one file, on arrival.

**Where a follow-up goes decides whether rooms work at all.** A room is a thread with turns. A question asked inside a room is answered in that room; a question asked in the chat is answered in the chat. Without that rule the rooms are dead ends — you ask for a change in room three and the answer appears somewhere else — and with it the chat keeps its reports and decisions instead of decaying into nothing but pointers.

**Some things can never move.** An `AskUserQuestion` option list and a `TodoWrite` progress list are rendered by the harness and answered by clicking. A room is a file, and the room's only input is the typing path, which carries free text and cannot return a selection. That is a missing mechanism, not a preference. The question a long answer ends in is the same case for a different reason: put it in a room and it sits unread while the agent waits for an answer you cannot see without opening the room, which is a stalled conversation with no visible cause. Static formatting is the opposite and moves freely — a table reads as raw pipe text in the viewer and a mermaid block as dimmed source, both enough to skim, and `ctrl-o` draws them properly.

**Reading is two-tier on purpose.** The viewer wraps to the real width, renders the markdown agents write, and leaves fenced code, indented code and table rows alone, because wrapping those destroys them. Anything more — a real table, a diagram, an annotation on one line — is `ctrl-o` into revdiff. Two builds of revdiff answer to that name and only the patched one has a markdown preview mode, so the script asks `revdiff --help` for `--preview` and says plainly which one it got.

Four details cost real time to find:

**A pane opened by a hook, and an overlay, both start under the app's `PATH`**: `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` plus the agterm bundle. No `/opt/homebrew/bin` and no `~/.local/bin`, so a bare `fzf` reads as not installed, the script exits 127, and the pane shows nothing that says why. Both shell scripts widen `PATH` on their first line, and `~/.local/bin` goes **first**: with Homebrew first the plain revdiff 1.11.1 wins, and that build has no markdown preview mode at all.

**`overlay open` takes a program, not a program plus arguments.** That is why `rooms-view.sh` takes the row as `$1` rather than through a flag, and why it is a file instead of a line in `keymap.conf`.

**`tput cols` reports 79 inside an overlay** however wide the window is, which wraps every room into a narrow column and wastes most of the screen. Ask the tty instead, with `stty size < /dev/tty`. Wrap the whole thing in braces rather than just the `stty`: with no controlling terminal it is the *redirect* that fails, and the shell reports that on its own stderr, outside anything you redirected.

**Room titles are not identifiers.** They carry spaces, Cyrillic and glyphs, so the filename is a slug that keeps unicode word characters and falls back to a hash when nothing usable survives. Every pipeline here stays tab separated and is never re-split on spaces: fzf hands back the whole line, the room file comes off field 3, and taking the second word of a row would return the second word of somebody's room title.

## Limits

- **The reply path types real keystrokes into the agent's pane.** Keystrokes go wherever focus is, so `rooms-send.sh` reads `tree --json` first and refuses when an overlay, the scratch pane or a pending picker covers the target pane. It refuses before writing anything, so a refused reply is not half-sent — but a pane that changes between the check and the keystrokes is a race nothing can close.
- **The restore hook types into the right pane on a fresh session start.** It fires only when Claude Code reports the start `source` as `startup`, never on a resume, a `/clear` or an auto-compact — those land mid-session, where the pane may hold a half-typed command that the injected line would complete and run. It also refuses when the split is already running the viewer, and when a foreground program is running there. What remains is a shell sitting in that pane, at a prompt, empty or half-typed — it will receive the command line. Note that `startup` is reported for every fresh `claude` launch, not only the first one in a row, and an agterm row outlives the agent process, so this is not limited to the first launch of the day. No tree field reports what is sitting unsent at a prompt, so the hook cannot check for it. Use the right pane for the viewer, or set `XCHAT=off`.
- **A reply is only sent to a pane that is running something.** `rooms-send.sh` refuses when the target pane is at a bare shell prompt, because the reply is typed with a trailing newline and an ordinary sentence carrying backticks or `$( )` would run as a command there. It proves no more than that: a non-empty `foreground` means some job owns the terminal, so an `ssh` session left in that pane also passes. Deliberate — the recipe does not care which agent you run, so it does not match on one.
- **Whether an answer deserves a room is a judgment call on the write path**, made by the agent, and nothing checks it. Guessing wrong toward the chat gives you a long inline answer, which is what happens today anyway. Guessing wrong the other way gives you an empty room, which is worse, so the rule in *Setup* is deliberately biased toward answering in the chat.
- **Every room is on disk in the clear**, under `~/.local/state/agterm-xchat`, twice: once as a line in the room and once as the full body in `msgs/`. Nothing prunes them and nothing expires. Delete the directory to clear it.
- **The token saving is modest.** The same answer text is written once either way. The chat gains a short index in place of the full answers, which is real but small. What this buys is attention per note, not cost.
- **One session is still one attention budget.** Rooms make the record separable and let you read one thread at a time. They cannot give two answers genuinely independent reasoning; that needs separate sessions, and separate sessions do not hold this conversation's history.
- Claude Code only, and macOS only: the watcher uses BSD `stat -f`, and the whole thing runs inside agterm.
- A session that started before the hook was installed has no row pairing, so its viewer lists nothing until it writes its first room or is restarted.
