#!/usr/bin/env python3
"""Trial for cookbook/chat-rooms/rooms-write.py.

Runs against a throwaway XCHAT_HOME and a fake XCHAT_SESSIONS_DIR, with XCHAT_SESSION set,
so it resolves no live Claude session and never touches the real state directory.
"""

import importlib.util
import os
import re
import subprocess
import sys
import tempfile

RECIPE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "..", "..", "cookbook", "chat-rooms"))
SESSION = "11111111-2222-3333-4444-555555555555"

tmp = tempfile.mkdtemp(prefix="chat-rooms-write-trial-")
os.environ["XCHAT_HOME"] = os.path.join(tmp, "state")
os.environ["XCHAT_SESSIONS_DIR"] = os.path.join(tmp, "sessions")
os.environ["XCHAT_SESSION"] = SESSION
os.environ.pop("AGTERM_SESSION_ID", None)
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"   # the subprocess must not leave one either
sys.path.insert(0, RECIPE)
sys.dont_write_bytecode = True       # the recipe directory holds the README and scripts only

import xchat_store as store

spec = importlib.util.spec_from_file_location("rooms_write",
                                              os.path.join(RECIPE, "rooms-write.py"))
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)

MID = re.compile(r"^msg-\d{6}-[0-9a-f]{4}$")

first_body = "the dwell resets on every keystroke\n\nso the list never settles down"
line, path = writer.write_room("overlay PATH trap", first_body,
                               "why the patched revdiff has to win")
assert line, line
assert line.startswith('room "overlay PATH trap" (msg-'), line
assert line.endswith(", 1 unread message): why the patched revdiff has to win"), line
mid = line.split("(")[1].split(",")[0]
assert MID.match(mid), mid
assert path == os.path.join(store.msgs_dir(), mid + ".md"), path

with open(path) as fh:
    body_file = fh.read()
assert body_file.startswith(f"# {mid}\n"), body_file
assert "- room: overlay PATH trap\n" in body_file, body_file
assert "- summary: why the patched revdiff has to win\n" in body_file, body_file
assert body_file.endswith(first_body + "\n"), body_file

second, _ = writer.write_room("the recency dwell", "a second answer, its own room",
                              "the dwell question")
assert second.startswith('room "the recency dwell" (msg-'), second
assert second.endswith(", 1 unread message): the dwell question"), second

# Two rooms, one message each, both unread.
rows = {r[0]: (r[2], r[3]) for r in store.rooms(SESSION)}
assert rows == {"overlay PATH trap": (1, 1), "the recency dwell": (1, 1)}, rows
back = store.load(store.room_path(SESSION, "overlay PATH trap"))
assert len(back) == 1 and back[0]["body"] == first_body, back
assert back[0]["id"] == mid and back[0]["path"] == path, back
assert back[0]["summary"] == "why the patched revdiff has to win", back

# An unread room appended to again counts both messages in the new pointer.
again, _ = writer.write_room("overlay PATH trap", "a follow-up in the same room", "more")
assert again.endswith(", 2 unread messages): more"), again

# No summary given: the body's first non-empty line becomes it, in the line and in the file.
blank_first = "\n\n  the first line arrives after two blank ones  \nand a second one\n"
empty, empty_path = writer.write_room("cursor rounding", blank_first)
assert empty.endswith("): the first line arrives after two blank ones"), empty
with open(empty_path) as fh:
    assert "- summary: the first line arrives after two blank ones\n" in fh.read()
assert store.load(store.room_path(SESSION, "cursor rounding"))[0]["body"] == blank_first

assert writer.first_line("") == ""
assert writer.first_line("x" * 300) == "x" * 200
assert writer.write_room("", "a body") == (None, None)
assert writer.write_room("a room", "   \n ") == (None, None)

# The command line agrees with the entry point, and stdin is the default body.
out = subprocess.run([sys.executable, os.path.join(RECIPE, "rooms-write.py"),
                      "typed room", "--summary", "from stdin"],
                     input="the piped answer\n", capture_output=True, text=True, check=True)
assert out.stdout.strip().endswith(", 1 unread message): from stdin"), out.stdout
piped = store.load(store.room_path(SESSION, "typed room"))
assert len(piped) == 1 and piped[0]["body"] == "the piped answer\n", piped

print("trial-rooms-write ok:", tmp)
