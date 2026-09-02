#!/usr/bin/env python3
"""Read the cross-agent record: list this row's conversations, or print one of them.

Messages are stored structured, so the wrapping width is decided here, against the window
the text is actually being read in, rather than baked in when it was sent.

What it does to a message body, and why:

- Wraps prose to the real window width. A 900-character paragraph as one line that scrolls
  sideways was the worst thing about reading these.
- Renders the markdown agents actually write instead of showing its punctuation. `**bold**`
  becomes bold, `code` becomes coloured, headings become bold, and fence markers disappear
  while the code inside them keeps its shape.
- Leaves fenced code, indented code and table rows unwrapped. Wrapping those destroys them.
- Keeps bullets and numbered items on their own lines, with continuation indented under the
  text rather than under the marker.
- Marks each message with who sent it and which way it went, so a thread reads as a
  conversation rather than a pile of entries.

Wrapping is ANSI-aware: markup is applied before wrapping, and the wrapper measures visible
width only, so a bolded word does not make its line wrap short.

Usage:
  xchat-read.py list [--row ID | --session NAME]          peer <TAB> count <TAB> last-seen
  xchat-read.py show [--peer NAME] [--width N] [--no-color] [--row ID | --session NAME]
  xchat-read.py who  [--row ID | --session NAME]

--row is an agterm session id and defaults to $AGTERM_SESSION_ID. --session names a Claude
session instead, for a shell that is not inside agterm.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xchat_store as store

BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BLUE = "\033[34m"

ANSI_RE = re.compile(r"\033\[[0-9;]*m")
FENCE = re.compile(r"^\s*(```|~~~)")
BULLET = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
PREFORMATTED = re.compile(r"^(\s{4,}|\t)")
TABLE = re.compile(r"^\s*\|")
HEADING = re.compile(r"^\s*(#{1,6})\s+(.*)$")
UUID_RE = re.compile(r"^[0-9a-f-]{32,40}$", re.IGNORECASE)

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


def render(msgs, peer, width, color=True):
    if not msgs:
        return "No messages in this conversation yet.\n"

    def c(code, s):
        return (code + s + RESET) if color else s

    body_width = max(30, width - 2)
    plural = "" if len(msgs) == 1 else "s"
    lines = [f"{c(BOLD, 'Conversation with ' + peer)}   {c(DIM, f'{len(msgs)} message{plural}')}"]

    for m in msgs:
        sent = m.get("direction") == "sent"
        who = "you" if sent else m.get("peer", "peer")
        pri = m.get("priority", "normal")
        pri_col = {"urgent": RED, "fyi": DIM}.get(pri, GREEN)
        summary = (m.get("summary") or "").strip()

        lines.append("")
        lines.append(" ".join([
            c(DIM, m.get("at", "")[-8:]),
            c(BOLD + (BLUE if sent else YELLOW), who),
            c(pri_col, f"[{pri}]"),
            c(DIM, m.get("id", "")),
            c("" if sent else CYAN, summary)]))
        lines.extend(wrap_body(m.get("body", ""), body_width, color))
        lines.append(c(DIM, "─" * width))

    return "\n".join(lines) + "\n"


def opt(args, flag, default=None):
    if flag in args:
        try:
            return args[args.index(flag) + 1]
        except IndexError:
            return default
    return default


def my_sessions(args):
    """The Claude session ids this invocation is reading for.

    An agterm row can hold more than one — two panes of a split each running an agent, or the
    same pane restarted — so this is a list, and the conversations of all of them are shown
    together.
    """
    session = opt(args, "--session")
    if session:
        if UUID_RE.match(session):
            return [session]
        found = store.id_for_name(session)
        if not found:
            sys.stderr.write(f"xchat: no Claude session named {session!r} is on record\n")
            return []
        return [found]
    row = opt(args, "--row") or os.environ.get("AGTERM_SESSION_ID", "")
    if not row:
        sys.stderr.write("xchat: no agterm session to read for. Pass --row ID or --session NAME.\n")
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
        # stdout is usually a pipe into less, so ask the terminal itself.
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


def cmd_list(args):
    rows = store.conversations(my_sessions(args))
    for peer, _paths, count, at in rows:
        print(f"{peer}\t{count}\t{at}")
    return 0 if rows else 1


def cmd_show(args):
    rows = store.conversations(my_sessions(args))
    if not rows:
        sys.stderr.write("xchat: no conversations on record for this session\n")
        return 1
    peer = opt(args, "--peer")
    if peer:
        picked = [r for r in rows if r[0] == peer] or [r for r in rows if r[0].startswith(peer)]
        if not picked:
            sys.stderr.write(f"xchat: no conversation with a peer named {peer!r}\n")
            return 1
    elif len(rows) > 1:
        sys.stderr.write(f"xchat: {len(rows)} conversations. Name one with --peer:\n")
        for name, _paths, count, _at in rows:
            sys.stderr.write(f"  {name:<44} {count:>4} msg\n")
        return 1
    else:
        picked = rows
    name, paths, _count, _at = picked[0]
    sys.stdout.write(render(store.merged(paths), name, terminal_width(args),
                            "--no-color" not in args))
    return 0


def cmd_who(args):
    sessions = my_sessions(args)
    if not sessions:
        return 1
    row = opt(args, "--row") or os.environ.get("AGTERM_SESSION_ID", "-")
    print(f"agterm session: {row}")
    for sid in sessions:
        print(f"claude session: {sid}  {store.name_for_id(sid, '(no longer running)')}")
        print(f"threads:        {os.path.join(store.threads_dir(), sid)}")
    return 0


def main():
    args = sys.argv[1:]
    sub = args[0] if args else ""
    if sub == "list":
        return cmd_list(args)
    if sub == "show":
        return cmd_show(args)
    if sub == "who":
        return cmd_who(args)
    sys.stderr.write(__doc__.split("Usage:", 1)[-1].lstrip("\n"))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
