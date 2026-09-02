#!/usr/bin/env python3
"""Where cross-agent messages are kept, and how a session is identified.

Imported by the hook that writes messages and by the reader that prints them. It is a
module, not a command: nothing here is meant to be run.

Layout, under XCHAT_HOME (default ~/.local/state/agterm-xchat):

    msgs/<msg-id>.md                                  one file per message, in full
    threads/<my-session>/<peer-session>.jsonl         one thread per peer I talk to
    panes/<agterm-session>/<claude-session>.json      which agent runs in which row
    hook.log                                          the hook's own breadcrumbs

A session is identified by its Claude session id, never by its name. Claude Code renames a
session as the work in it changes, so a thread keyed on the name splits in two the moment it
does. The name travels inside each message, for display only.

One thread per PEER, not one log per session. A session can be talking to several agents at
once, and a single merged log makes those unreadable: you cannot follow one exchange without
reading all of them interleaved. Each side keeps its own copy, so each reads its own view.

Messages are stored structured, never pre-formatted. The width the text should wrap to is a
property of the window it is read in, which the sender cannot know, so rendering happens at
view time.
"""

import hashlib
import json
import os
import re
import time

HOME = os.path.expanduser("~")

# Claude Code's own registry of running sessions: one <pid>.json per session, holding the
# session id, the name `SendMessage` addresses it by, and the pid. This is the same file set
# `ListAgents` reads, which is what makes a name resolvable here without any private tool.
SESSIONS_DIR = os.environ.get("XCHAT_SESSIONS_DIR") or os.path.join(HOME, ".claude", "sessions")

# A ` [ref]` suffix on a SendMessage recipient is addressing, not part of the name.
REF_SUFFIX = re.compile(r"\s*\[[^\]]+\]\s*$")


def home():
    return os.environ.get("XCHAT_HOME") or os.path.join(HOME, ".local", "state", "agterm-xchat")


def msgs_dir():
    return os.path.join(home(), "msgs")


def threads_dir():
    return os.path.join(home(), "threads")


def panes_dir():
    return os.path.join(home(), "panes")


def log(msg):
    """Best-effort breadcrumb. A failure here must never propagate."""
    try:
        os.makedirs(home(), exist_ok=True)
        with open(os.path.join(home(), "hook.log"), "a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def slug(name):
    """A filename for a session name, used only where no session id is available.

    Session names carry whatever the agent called itself, which in practice includes spaces,
    Cyrillic and status glyphs. An ASCII-only sanitizer turns those into a row of dashes, so
    keep unicode word characters and fall back to a hash when nothing usable survives.
    """
    s = re.sub(r"[^\w.-]", "-", (name or "").strip(), flags=re.UNICODE)
    s = re.sub(r"-{2,}", "-", s).strip("-.")
    if not s or not re.search(r"\w", s, flags=re.UNICODE):
        s = "sess-" + hashlib.md5((name or "unknown").encode("utf-8")).hexdigest()[:8]
    return s[:80]


def alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # it exists, it is just not ours to signal
    except (TypeError, ValueError):
        return False
    return True


def registry():
    """Every session Claude Code has recorded, newest first.

    A <pid>.json is never removed when the process dies, so this list holds long-dead
    sessions as well as live ones. Callers that need a live one check `alive`.
    """
    out = []
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS_DIR, fn)) as fh:
                entry = json.load(fh)
        except (OSError, ValueError):   # a half-written entry is skipped, not fatal
            continue
        if isinstance(entry, dict) and entry.get("sessionId"):
            out.append(entry)
    out.sort(key=lambda e: e.get("updatedAt") or 0, reverse=True)
    return out


def id_for_name(name):
    """The session id `SendMessage` would reach for this name, or None.

    A live entry wins over a dead one, and the newest wins within each group, because a pid
    file outlives its process and pids get reused.
    """
    wanted = REF_SUFFIX.sub("", (name or "").strip())
    if not wanted:
        return None
    hits = [e for e in registry() if e.get("name") == wanted]
    for entry in hits:
        if alive(entry.get("pid") or -1):
            return entry.get("sessionId")
    return hits[0].get("sessionId") if hits else None


def name_for_id(session_id, default=""):
    for entry in registry():
        if entry.get("sessionId") == session_id:
            return entry.get("name") or default
    return default


def pair(agterm_session, claude_session, pane=""):
    """Record that this Claude session runs in this agterm row.

    One file per pairing rather than one file per row: two Claude sessions in the two halves
    of a split share the row, and each writes only its own file, so no lock is needed.
    """
    if not agterm_session or not claude_session:
        return None
    path = os.path.join(panes_dir(), agterm_session, claude_session + ".json")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"claudeSession": claude_session, "pane": pane,
                       "at": time.strftime("%Y-%m-%d %H:%M:%S")}, fh)
    except OSError as exc:
        log(f"pairing write failed: {exc}")
        return None
    return path


def sessions_in_row(agterm_session):
    """Claude session ids ever paired to this agterm row, newest pairing first.

    Dead ones are kept. Restarting the agent in a tab gives it a new session id, and dropping
    the old one would take yesterday's conversation off the screen with it.
    """
    mydir = os.path.join(panes_dir(), agterm_session or "")
    rows = []
    try:
        names = os.listdir(mydir)
    except OSError:
        return rows
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            rows.append((os.path.getmtime(os.path.join(mydir, fn)), fn[:-5]))
        except OSError:
            continue
    rows.sort(reverse=True)
    return [sid for _, sid in rows]


def thread_path(me, peer_id, peer_name=""):
    """The thread file for one side of one conversation.

    `peer_id` is the peer's Claude session id when it could be resolved. When it could not,
    the peer's name is the only key left, and a name-keyed file beats a lost message.
    """
    leaf = peer_id or ("name-" + slug(peer_name))
    return os.path.join(threads_dir(), me, leaf + ".jsonl")


def append(me, peer_id, record, peer_name=""):
    """Add one message to my thread with this peer. Never raises."""
    if not me:
        return None
    path = thread_path(me, peer_id, peer_name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError as exc:
        log(f"thread append failed: {exc}")
        return None
    return path


def load(path):
    """Every message in a thread file, skipping any line that got truncated."""
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    out.append(json.loads(stripped))
                except ValueError:      # a torn last line loses one message, not the thread
                    continue
    except OSError:                     # an unreadable thread reads as an empty one
        pass
    return out


def conversations(my_sessions):
    """[(peer name, [thread paths], message count, last timestamp)], newest first.

    Grouped by the peer's NAME across every one of my own session ids, so restarting the
    agent in this tab continues the conversation on screen instead of opening a second row
    beside it.
    """
    groups = {}
    for me in my_sessions:
        mydir = os.path.join(threads_dir(), me)
        try:
            names = os.listdir(mydir)
        except OSError:                 # a session id with no threads yet has no directory
            continue
        for fn in names:
            if not fn.endswith(".jsonl"):
                continue
            path = os.path.join(mydir, fn)
            msgs = load(path)
            if not msgs:
                continue
            peer = msgs[-1].get("peer") or fn[:-6]
            paths, count, last = groups.get(peer, ([], 0, ""))
            groups[peer] = (paths + [path], count + len(msgs),
                            max(last, msgs[-1].get("at", "")))
    rows = [(peer, paths, count, last) for peer, (paths, count, last) in groups.items()]
    rows.sort(key=lambda r: r[3], reverse=True)
    return rows


def merged(paths):
    """Every message across these thread files, oldest first."""
    msgs = []
    for path in paths:
        msgs.extend(load(path))
    msgs.sort(key=lambda m: m.get("at", ""))
    return msgs
