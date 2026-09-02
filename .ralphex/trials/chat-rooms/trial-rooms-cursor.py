#!/usr/bin/env python3
"""Trial for reading a room advancing its cursor.

Runs the reader the way the viewer runs it, against a throwaway XCHAT_HOME and a fake
XCHAT_SESSIONS_DIR, so it resolves no live Claude session and touches no real state.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

RECIPE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "..", "cookbook", "chat-rooms"))
SESSION = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

tmp = tempfile.mkdtemp(prefix="chat-rooms-cursor-trial-")
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

READER = os.path.join(RECIPE, "rooms-read.py")
ROOM = "the overlay PATH trap"
PATH = store.room_path(SESSION, ROOM)
CURSOR = store.cursor_path(SESSION, ROOM)


def show(*extra):
    out = subprocess.run([sys.executable, READER, "show", "--path", PATH,
                          "--width", "90", "--no-color", *extra],
                         capture_output=True, text=True, check=True)
    return out.stdout


def listing():
    out = subprocess.run([sys.executable, READER, "list"], capture_output=True, text=True,
                         check=False)
    return {r.split("\t")[0]: r.split("\t")[1] for r in out.stdout.splitlines() if r}


writer.write_room(ROOM, "the app PATH has no /opt/homebrew/bin", "why fzf reads as missing")
writer.write_room(ROOM, "so the viewer exports its own", "the fix")
writer.write_room("a quiet room", "nobody opens this one", "left unread")

assert store.room_unread(SESSION, ROOM) == 2, store.rooms(SESSION)
assert not os.path.exists(CURSOR), CURSOR
assert listing()[ROOM].startswith("2 new, 2 msg"), listing()

# A preview follows the selection, so it must never move the cursor.
assert "2 unread" in show(), show()
assert not os.path.exists(CURSOR), CURSOR
assert store.room_unread(SESSION, ROOM) == 2

# Opening the room is what reads it: the cursor file lands on the room's length and the
# badge clears.
body = show("--mark")
assert "2 unread" in body, body
size = os.path.getsize(PATH)
with open(CURSOR) as fh:
    assert int(fh.read().strip()) == size, (fh, size)
assert store.room_unread(SESSION, ROOM) == 0, store.rooms(SESSION)
assert listing()[ROOM].startswith("2 msg"), listing()
assert "new" not in listing()[ROOM], listing()

# Reading one room leaves every other room's count alone.
assert listing()["a quiet room"].startswith("1 new, 1 msg"), listing()

# A room appended to after being read counts again, and reading it clears it again.
writer.write_room(ROOM, "a follow-up asked inside the room", "and its answer")
assert store.room_unread(SESSION, ROOM) == 1, store.rooms(SESSION)
assert listing()[ROOM].startswith("1 new, 3 msg"), listing()
show("--mark")
assert store.room_unread(SESSION, ROOM) == 0, store.rooms(SESSION)

# A message that arrives while the room sits open in the pager was not on the screen, so it
# must survive the mark. The reader takes the length before rendering; this is that length
# handed back explicitly, which is what a slow pager amounts to.
seen = os.path.getsize(PATH)
writer.write_room(ROOM, "arrived while the pager was up", "not on that screen")
store.advance_cursor_at(PATH, seen)
assert store.room_unread(SESSION, ROOM) == 1, store.rooms(SESSION)

# An unreadable cursor, and one past the end, both read as zero rather than hiding the room.
with open(CURSOR, "w") as fh:
    fh.write("not a number")
assert store.room_cursor(SESSION, ROOM) == 0
assert store.room_unread(SESSION, ROOM) == 4, store.rooms(SESSION)
with open(CURSOR, "w") as fh:
    fh.write(str(os.path.getsize(PATH) + 1000))
assert store.room_cursor(SESSION, ROOM) == 0

# The viewer opens a room the same way: its enter binding marks, the preview does not.
with open(os.path.join(RECIPE, "rooms-view.sh")) as fh:
    view = [ln for ln in fh if "--bind" in ln or "--preview=" in ln]
enter = [ln for ln in view if "enter:execute" in ln]
preview = [ln for ln in view if "--preview=" in ln]
assert len(enter) == 1 and "--mark" in enter[0], enter
assert len(preview) == 1 and "--mark" not in preview[0], preview
assert "reload(" in enter[0], enter               # the badge clears without waiting a tick

print("trial-rooms-cursor ok:", tmp)
