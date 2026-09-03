#!/usr/bin/env python3
"""Regression checks for the reply path: what cancels, and what reaches the pane."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SEND = HERE / "rooms-send.sh"
WRITE = HERE / "rooms-write.py"

# `tree --json` reporting a live session whose left pane is clear and running an agent, so
# the guard passes and the reply reaches the typing step. `session type` appends instead.
STUB = """#!/bin/sh
if [ "$1" = tree ]; then
  printf '%s' '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"ROW1","realized":true,"foreground":"claude"}]}]}}}'
  exit 0
fi
cat >>"$TYPED"
"""


class SendTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

        stub = self.tmp / "agtermctl"
        stub.write_text(STUB)
        stub.chmod(0o755)

        self.typed = self.tmp / "typed.txt"
        self.typed.write_text("")
        self.env = dict(os.environ,
                        XCHAT_HOME=str(self.tmp / "store"),
                        AGTERMCTL=str(stub),
                        TYPED=str(self.typed),
                        XCHAT_SENDER="tester")

        subprocess.run(["python3", str(WRITE), "test room", "--session", "SESS1",
                        "--summary", "seed"], input="the answer", text=True,
                       env=self.env, check=True, capture_output=True)
        self.room = self.tmp / "store" / "rooms" / "SESS1" / "test-room.jsonl"

    def send(self, text):
        return subprocess.run(["sh", str(SEND), "--room-file", str(self.room),
                               "--target", "ROW1"],
                              input=text, text=True, env=self.env, capture_output=True)

    def messages(self):
        return [json.loads(line) for line in self.room.read_text().splitlines() if line]

    def test_a_bare_escape_cancels_instead_of_posting(self):
        # fzf's execute hands the script a raw terminal, where Esc reaches `read` as the
        # byte itself. Without this it was written into the room as a message saying "^[".
        result = self.send("\033\n")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual(self.typed.read_text(), "")

    def test_an_empty_line_cancels(self):
        result = self.send("\n")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.messages()), 1)

    def test_a_reply_is_written_whole_and_typed_as_one_line(self):
        body = "why not use `rm -rf build` here?\nit would break the cache\n"

        result = self.send(body)

        self.assertEqual(result.returncode, 0)
        records = self.messages()
        self.assertEqual(len(records), 2)
        self.assertEqual(records[1]["from"], "tester")
        self.assertIn("it would break the cache", records[1]["body"])

        typed = self.typed.read_text()
        self.assertEqual(len(typed.strip().splitlines()), 1)
        self.assertNotIn("it would break the cache", typed)
        self.assertIn("full text:", typed)

    def test_a_peer_row_is_refused(self):
        peer = self.tmp / "store" / "threads" / "SESS1" / "PEER.jsonl"
        peer.parent.mkdir(parents=True, exist_ok=True)
        peer.write_text(json.dumps({"at": "2026-09-03 10:00:00", "from": "reviewer",
                                    "peer": "reviewer", "summary": "hi", "body": "hi"}) + "\n")

        result = subprocess.run(["sh", str(SEND), "--room-file", str(peer),
                                 "--target", "ROW1"], input="anything", text=True,
                                env=self.env, capture_output=True)

        self.assertEqual(result.returncode, 3)
        self.assertIn("peer conversation", result.stderr)
        self.assertEqual(self.typed.read_text(), "")


if __name__ == "__main__":
    unittest.main()
