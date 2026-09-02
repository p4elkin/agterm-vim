#!/usr/bin/env python3
"""Write one answer into one chat room, and print the line the main thread keeps.

Called once per room by the agent that wrote the answer, as the answer is written:

    rooms-write.py "overlay PATH trap" --summary "why the plain revdiff wins" <<'EOF'
    ...the answer...
    EOF

The body is appended to the room and written out in full to msgs/<msg-id>.md, the same id
shape and the same directory the cross-agent messages use, so both kinds of message read
back through one viewer.

What comes back on stdout is a single line naming the room, the id and the summary. That
line is what belongs in the chat reply. The answer itself already passed through the
transcript once on its way here, so putting it in the reply as well would say it twice.

The room is keyed on the Claude session id, never on the session name, because Claude Code
rewrites a session's name as the work in it changes. The id is resolved from the process
tree: this script runs as a child of the Claude process that is writing the answer, so the
first ancestor pid the session registry knows is that session. Writing also records which
agterm row the session runs in, which is the only join the viewer in the other pane has.

Switches
--------
  --session <id>       skip the process-tree lookup and write to this session's rooms
  XCHAT_SESSION=<id>   the same, from the environment
  --from <name>        who wrote it; this session's name by default
  --mark               count it read, which the typing path wants for your own reply
  --paths              print the body's path on a second line, after the pointer
  XCHAT_HOME=<dir>     where the record is kept
"""

import argparse
import os
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xchat_store as store

SUMMARY_MAX = 200


def ancestors(pid, limit=12):
    """This process and its parents, innermost first.

    `ps` rather than /proc, which macOS does not have. The walk stops at init, at a repeated
    pid, or at `limit`, so a broken parent chain cannot spin here.
    """
    chain = []
    seen = set()
    while pid and pid > 1 and pid not in seen and len(chain) < limit:
        chain.append(pid)
        seen.add(pid)
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], check=False,
                                 capture_output=True, text=True, timeout=5)
            pid = int((out.stdout or "").strip() or 0)
        except (OSError, ValueError, subprocess.SubprocessError):
            break
    return chain


def owning_session(explicit=""):
    """The Claude session whose rooms this answer belongs in, or "".

    An ancestor pid is the exact answer and is tried first. The newest live session is the
    fallback for the case where the script is run from a shell the agent spawned deeper than
    the walk reaches; it is right whenever only one agent is running, which is the common
    case, and `--session` is there for when it is not.
    """
    if explicit:
        return explicit
    if os.environ.get("XCHAT_SESSION"):
        return os.environ["XCHAT_SESSION"]
    entries = [e for e in store.registry() if store.alive(e.get("pid") or -1)]
    mine = set(ancestors(os.getpid()))
    for entry in entries:
        try:
            if int(entry.get("pid") or -1) in mine:
                return entry.get("sessionId")
        except (TypeError, ValueError):
            continue
    return entries[0].get("sessionId") if entries else ""


def first_line(body):
    for line in (body or "").splitlines():
        if line.strip():
            return line.strip()[:SUMMARY_MAX]
    return ""


def spool(mid, room, session_name, summary, body):
    """Write the answer out in full. Returns its path, or None if it could not be written."""
    path = os.path.join(store.msgs_dir(), mid + ".md")
    try:
        os.makedirs(store.msgs_dir(), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(
                f"# {mid}\n\n"
                f"- room: {room}\n"
                f"- from: {session_name}\n"
                f"- written: {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"- summary: {summary}\n\n"
                f"---\n\n{body}\n"
            )
    except OSError as exc:
        store.log(f"room body write failed: {exc}")
        return None
    return path


def pointer(room, mid, unread, summary):
    """The one line the main thread keeps for this room."""
    plural = "" if unread == 1 else "s"
    return f'room "{room}" ({mid}, {unread} unread message{plural}): {summary}'


def write_room(room, body, summary="", session="", sender="", mark=False):
    """Append one answer to one room. Returns (pointer line, message path), or (None, None).

    `sender` names the author when it is not this session — the typing path writes your own
    reply into the room the same way. `mark` moves the room's cursor over what was just
    written, which is what that path wants: the author has already read their own message.
    """
    room = (room or "").strip()
    if not room or not (body or "").strip():
        store.log("refusing an answer with no room or no body")
        return None, None

    claude_session = owning_session(session)
    if not claude_session:
        store.log("no Claude session id resolved; not writing")
        return None, None

    # Written on every answer rather than at session start, so the viewer in the other pane
    # can find a session that was already running when the recipe was installed.
    store.pair(os.environ.get("AGTERM_SESSION_ID", ""), claude_session,
               os.environ.get("AGTERM_PANE", ""))

    summary = (summary or "").strip() or first_line(body)
    session_name = (sender or "").strip() or store.name_for_id(claude_session, claude_session)
    mid = f"msg-{time.strftime('%H%M%S')}-{uuid.uuid4().hex[:4]}"

    path = spool(mid, room, session_name, summary, body)
    if not path:
        return None, None

    record = {"id": mid, "at": time.strftime("%Y-%m-%d %H:%M:%S"), "room": room,
              "from": session_name, "summary": summary, "body": body, "path": path}
    if not store.append_room(claude_session, room, record):
        return None, None
    if mark:
        store.advance_cursor(claude_session, room)

    return pointer(room, mid, store.room_unread(claude_session, room), summary), path


def main():
    ap = argparse.ArgumentParser(description="write one answer into one chat room")
    ap.add_argument("room", help="the room's title, as it should read in the viewer")
    ap.add_argument("--summary", default="", help="the line the chat keeps; body's first line by default")
    ap.add_argument("--body", default=None, help="the answer itself; read from stdin when absent")
    ap.add_argument("--body-file", default=None, help="read the answer from this file instead")
    ap.add_argument("--session", default="", help="write to this Claude session's rooms")
    ap.add_argument("--from", dest="sender", default="", help="who wrote it; this session by default")
    ap.add_argument("--mark", action="store_true", help="count it read, for an author reading their own")
    ap.add_argument("--paths", action="store_true", help="print the body's path on a second line")
    args = ap.parse_args()

    if args.body is not None:
        body = args.body
    elif args.body_file and args.body_file != "-":
        with open(args.body_file) as fh:
            body = fh.read()
    else:
        body = sys.stdin.read()

    line, path = write_room(args.room, body, args.summary, args.session, args.sender, args.mark)
    if not line:
        print("could not write the room; the answer belongs in the reply", file=sys.stderr)
        return 1
    print(line)
    if args.paths:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
