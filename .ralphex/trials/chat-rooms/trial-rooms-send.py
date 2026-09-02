#!/usr/bin/env python3
"""Trial for the inbound typing path.

`agtermctl` is a stub here, so nothing reaches any socket, and AGTERM_STATE_DIR points at a
short throwaway path so even a real binary could not resolve the live terminal. The stub
records what it was asked to type, which is what the "only the pointer goes on the wire"
assertions read.
"""

import json
import os
import subprocess
import sys
import tempfile

RECIPE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "..", "cookbook", "chat-rooms"))
SESSION = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
ROW = "sess-42"

tmp = tempfile.mkdtemp(prefix="chat-rooms-send-trial-")
STATE = tempfile.mkdtemp(prefix="agt-", dir="/tmp")
TREE_FILE = os.path.join(tmp, "tree.json")
TYPED = os.path.join(tmp, "typed.log")
STUB = os.path.join(tmp, "agtermctl")

os.environ["XCHAT_HOME"] = os.path.join(tmp, "state")
os.environ["XCHAT_SESSIONS_DIR"] = os.path.join(tmp, "sessions")
os.environ["XCHAT_SESSION"] = SESSION
# Pin the sender rather than letting $USER through, or this asserts whatever the machine
# running it is called. The point of the default is that it is NOT a fixed name.
SENDER = "trial-user"
os.environ["XCHAT_SENDER"] = SENDER
os.environ["AGTERM_STATE_DIR"] = STATE
os.environ.pop("AGTERM_SESSION_ID", None)
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, RECIPE)
sys.dont_write_bytecode = True

import xchat_store as store

with open(STUB, "w") as fh:
    fh.write(f"""#!/bin/sh
if [ "$1" = "tree" ]; then cat '{TREE_FILE}'; exit 0; fi
{{ printf 'argv:'; for a in "$@"; do printf ' %s' "$a"; done
  printf '\\nstate:%s\\nbody:' "${{AGTERM_STATE_DIR:-unset}}"; cat; printf '\\n--\\n'
}} >> '{TYPED}'
""")
os.chmod(STUB, 0o755)

SEND = os.path.join(RECIPE, "rooms-send.sh")
ROOM = "почему PATH ломается ⚠️ in an overlay"
LONG = ("the app PATH has no /opt/homebrew/bin\n"
        "so fzf and revdiff both read as missing\n"
        "and the fix is one export at the top of the script\n")


def set_tree(**session_fields):
    # `foreground` non-empty means some job owns the pane's terminal, not that it is an agent.
    # It is nil at a bare shell prompt, where a typed reply would run as a command, so the
    # default here is the running case and the empty one is a refusal case below.
    node = {"id": ROW, "name": "agent", "cwd": "/tmp", "active": True, "split": True,
            "overlay": False, "scratch": False, "flagged": False, "realized": True,
            "foreground": ["claude"]}
    node.update(session_fields)
    pending = node.pop("pickPending", None)
    tree = {"workspaces": [{"name": "work", "sessions": [node]}]}
    if pending:
        tree["pickPending"] = pending
    with open(TREE_FILE, "w") as fh:
        json.dump({"ok": True, "result": {"tree": tree}}, fh)


def send(text, room_file=None, room=None):
    cmd = [SEND, "--text", text, "--target", ROW]
    cmd += ["--room-file", room_file] if room_file else ["--room", room or ROOM,
                                                         "--session", SESSION]
    env = dict(os.environ, AGTERMCTL=STUB, PYTHON=sys.executable)
    return subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)


def typed():
    if not os.path.exists(TYPED):
        return []
    with open(TYPED) as fh:
        return [b for b in fh.read().split("\n--\n") if b.strip()]


def room_lines():
    path = store.room_path(SESSION, ROOM)
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


# Every refusal case comes first, so a stray write from one of them would still be visible as
# an extra room line in the assertions below it.
for label, fields in [("session overlay", {"overlay": True}),
                      ("pane overlay", {"paneOverlays": ["left"]}),
                      ("scratch", {"scratch": True}),
                      ("unrealized", {"realized": False}),
                      ("picker", {"pickPending": "pick-1"}),
                      # A bare prompt is the case where the reply becomes a command: the text
                      # is sent with a trailing newline, so backticks in an ordinary sentence
                      # run before the line even fails to parse.
                      ("shell prompt", {"foreground": []})]:
    set_tree(**fields)
    out = send("this must not be typed")
    assert out.returncode == 3, (label, out.returncode, out.stderr)
    assert "not typing" in out.stderr, (label, out.stderr)
    assert not typed(), (label, typed())
    assert not room_lines(), (label, room_lines())

set_tree()
out = send("this session is not in the tree at all", room=ROOM)
os.environ["AGTERM_SESSION_ID"] = "sess-nowhere"
missing = subprocess.run([SEND, "--text", "x", "--room", ROOM, "--session", SESSION],
                         capture_output=True, text=True,
                         env=dict(os.environ, AGTERMCTL=STUB, PYTHON=sys.executable),
                         check=False)
os.environ.pop("AGTERM_SESSION_ID")
assert missing.returncode == 3, (missing.returncode, missing.stderr)
assert "no session sess-nowhere" in missing.stderr, missing.stderr

# The clear tree: the room takes the whole text, the wire takes one line.
assert out.returncode == 0, (out.returncode, out.stderr)
lines = room_lines()
assert len(lines) == 1, lines
assert lines[0]["body"] == "this session is not in the tree at all", lines[0]
assert lines[0]["from"] == SENDER, lines[0]
body_path = lines[0]["path"]
with open(body_path) as fh:
    assert "this session is not in the tree at all" in fh.read(), body_path
# Your own reply is already read, so it must not come back as an unread badge.
assert store.room_unread(SESSION, ROOM) == 0, store.rooms(SESSION)

wire = typed()
assert len(wire) == 1, wire
argv, state, body = wire[0].split("\n", 2)
assert "session type" in argv and "--stdin" in argv, argv
assert f"--target {ROW}" in argv and "--pane left" in argv, argv
assert state == f"state:{STATE}", state
assert "--socket" not in argv, argv
assert body.count("\n") == 1, body
assert body.startswith("body:[room] ") and f'"{ROOM}"' in body, body
assert body_path in body, (body, body_path)

# A multi-line reply keeps every line in the room and still puts one line on the wire.
set_tree()
out = send(LONG, room_file=store.room_path(SESSION, ROOM))
assert out.returncode == 0, out.stderr
lines = room_lines()
assert len(lines) == 2, lines
assert lines[1]["body"] == LONG, lines[1]
assert lines[1]["room"] == ROOM, lines[1]
assert lines[1]["summary"] == "the app PATH has no /opt/homebrew/bin", lines[1]
wire = typed()[1]
argv, state, body = wire.split("\n", 2)
assert body.count("\n") == 1, body
assert "so fzf and revdiff" not in body, body
assert lines[1]["path"] in body, body

# An empty reply is a cancel: nothing typed, nothing written.
set_tree()
out = send("")
assert out.returncode == 0, (out.returncode, out.stderr)
assert len(typed()) == 2, typed()
assert len(room_lines()) == 2, room_lines()

print(f"trial-rooms-send: ok ({tmp})")
