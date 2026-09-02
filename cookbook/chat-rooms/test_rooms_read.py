#!/usr/bin/env python3
"""Regression checks for the reader, over rooms and peer conversations alike."""

import io
import json
import os
import runpy
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT = runpy.run_path(Path(__file__).with_name("rooms-read.py"))
CMD_MARKDOWN = SCRIPT["cmd_markdown"]
CMD_SHOW = SCRIPT["cmd_show"]
SPLIT_PATHS = SCRIPT["split_paths"]
STORE = SCRIPT["store"]

MINE = "11111111-1111-1111-1111-111111111111"
MINE_RESTARTED = "22222222-2222-2222-2222-222222222222"
PEER = "33333333-3333-3333-3333-333333333333"


def thread_record(at, body, summary, direction="received"):
    return {"at": at, "from": "reviewer", "id": "msg-" + summary, "summary": summary,
            "body": body, "peer": "reviewer", "direction": direction}


def room_record(at, body, summary):
    return {"at": at, "from": "planner", "id": "msg-" + summary, "summary": summary,
            "body": body, "room": "Design notes"}


class ReaderTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "xchat"
        self.out_dir = Path(tmp.name) / "out"
        patcher = patch.dict(os.environ, {"XCHAT_HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, path, records):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
        return str(path)

    def thread(self, me, peer, records):
        return self.write(self.home / "threads" / me / f"{peer}.jsonl", records)

    def room(self, session, leaf, records):
        return self.write(self.home / "rooms" / session / f"{leaf}.jsonl", records)

    def show(self, path, *extra):
        args = ["show", "--path", path, "--width", "80", "--no-color", *extra]
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = CMD_SHOW(args)
        return code, buf.getvalue()

    def markdown(self, path, *extra):
        args = ["markdown", "--path", path, "--out-dir", str(self.out_dir), *extra]
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = CMD_MARKDOWN(args)
        return code, buf.getvalue().strip()


class PeerThreadTests(ReaderTests):
    def test_a_peer_thread_is_titled_with_the_peer(self):
        path = self.thread(MINE, PEER, [thread_record("2026-09-02 10:00:00", "hi", "greeting")])

        code, out = self.show(path)

        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("reviewer"), out.splitlines()[0])

    def test_a_group_renders_both_files_in_time_order(self):
        first = self.thread(MINE, PEER, [thread_record("2026-09-02 10:00:00", "earlier", "one")])
        second = self.thread(MINE_RESTARTED, PEER,
                             [thread_record("2026-09-02 11:00:00", "later", "two")])

        code, out = self.show(f"{first},{second}")

        self.assertEqual(code, 0)
        self.assertLess(out.index("earlier"), out.index("later"))

    def test_markdown_on_a_group_writes_one_document(self):
        first = self.thread(MINE, PEER, [thread_record("2026-09-02 10:00:00", "earlier", "one")])
        second = self.thread(MINE_RESTARTED, PEER,
                             [thread_record("2026-09-02 11:00:00", "later", "two")])

        code, dest = self.markdown(f"{first},{second}")

        self.assertEqual(code, 0)
        written = Path(dest).read_text()
        self.assertIn("earlier", written)
        self.assertIn("later", written)
        self.assertEqual(written.splitlines()[0], "# reviewer")
        self.assertEqual(list(Path(dest).parent.glob("*.md")), [Path(dest)])

    def test_marking_a_group_clears_every_badge(self):
        first = self.thread(MINE, PEER, [thread_record("2026-09-02 10:00:00", "earlier", "one")])
        second = self.thread(MINE_RESTARTED, PEER,
                             [thread_record("2026-09-02 11:00:00", "later", "two")])
        self.assertEqual([STORE.unread_at(first), STORE.unread_at(second)], [1, 1])

        self.show(f"{first},{second}", "--mark")

        self.assertEqual([STORE.unread_at(first), STORE.unread_at(second)], [0, 0])

    def test_a_comma_in_the_home_directory_does_not_split_a_path(self):
        self.assertEqual(SPLIT_PATHS("/tmp/a,b/threads/me/peer.jsonl"),
                         ["/tmp/a,b/threads/me/peer.jsonl"])
        self.assertEqual(SPLIT_PATHS("/tmp/a,b/one.jsonl,/tmp/a,b/two.jsonl"),
                         ["/tmp/a,b/one.jsonl", "/tmp/a,b/two.jsonl"])


class RoomTests(ReaderTests):
    def setUp(self):
        super().setUp()
        self.path = self.room(MINE, "design-notes", [
            room_record("2026-09-02 10:00:00", "the first note", "opening"),
            room_record("2026-09-02 11:00:00", "the second note", "answer")])

    def test_a_room_renders_under_its_title(self):
        code, out = self.show(self.path)

        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("Design notes"), out.splitlines()[0])
        self.assertIn("2 messages, 2 unread", out)
        self.assertIn("the second note", out)

    def test_a_room_marks_read(self):
        self.show(self.path, "--mark")

        self.assertEqual(STORE.unread_at(self.path), 0)

    def test_a_room_writes_markdown_named_after_its_file(self):
        code, dest = self.markdown(self.path)

        self.assertEqual(code, 0)
        self.assertEqual(Path(dest).name, "design-notes.md")
        self.assertEqual(Path(dest).parent.name, MINE)
        self.assertEqual(Path(dest).read_text().splitlines()[0], "# Design notes")

    def test_a_message_appended_while_reading_stays_unread(self):
        original = os.path.getsize(self.path)
        real_load = STORE.load

        def load_then_append(path):
            msgs = real_load(path)
            self.write(Path(self.path),
                       [room_record("2026-09-02 12:00:00", "arrived late", "late")])
            return msgs

        with patch.object(STORE, "load", side_effect=load_then_append):
            self.show(self.path, "--mark")

        self.assertEqual(STORE.cursor_at(self.path), original)
        self.assertEqual(STORE.unread_at(self.path), 1)


if __name__ == "__main__":
    unittest.main()
