#!/usr/bin/env python3
"""Read the chat rooms of the agent in this row: list them, or print one of them.

The viewer is a separate process reading files, so nothing here costs the agent anything.
The agent writes a room once and never reads it back.

Messages are stored structured, so the wrapping width is decided here, against the window
the room is actually being read in, rather than baked in when the answer was written.

What it does to a body, and why:

- Wraps prose to the real window width. A 900-character paragraph as one line that scrolls
  sideways was the worst thing about reading these.
- Renders the markdown agents actually write instead of showing its punctuation. `**bold**`
  becomes bold, `code` becomes coloured, headings become bold, and fence markers disappear
  while the code inside them keeps its shape.
- Leaves fenced code, indented code and table rows unwrapped. Wrapping those destroys them.
- Keeps bullets and numbered items on their own lines, with continuation indented under the
  text rather than under the marker.

A fenced mermaid block therefore reads as dimmed source and a table as raw pipe text. Both
are enough to skim; opening the room file in revdiff is the full read.

Wrapping is ANSI-aware: markup is applied before wrapping, and the wrapper measures visible
width only, so a bolded word does not make its line wrap short.

Usage:
  rooms-read.py list  [--row ID | --session NAME]   title <TAB> badge <TAB> file(s)
  rooms-read.py show  (--path FILE | --room TITLE) [--width N] [--no-color] [--mark]
  rooms-read.py markdown (--path FILE | --room TITLE) [--out-dir DIR] [--mark]
  rooms-read.py where                               the directories to watch, one per line

`markdown` writes the room out as plain markdown and prints the file it wrote. That file is
what the viewer's full-read key hands to revdiff, which renders markdown and cannot render a
room's own JSON lines.

--mark writes the room's cursor forward to the length it had when the read started, so the
unread badge clears. The preview never passes it: a preview follows the selection, and marking
there would read every room by walking past it.

`list` prints rooms and peer conversations together, newest first. A peer row carries
`peer · <name>` in its title field, so the two kinds are told apart without a fourth column
the viewer would have to render. The third field is what `show` and `markdown` take back.

--path takes one file, or several joined by commas. A peer conversation is one file per session
id of mine that talked to that peer, so all of them are read, their messages merge in time
order, and --mark marks each one to its own length.

--row is an agterm session id and defaults to $AGTERM_SESSION_ID. --session names a Claude
session instead, for a shell that is not inside agterm. Rooms are keyed on the Claude session
id, never on its name, because Claude Code rewrites the name as the work changes.

Every field is tab separated and stays that way. Room titles carry spaces, so re-splitting a
listing row on whitespace returns the second WORD of a title.
"""

import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xchat_store as store

BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
CYAN = "\033[36m"
YELLOW = "\033[33m"

ANSI_RE = re.compile(r"\033\[[0-9;]*m")
FENCE = re.compile(r"^\s*(```|~~~)")
FENCE_ONLY = re.compile(r"^\s*(?:```|~~~)", re.MULTILINE)
BULLET = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
PREFORMATTED = re.compile(r"^(\s{4,}|\t)")
TABLE = re.compile(r"^\s*\|")
HEADING = re.compile(r"^\s*(#{1,6})\s+(.*)$")
UUID_RE = re.compile(r"^[0-9a-f-]{32,40}$", re.IGNORECASE)

# A peer conversation arrives as several files in one --path value. Its own suffix is the
# separator, so a comma inside XCHAT_HOME cannot tear a path in two.
PATH_SEP = ".jsonl,"

# The kind of a row rides in its title rather than in a column of its own. `rooms-view.sh`
# renders fields 1 and 2 and takes the path from {3} in four separate binds, so any new
# column either shifts the path off {3} or is never drawn.
PEER_LABEL = "peer · "

# Use the whole window by default. A long measure does cost you something — the eye has
# further to travel back to the next line start — so XCHAT_MAX_WIDTH caps it if you want a
# narrower column. 0 or unset means no cap.
MAX_MEASURE = int(os.environ.get("XCHAT_MAX_WIDTH", "0") or 0)


def vis(s):
    """Visible length, ignoring colour escapes."""
    return len(ANSI_RE.sub("", s))


def md_inline(text, color=True):
    """Turn the markdown agents write into colour, and drop its punctuation."""
    if not color:
        return re.sub(r"\*\*(.+?)\*\*", r"\1", re.sub(r"`([^`]+)`", r"\1", text))
    text = re.sub(r"\*\*(.+?)\*\*", BOLD + r"\1" + RESET, text)
    text = re.sub(r"(?<!\w)\*([^*\s][^*]*?)\*(?!\w)", BOLD + r"\1" + RESET, text)
    return re.sub(r"`([^`]+)`", CYAN + r"\1" + RESET, text)


def wrap_ansi(text, width, initial="", subsequent=""):
    """Wrap on visible width, never splitting an escape sequence off its word."""
    words = text.split()
    if not words:
        return []
    lines, cur, indent = [], initial, initial
    for word in words:
        if vis(cur) == vis(indent) and cur.strip() == indent.strip():
            candidate = cur + word
        else:
            candidate = cur + " " + word
        if vis(candidate) > width and cur.strip():
            lines.append(cur.rstrip())
            indent = subsequent
            cur = subsequent + word
        else:
            cur = candidate
    if cur.strip():
        lines.append(cur.rstrip())
    return lines


def wrap_body(text, width, color=True):
    """Wrap prose, leave anything whose shape carries meaning untouched."""
    out = []
    in_fence = False
    blank_run = 0
    for raw in text.replace("\r\n", "\n").split("\n"):
        line = raw.rstrip()

        if FENCE.match(line):
            in_fence = not in_fence
            continue                    # the marker is noise; the indent shows the block
        if in_fence or PREFORMATTED.match(line) or TABLE.match(line):
            out.append((DIM + line + RESET) if (color and in_fence) else line)
            blank_run = 0
            continue

        if not line.strip():
            blank_run += 1
            if blank_run == 1:
                out.append("")
            continue
        blank_run = 0

        heading = HEADING.match(line)
        if heading:
            out.append((BOLD + heading.group(2) + RESET) if color else heading.group(2))
            continue

        bullet = BULLET.match(line)
        if bullet:
            lead, marker, rest = bullet.groups()
            first = f"{lead}{marker} "
            out.extend(wrap_ansi(md_inline(rest, color), width, first, " " * len(first))
                       or [first.rstrip()])
            continue

        out.extend(wrap_ansi(md_inline(line, color), width) or [""])
    return out


def render(msgs, title, width, color=True, fresh=()):
    """The conversation as text. `fresh` marks each message unread or not, one flag per message.

    A flag per message rather than a count of the last N: a peer conversation merges several
    files by time, so the unread ones are scattered through the list rather than sitting at
    the end of it.
    """
    if not msgs:
        return "This room is empty.\n"

    def c(code, s):
        return (code + s + RESET) if color else s

    fresh = list(fresh) + [False] * (len(msgs) - len(fresh))
    body_width = max(30, width - 2)
    plural = "" if len(msgs) == 1 else "s"
    head = f"{len(msgs)} message{plural}"
    if any(fresh):
        head += f", {sum(fresh)} unread"
    lines = [f"{c(BOLD, title)}   {c(DIM, head)}"]

    for i, m in enumerate(msgs):
        new = fresh[i]
        lines.append("")
        lines.append(" ".join([
            c(DIM, m.get("at", "")[-8:]),
            c(BOLD + YELLOW, m.get("from", "agent")),
            c(DIM, m.get("id", "")),
            c(CYAN if new else "", (m.get("summary") or "").strip())]))
        lines.extend(wrap_body(m.get("body", ""), body_width, color))
        lines.append(c(DIM, "─" * width))

    return "\n".join(lines) + "\n"


def markdown(msgs, title):
    """The room as a markdown document, bodies kept verbatim.

    Verbatim is the point: a fenced mermaid block or a table survives into a file revdiff can
    render, which is what the viewer's own preview cannot do.
    """
    out = [f"# {title}", ""]
    for m in msgs:
        summary = (m.get("summary") or "").strip()
        out += [f"## {summary or m.get('from', 'agent')}", ""]
        stamp = " ".join(p for p in (m.get("at", ""), m.get("from", ""), m.get("id", "")) if p)
        if stamp:
            out += [f"*{stamp}*", ""]
        body = (m.get("body") or "").rstrip("\n")
        # An unclosed fence in one body would swallow every message under it, so close it.
        if len(FENCE_ONLY.findall(body)) % 2:
            body += "\n```"
        out += [body, ""]
    return "\n".join(out).rstrip("\n") + "\n"


def split_paths(value):
    """Several files in one --path value, split on the `.jsonl,` boundary.

    A bare comma is not the separator. A slug and a session id cannot hold one, but the
    XCHAT_HOME prefix in front of them is unconstrained and a directory name may well.
    """
    parts = value.split(PATH_SEP)
    paths = [p + ".jsonl" for p in parts[:-1]] + [parts[-1]]
    return [p for p in paths if p]


def resolve_path(args):
    """The files this invocation is about, always a list, from --path or --room.

    A room is one file and a peer conversation is one per session id of mine, so both callers
    take a list and neither needs to know which kind it was handed.
    """
    path = opt(args, "--path")
    if path:
        return split_paths(path)
    title = opt(args, "--room")
    if not title:
        sys.stderr.write("rooms: pass --path FILE or --room TITLE\n")
        return []
    for sid in my_sessions(args):
        candidate = store.room_path(sid, title)
        if os.path.exists(candidate):
            return [candidate]
    sys.stderr.write(f"rooms: no room named {title!r} in this session\n")
    return []


def tail_at(path):
    """Every parseable record in this file past its cursor."""
    out = []
    try:
        with open(path, "rb") as fh:
            fh.seek(store.cursor_at(path))
            for line in fh:             # bytes, because a byte cursor is not a text one
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:      # a torn line loses one message, not the tail
                    continue
    except OSError:
        return []
    return out


def unread_at(path):
    """Messages past this file's cursor that the agent did not send itself.

    `store.unread_at` counts raw lines and cannot see a field, so it cannot serve here: the
    hook appends the sender's own copy of an outgoing message into the sender's own thread,
    and counting lines reports "N new" for messages this agent wrote. A room record has no
    `direction` at all and always counts.
    """
    return sum(1 for record in tail_at(path) if record.get("direction") != "sent")


def sizes_of(paths):
    """[(path, its length now)], captured before anything is read.

    Each file is marked to its own captured length. Taking the size again at --mark time would
    swallow a message appended while the pager was open.
    """
    out = []
    for path in paths:
        try:
            out.append((path, os.path.getsize(path)))
        except OSError:
            out.append((path, 0))
    return out


def read_paths(paths):
    """Every message across these files oldest first, which of them are unread, and the title.

    Unread is decided per file, before the merge, because a merged list interleaves by time
    and its tail belongs to no single file.

    A room record carries `room` and a thread record carries `peer`; the filename is the last
    resort, and for a room it is a slug that has lost the punctuation of the real title.
    """
    msgs, fresh = [], []
    for path in paths:
        # The window is the RAW tail past the cursor, and the direction test is applied inside
        # it. Sizing the window with the filtered count instead slides it off the far end as
        # soon as the tail holds one `sent` record, which silently marks a peer's message read
        # the moment this agent replies to it.
        tail = len(tail_at(path))
        records = store.load(path)
        msgs.extend(records)
        fresh.extend(i >= len(records) - tail and r.get("direction") != "sent"
                     for i, r in enumerate(records))
    if len(paths) > 1:
        order = sorted(range(len(msgs)), key=lambda i: msgs[i].get("at", ""))
        msgs = [msgs[i] for i in order]
        fresh = [fresh[i] for i in order]
    name = (msgs[-1].get("room") or msgs[-1].get("peer") or "") if msgs else ""
    return msgs, fresh, name or os.path.basename(paths[0])[: -len(".jsonl")]


def cmd_markdown(args):
    paths = resolve_path(args)
    if not paths:
        return 1
    seen = sizes_of(paths)
    msgs, _, name = read_paths(paths)
    if not msgs:
        sys.stderr.write(f"rooms: {','.join(paths)} holds no messages\n")
        return 1
    out_dir = opt(args, "--out-dir") or os.path.join(tempfile.gettempdir(), "agterm-rooms")
    # Named after the room file under its session, so re-opening one room rewrites its
    # document instead of leaving a new one behind on every read, and two sessions that named
    # a room the same way do not overwrite each other. A peer spans several files under
    # several session directories, so it is named after the peer under the first of them.
    out_dir = os.path.join(out_dir, os.path.basename(os.path.dirname(paths[0])))
    leaf = store.slug(name) if len(paths) > 1 else os.path.basename(paths[0])[: -len(".jsonl")]
    dest = os.path.join(out_dir, leaf + ".md")
    try:
        os.makedirs(out_dir, exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(markdown(msgs, name))
    except OSError as exc:
        sys.stderr.write(f"rooms: cannot write {dest}: {exc}\n")
        return 1
    if "--mark" in args:
        for path, offset in seen:
            store.advance_cursor_at(path, offset)
    print(dest)
    return 0


def opt(args, flag, default=None):
    if flag in args:
        try:
            return args[args.index(flag) + 1]
        except IndexError:
            return default
    return default


def my_sessions(args):
    """The Claude session ids this invocation is reading rooms for.

    An agterm row can hold more than one — the agent pane restarted, or a second agent in a
    split — so this is a list, and the rooms of all of them are listed together.
    """
    session = opt(args, "--session") or os.environ.get("XCHAT_SESSION", "")
    if session:
        if UUID_RE.match(session):
            return [session]
        found = store.id_for_name(session)
        if not found:
            sys.stderr.write(f"rooms: no Claude session named {session!r} is on record\n")
            return []
        return [found]
    row = opt(args, "--row") or os.environ.get("AGTERM_SESSION_ID", "")
    if not row:
        sys.stderr.write("rooms: no agterm session to read for. Pass --row ID or --session NAME.\n")
        return []
    return store.sessions_in_row(row)


def terminal_width(args):
    width = None
    given = opt(args, "--width")
    if given:
        try:
            width = int(given)
        except ValueError:
            width = None
    if not width or width < 20:
        # stdout is usually a pipe into less or an fzf preview, so ask the terminal itself.
        for src in (lambda: os.get_terminal_size(sys.stderr.fileno()).columns,
                    lambda: os.get_terminal_size().columns,
                    lambda: int(os.environ["COLUMNS"])):
            try:
                width = src()
            except (OSError, ValueError, KeyError):
                continue
            if width and width >= 20:
                break
    width = width or 100
    return min(width, MAX_MEASURE) if MAX_MEASURE > 0 else width


def badge(count, unread, at):
    parts = [f"{unread} new"] if unread else []
    parts.append(f"{count} msg")
    if at:
        parts.append(f"last {at[-8:]}")
    return ", ".join(parts)


def cmd_list(args):
    """Rooms and peer conversations in one list, newest first.

    Both kinds are normalized to (label, path field, count, unread, last timestamp) before
    they are sorted together. A peer group is several files, so its path field joins them and
    its unread is the sum across them.
    """
    sessions = my_sessions(args)
    rows = []
    for sid in sessions:
        rows.extend(store.rooms(sid))
    for peer, paths, count, at in store.conversations(sessions):
        rows.append((f"{PEER_LABEL}{peer}", ",".join(paths), count,
                     sum(unread_at(p) for p in paths), at))
    rows.sort(key=lambda r: r[4], reverse=True)
    for label, path, count, unread, at in rows:
        print(f"{label}\t{badge(count, unread, at)}\t{path}")
    return 0 if rows else 1


def cmd_show(args):
    paths = resolve_path(args)
    if not paths:
        return 1
    # Read the lengths before rendering, and mark each file to its own. A message appended
    # while the conversation sits open in the pager is not on the screen, so marking to the
    # current size would hide it for good.
    seen = sizes_of(paths)
    msgs, fresh, name = read_paths(paths)
    sys.stdout.write(render(msgs, name or "room", terminal_width(args),
                            "--no-color" not in args, fresh))
    if "--mark" in args:
        for path, offset in seen:
            store.advance_cursor_at(path, offset)
    return 0


def cmd_where(_args):
    """The roots a file watcher has to look at, one per line.

    Both kinds are listed together, so both roots are watched: a peer message lands under
    `threads/` and would otherwise never reload the list. The two are named rather than
    replaced by the store root above them, because that root also holds `msgs/`, which the
    watcher would then walk once a second. A name filter keeps those files out of `stat`,
    not out of the traversal.
    """
    print(store.rooms_dir())
    print(store.threads_dir())
    return 0


def main():
    args = sys.argv[1:]
    sub = args[0] if args else ""
    if sub == "list":
        return cmd_list(args)
    if sub == "show":
        return cmd_show(args)
    if sub == "markdown":
        return cmd_markdown(args)
    if sub == "where":
        return cmd_where(args)
    sys.stderr.write(__doc__.split("Usage:", 1)[-1].lstrip("\n"))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
