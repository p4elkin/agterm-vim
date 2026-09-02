#!/usr/bin/env python3
"""Claude Code hook: keep the room viewer up in the pane beside the agent.

Registered on one event in ~/.claude/settings.json:

    SessionStart    open the viewer in the right pane when it is not already there

A FRESH session start is the moment the pane is known to be free: the agent has just come up,
and nothing has been typed into either half yet. The viewer is a separate process reading
files, so restarting it costs the agent nothing, but typing into a pane somebody is using
would cost them their command line. Everything below is that one check, done before typing.

Only a `source` of `startup` carries that guarantee. Claude Code fires this same event for
`resume`, `clear` and `compact`, which land in the middle of a working session where the pane
may hold a half-typed command — the injected line would complete it and press Enter. Those
sources still pair the row, which only writes a file, and open nothing.

The hook also records which agterm row this Claude session runs in. It runs as a child of
the Claude process, which the row's own shell started, so AGTERM_SESSION_ID is right here in
the environment. The viewer resolves its rooms through that pairing, so without it a freshly
opened viewer lists nothing.

Switches
--------
  XCHAT=off                     env var, disables the hook completely
  rooms-restore-hook.off        if this file exists beside this script, the hook is off
  XCHAT_VIEW=<path>             the viewer to open (default rooms-view.sh beside this file)
  AGTERMCTL=<path>              the CLI to drive
  XCHAT_HOME=<dir>              where the rooms are kept

Fails open. Any error at all and the hook exits 0 with nothing on stdout, so a fault here can
never be the reason a session fails to start.
"""

import json
import os
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xchat_store as store

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.environ.get("XCHAT_VIEW") or os.path.join(HERE, "rooms-view.sh")
AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
# How long to wait for a freshly opened split to grow a live terminal.
SPLIT_TIMEOUT = 3.0
SPLIT_POLL = 0.1


def run(*args, capture=False):
    """One agtermctl call. Returns its stdout when asked, None when it failed."""
    try:
        done = subprocess.run([AGTERMCTL, *args], check=False, timeout=10,
                              stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as exc:
        store.log(f"rooms-restore: {args[0] if args else 'agtermctl'} failed: {exc}")
        return None
    if done.returncode != 0:
        return None
    return done.stdout.decode("utf-8", "replace") if capture else ""


def node_for(row):
    """The tree node of this row. `tree` is read-only, so it is safe on any socket."""
    out = run("tree", "--json", capture=True)
    if out is None:
        return None, "agtermctl could not read the tree"
    try:
        payload = json.loads(out)
    except ValueError as exc:
        return None, f"the tree did not parse ({exc})"
    tree = payload.get("result", payload).get("tree", payload)
    # A picker owns the keyboard of its whole window, so it blocks whatever the panes hold.
    if tree.get("pickPending"):
        return None, "a picker is waiting for an answer"
    node = next((s for ws in tree.get("workspaces") or []
                 for s in ws.get("sessions") or [] if s.get("id") == row), None)
    if node is None:
        return None, f"no session {row} in the tree"
    return node, ""


def covered(node):
    """Why real keystrokes would not reach the right pane, or an empty string."""
    if node.get("realized") is False:
        return "the session has no live terminal yet"
    if node.get("overlay"):
        return "an overlay covers the whole session"
    if "right" in (node.get("paneOverlays") or []):
        return "an overlay covers the right pane"
    if node.get("scratch"):
        return "the scratch terminal is up"
    return ""


def holds_viewer(node):
    """Whether the split pane is already running the viewer.

    The pane's foreground process is fzf, not this script: the script execs nothing and fzf
    outlives its start. Both spellings carry the viewer's path, because fzf's own argv holds
    the bind strings that re-enter it, so one marker matches the shell and the fzf phase.
    """
    argv = node.get("splitForeground") or []
    return os.path.basename(VIEWER) in " ".join(argv)


def wait_for_split(row):
    """Poll until the new pane has a terminal to type into. Returns the node, or None."""
    deadline = time.monotonic() + SPLIT_TIMEOUT
    while True:
        node, _ = node_for(row)
        if node and node.get("hasSplit"):
            return node
        if time.monotonic() >= deadline:
            return None
        time.sleep(SPLIT_POLL)


def open_viewer(row):
    node, why = node_for(row)
    if node is None:
        store.log(f"rooms-restore: not opening the viewer: {why}")
        return
    why = covered(node)
    if why:
        store.log(f"rooms-restore: not opening the viewer: {why}")
        return

    if holds_viewer(node):
        # Already up. A split hidden with ⌘D stays hidden — the viewer is running in it, and
        # re-showing a pane somebody just put away is not a restore.
        return

    if node.get("hasSplit"):
        if node.get("splitForeground"):
            store.log("rooms-restore: the right pane is running something else, leaving it")
            return
        # A hidden split at a prompt is still a pane to type into, but the viewer would be
        # invisible in it, so show it first.
        if not node.get("split"):
            run("session", "split", "on", "--target", row)
    else:
        if run("session", "split", "on", "--target", row) is None:
            store.log("rooms-restore: the split would not open")
            return
        if wait_for_split(row) is None:
            store.log("rooms-restore: the split never grew a terminal")
            return

    line = f"{shlex.quote(VIEWER)} {shlex.quote(row)}\n"
    if run("session", "type", line, "--target", row, "--pane", "right") is None:
        store.log("rooms-restore: typing the viewer into the right pane failed")
        return
    # Opening a split moves focus into it, and the agent's pane is where you type next.
    run("session", "focus", "primary", "--target", row)


def main():
    if os.environ.get("XCHAT", "").lower() == "off":
        return 0
    if os.path.exists(os.path.join(HERE, "rooms-restore-hook.off")):
        return 0

    payload = json.load(sys.stdin)
    if payload.get("hook_event_name") != "SessionStart":
        return 0

    row = os.environ.get("AGTERM_SESSION_ID", "")
    store.pair(row, payload.get("session_id") or "", os.environ.get("AGTERM_PANE", ""))
    if not row:
        return 0                      # not running in agterm, so there is no pane to open

    # Only `startup` means what this hook assumes. SessionStart also fires for `resume`, `clear`
    # and `compact`, and those land in the middle of a working session: the pane may hold a shell
    # with a half-typed command, which the viewer command would complete and run. Pairing above
    # still happens every time, because that only writes a file.
    source = payload.get("source") or "startup"
    if source != "startup":
        store.log(f"rooms-restore: session start source is {source}, not opening the viewer")
        return 0

    open_viewer(row)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - never be the reason a session fails to start
        store.log(f"rooms-restore failing open: {exc!r}")
        sys.exit(0)
