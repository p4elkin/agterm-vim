#!/usr/bin/env python3
"""Trial for the SessionStart restore hook.

`agtermctl` is a stub, so nothing reaches any socket, and AGTERM_STATE_DIR points at a short
throwaway path so even a real binary could not resolve the live terminal. The stub records
every call and serves the tree from a file the trial rewrites between cases; a `split on`
call swaps in the after-tree, which is what the poll for the new pane then reads.
"""

import json
import os
import subprocess
import sys
import tempfile

RECIPE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "..", "cookbook", "chat-rooms"))
SESSION = "11111111-2222-3333-4444-555555555555"
ROW = "sess-7"
VIEWER = os.path.join(RECIPE, "rooms-view.sh")

tmp = tempfile.mkdtemp(prefix="chat-rooms-restore-trial-")
STATE = tempfile.mkdtemp(prefix="agt-", dir="/tmp")
TREE = os.path.join(tmp, "tree.json")
AFTER = os.path.join(tmp, "tree-after.json")
CALLS = os.path.join(tmp, "calls.log")
STUB = os.path.join(tmp, "agtermctl")

os.environ["XCHAT_HOME"] = os.path.join(tmp, "state")
os.environ["XCHAT_SESSIONS_DIR"] = os.path.join(tmp, "sessions")
os.environ["AGTERM_STATE_DIR"] = STATE
os.environ["AGTERM_SESSION_ID"] = ROW
os.environ["AGTERM_PANE"] = "left"
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
os.environ.pop("XCHAT", None)
sys.path.insert(0, RECIPE)
sys.dont_write_bytecode = True

import xchat_store as store

with open(STUB, "w") as fh:
    fh.write(f"""#!/bin/sh
{{ printf 'argv:'; for a in "$@"; do printf ' %s' "$a"; done; printf '\\n--\\n'; }} >> '{CALLS}'
if [ "$1" = "tree" ]; then cat '{TREE}'; exit 0; fi
if [ "$2" = "split" ] && [ -f '{AFTER}' ]; then cp '{AFTER}' '{TREE}'; fi
exit 0
""")
os.chmod(STUB, 0o755)

HOOK = os.path.join(RECIPE, "rooms-restore-hook.py")


def write_tree(path, **fields):
    node = {"id": ROW, "name": "agent", "cwd": "/tmp", "active": True, "realized": True,
            "overlay": False, "scratch": False}
    node.update(fields)
    pending = node.pop("pickPending", None)
    tree = {"workspaces": [{"name": "work", "sessions": [node]}]}
    if pending:
        tree["pickPending"] = pending
    with open(path, "w") as fh:
        json.dump({"ok": True, "result": {"tree": tree}}, fh)


def fire(event="SessionStart", **env):
    if os.path.exists(CALLS):
        os.remove(CALLS)
    payload = json.dumps({"hook_event_name": event, "session_id": SESSION, "source": "startup"})
    return subprocess.run([sys.executable, HOOK], input=payload, capture_output=True, text=True,
                          env={**os.environ, "AGTERMCTL": STUB, **env}, check=False)


def calls():
    """One entry per agtermctl call, newlines inside an argument flattened.

    The viewer line the hook types ends in a newline, so a record cannot be one log line.
    """
    if not os.path.exists(CALLS):
        return []
    with open(CALLS) as fh:
        blocks = [b for b in fh.read().split("\n--\n") if b.strip()]
    return [" ".join(b[len("argv: "):].split()) for b in blocks]


def typing():
    return [c for c in calls() if c.startswith("session type")]


def splits():
    return [c for c in calls() if c.startswith("session split")]


VIEWER_ARGV = ["/bin/sh", VIEWER, ROW]
FZF_ARGV = ["fzf", "--ansi", "--listen",
            "--bind", f"ctrl-o:execute('{VIEWER}' --full-read {{3}})+reload(...)"]

# The pane is absent: the hook opens a split, types the viewer into it and hands focus back.
write_tree(TREE)
write_tree(AFTER, hasSplit=True, split=True)
out = fire()
assert out.returncode == 0, (out.returncode, out.stderr)
assert splits() == [f"session split on --target {ROW}"], calls()
assert len(typing()) == 1, calls()
line = typing()[0]
assert VIEWER in line and f"--target {ROW}" in line and "--pane right" in line, line
assert "--socket" not in line, line
assert f"session focus primary --target {ROW}" in calls(), calls()

# Pairing is what lets the viewer resolve this row's rooms at all.
assert store.sessions_in_row(ROW) == [SESSION], store.sessions_in_row(ROW)

# The pane already holds the viewer: nothing is opened twice, in either phase of its life.
for label, argv in [("shell phase", VIEWER_ARGV), ("fzf phase", FZF_ARGV)]:
    os.remove(AFTER)
    write_tree(TREE, hasSplit=True, split=True, splitForeground=argv)
    out = fire()
    assert out.returncode == 0, (label, out.stderr)
    assert not typing(), (label, calls())
    assert not splits(), (label, calls())
    write_tree(AFTER, hasSplit=True, split=True)

# A split at a shell prompt is typed into without opening a second one.
os.remove(AFTER)
write_tree(TREE, hasSplit=True, split=True)
out = fire()
assert len(typing()) == 1, calls()
assert not splits(), calls()

# A hidden split at a prompt is shown first, so the viewer is not typed into an invisible pane.
write_tree(TREE, hasSplit=True, split=False)
out = fire()
assert splits() == [f"session split on --target {ROW}"], calls()
assert len(typing()) == 1, calls()

# A split running something else belongs to whoever started it.
write_tree(TREE, hasSplit=True, split=True, splitForeground=["vim", "notes.md"])
out = fire()
assert not typing(), calls()
assert not splits(), calls()

# Nothing that covers the pane may be typed through, because these are real keystrokes.
for label, fields in [("session overlay", {"overlay": True}),
                      ("pane overlay", {"paneOverlays": ["right"]}),
                      ("scratch", {"scratch": True}),
                      ("unrealized", {"realized": False}),
                      ("picker", {"pickPending": "pick-1"})]:
    write_tree(TREE, **fields)
    out = fire()
    assert out.returncode == 0, (label, out.stderr)
    assert not typing(), (label, calls())
    assert not splits(), (label, calls())

# Wrong row, off switch, other events and a broken tree all pass without touching anything.
write_tree(TREE)
out = fire(AGTERM_SESSION_ID="sess-nowhere")
assert out.returncode == 0 and not typing(), (out.stderr, calls())

out = fire(XCHAT="off")
assert out.returncode == 0 and not calls(), calls()

out = fire(event="PreToolUse")
assert out.returncode == 0 and not calls(), calls()

with open(TREE, "w") as fh:
    fh.write("not json at all")
out = fire()
assert out.returncode == 0 and not typing(), (out.stderr, calls())

# Outside agterm there is no pane to open, and the hook still exits clean.
os.remove(CALLS)
env = dict(os.environ)
env.pop("AGTERM_SESSION_ID")
out = subprocess.run([sys.executable, HOOK], input='{"hook_event_name": "SessionStart"}',
                     capture_output=True, text=True,
                     env=dict(env, AGTERMCTL=STUB), check=False)
assert out.returncode == 0 and not calls(), (out.stderr, calls())

# No agtermctl at all: the hook logs and gives up rather than raising into the session start.
write_tree(TREE)
out = fire(AGTERMCTL=os.path.join(tmp, "no-such-agtermctl"))
assert out.returncode == 0, (out.returncode, out.stderr)

print("trial-rooms-restore: ok")
