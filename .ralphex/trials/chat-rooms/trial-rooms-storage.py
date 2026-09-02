#!/usr/bin/env python3
"""Trial for the room storage in cookbook/chat-rooms/xchat_store.py.

Runs against a throwaway XCHAT_HOME and a fake XCHAT_SESSIONS_DIR, so it never touches the
real state directory and never needs a live agterm.
"""

import os
import sys
import tempfile

RECIPE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "..", "..", "cookbook", "chat-rooms")

tmp = tempfile.mkdtemp(prefix="chat-rooms-trial-")
os.environ["XCHAT_HOME"] = os.path.join(tmp, "state")
os.environ["XCHAT_SESSIONS_DIR"] = os.path.join(tmp, "sessions")
sys.path.insert(0, os.path.abspath(RECIPE))
sys.dont_write_bytecode = True       # the recipe directory holds the README and scripts only

# Imported after the environment is set, because the module reads XCHAT_SESSIONS_DIR at import.
import xchat_store as store

SESSION = "11111111-2222-3333-4444-555555555555"


def msg(body):
    return {"at": "2026-09-02 10:00:00", "body": body}


def counts(titles):
    return [store.room_unread(SESSION, t) for t in titles]


titles = ["the recency dwell", "cursor rounding", "overlay PATH trap"]
for title, n in zip(titles, (2, 1, 3)):
    for i in range(n):
        assert store.append_room(SESSION, title, msg(f"{title} #{i}")), title

assert counts(titles) == [2, 1, 3], counts(titles)

store.advance_cursor(SESSION, titles[0])
assert counts(titles) == [0, 1, 3], counts(titles)

store.append_room(SESSION, titles[0], msg("after the read"))
assert counts(titles) == [1, 1, 3], counts(titles)

rows = store.rooms(SESSION)
assert sorted(r[0] for r in rows) == sorted(titles), rows
assert {r[0]: r[2] for r in rows} == {titles[0]: 3, titles[1]: 1, titles[2]: 3}, rows
assert {r[0]: r[3] for r in rows} == {titles[0]: 1, titles[1]: 1, titles[2]: 3}, rows

odd = "⠂ разбор сессии ✳"
path = store.append_room(SESSION, odd, msg("тело сообщения ✳"))
assert path and os.path.exists(path), path
back = store.load(path)
assert len(back) == 1 and back[0]["room"] == odd, back
assert back[0]["body"] == "тело сообщения ✳", back
assert store.room_unread(SESSION, odd) == 1
assert odd in [r[0] for r in store.rooms(SESSION)], store.rooms(SESSION)

store.advance_cursor(SESSION, odd)
assert store.room_unread(SESSION, odd) == 0

# A cursor left past the end reads as unread rather than hiding the room.
with open(store.cursor_path(SESSION, odd), "w") as fh:
    fh.write("999999")
assert store.room_unread(SESSION, odd) == 1

assert store.append_room("", "no session", msg("x")) is None
assert store.append_room(SESSION, "   ", msg("x")) is None
assert store.room_unread(SESSION, "never opened") == 0
assert store.rooms("no-such-session") == []

print("trial-rooms-storage ok:", tmp)
