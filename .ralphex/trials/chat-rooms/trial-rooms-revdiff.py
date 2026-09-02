#!/usr/bin/env python3
"""Trial for the full-read key.

revdiff is a stub here, so nothing opens a terminal UI, and the stub records the argv it was
given. That log is what the "the key resolved the right room file" assertions read. The room
titles carry spaces on purpose: the field the key passes is a tab field, and re-splitting a
listing row on whitespace would hand revdiff the second WORD of a title.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

RECIPE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "..", "cookbook", "chat-rooms"))
SESSION = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

tmp = tempfile.mkdtemp(prefix="chat-rooms-revdiff-trial-")
os.environ["XCHAT_HOME"] = os.path.join(tmp, "state")
os.environ["XCHAT_SESSIONS_DIR"] = os.path.join(tmp, "sessions")
os.environ["XCHAT_SESSION"] = SESSION
os.environ.pop("AGTERM_SESSION_ID", None)
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, RECIPE)
sys.dont_write_bytecode = True

import xchat_store as store

spec = importlib.util.spec_from_file_location("rooms_write",
                                              os.path.join(RECIPE, "rooms-write.py"))
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)

VIEW = os.path.join(RECIPE, "rooms-view.sh")
READER = os.path.join(RECIPE, "rooms-read.py")
ROOM = "почему PATH ломается ⚠️ in an overlay"
OTHER = "the second room in this row"
LOG = os.path.join(tmp, "revdiff.log")


def stub(name, preview):
    """A fake revdiff. `preview` decides whether its --help advertises markdown preview."""
    path = os.path.join(tmp, name)
    with open(path, "w") as fh:
        fh.write("#!/bin/sh\n"
                 f"if [ \"$1\" = '--help' ]; then printf '%s\\n' '{'--preview' if preview else '--compact'}'; exit 0; fi\n"
                 "{ printf 'argv:'; for a in \"$@\"; do printf ' %s' \"$a\"; done; printf '\\n--\\n'; }"
                 f" >> '{LOG}'\n")
    os.chmod(path, 0o755)
    return path


def full_read(room_file, revdiff):
    return subprocess.run([VIEW, "--full-read", room_file], capture_output=True, text=True,
                          env=dict(os.environ, REVDIFF=revdiff, PYTHON=sys.executable),
                          check=False)


def calls():
    if not os.path.exists(LOG):
        return []
    with open(LOG) as fh:
        return [c.strip() for c in fh.read().split("\n--\n") if c.strip()]


def only_path(call):
    for word in call.split(" "):
        if word.startswith("--only="):
            return word[len("--only="):]
    return ""


writer.write_room(ROOM, "the app PATH has no /opt/homebrew/bin\n\n| flag | meaning |\n|---|---|\n| -F | only |\n",
                  "why fzf reads as missing")
writer.write_room(ROOM, "```mermaid\nflowchart LR\n  a --> b\n```", "the shape of it")
writer.write_room(OTHER, "a different conversation entirely", "not this one")

PATCHED = stub("revdiff-patched", preview=True)
PLAIN = stub("revdiff-plain", preview=False)
ROOM_FILE = store.room_path(SESSION, ROOM)

# The patched build: the room opens as markdown, in preview mode, and the document holds this
# room and not the other one.
out = full_read(ROOM_FILE, PATCHED)
assert out.returncode == 0, (out.returncode, out.stderr)
assert len(calls()) == 1, calls()
call = calls()[0]
assert "--preview" in call, call
md = only_path(call)
assert md.endswith(".md"), call
assert os.path.basename(md)[:-3] == os.path.basename(ROOM_FILE)[:-len(".jsonl")], (md, ROOM_FILE)
# Under the session, so two sessions with a room of the same name do not share one document.
assert os.path.basename(os.path.dirname(md)) == SESSION, md
with open(md) as fh:
    doc = fh.read()
assert doc.startswith(f"# {ROOM}\n"), doc[:200]
assert "```mermaid" in doc and "| -F | only |" in doc, doc
assert "a different conversation entirely" not in doc, doc
assert "why fzf reads as missing" in doc, doc

# Reading it that way is a read: the badge clears, exactly as the pager path clears it.
assert store.room_unread(SESSION, ROOM) == 0, store.rooms(SESSION)
assert store.room_unread(SESSION, OTHER) == 1, store.rooms(SESSION)

# The other room resolves to its own file, so the key is not carrying one path everywhere.
out = full_read(store.room_path(SESSION, OTHER), PATCHED)
assert out.returncode == 0, out.stderr
second = only_path(calls()[1])
assert second != md, (second, md)
with open(second) as fh:
    assert "a different conversation entirely" in fh.read(), second

# The unpatched Homebrew build still opens the room, and says why it will look like source.
out = full_read(ROOM_FILE, PLAIN)
assert out.returncode == 0, out.stderr
assert "--preview" not in calls()[2], calls()[2]
assert "no markdown preview mode" in out.stderr, out.stderr
assert "~/.local/bin" in out.stderr, out.stderr

# No revdiff at all falls back to the pager rather than losing the read.
out = full_read(ROOM_FILE, os.path.join(tmp, "revdiff-absent"))
assert out.returncode == 0, (out.returncode, out.stderr)
assert len(calls()) == 3, calls()
assert "why fzf reads as missing" in out.stdout, out.stdout

# A room file that is not there is a no-op, not a crash mid-viewer.
out = full_read(os.path.join(tmp, "gone.jsonl"), PATCHED)
assert out.returncode == 0, (out.returncode, out.stderr)
assert len(calls()) == 3, calls()

# The binding itself: the room file comes off tab field 3, never off a word of the title, and
# it re-enters this same script. The PATH export has to keep ~/.local/bin ahead of Homebrew,
# because that is which of the two revdiffs wins when the key runs for real.
with open(VIEW) as fh:
    view = fh.read()
bind = [ln for ln in view.splitlines() if "ctrl-o:" in ln]
assert len(bind) == 1, bind
assert "--full-read {3}" in bind[0], bind[0]
assert "$SELF" in bind[0], bind[0]
assert 'PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"' in view, "PATH order"
assert "annotate-extract.py:179" in view, "the reason revdiff is the full-read path"

# What the key is handed is what fzf prints for the row, so the listing has to carry the file
# in field 3 with the title intact in field 1.
listing = subprocess.run([sys.executable, READER, "list"], capture_output=True, text=True,
                         check=True).stdout.splitlines()
row = [r for r in listing if r.startswith(ROOM + "\t")]
assert len(row) == 1, listing
assert row[0].split("\t")[2] == ROOM_FILE, row

print("trial-rooms-revdiff ok:", tmp)
