#!/usr/bin/env python3
"""Claude Code hook: record every cross-agent message, and keep a long one out of the chat.

Registered twice in ~/.claude/settings.json, on two events:

    SessionStart                      records which Claude session runs in which agterm row
    PreToolUse (matcher SendMessage)  records the message, and rewrites a long one

A long SendMessage lands in the receiving session as a wall of text spliced into the middle
of whatever that session was doing. Nothing can fix that on the receiving side: there is no
hook event for an incoming cross-session message, and MessageDisplay fires on assistant text,
is display-only, and cannot suppress. The only lever is PreToolUse on the SENDER.

So the sender rewrites its own message before it goes out. The body is written to a file and
appended to the thread with that peer; what travels on the wire is one line naming the id,
the sender, the summary, and how soon it wants reading.

Priority is a marker at the very start of the message text, set by the sending agent:

    [urgent] ...   read it now, before continuing
    [fyi] ...      no reply needed, read whenever or skip
    (no marker)    read it when the current step finishes

Short messages pass through untouched: a one-liner does not need a pointer to itself.

Switches
--------
  XCHAT=off                     env var, disables the hook completely
  xchat-hook.off                if this file exists beside this script, the hook is off
  XCHAT_THRESHOLD=<chars>       override the pass-through size (default 400)
  XCHAT_HOME=<dir>              where the record is kept

Fails open. Any error at all and the hook emits nothing, so the original message goes out
unchanged. This sits in the path of every cross-session message, so it must never be the
reason one fails to arrive.
"""

import json
import os
import re
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import xchat_store as store

DEFAULT_THRESHOLD = 400
MARKER_RE = re.compile(r"^\s*\[(urgent|fyi)\]\s*", re.IGNORECASE)

POINTER = {
    "urgent": (
        "URGENT {mid} from {sender}: {summary}\n"
        "Full text: {path}\n"
        "Read it now, before you continue what you were doing. Reply with SendMessage to "
        '"{sender}".'
    ),
    "normal": (
        "{mid} from {sender}: {summary}\n"
        "Full text: {path}\n"
        "Read it when your current step finishes. It does not need to interrupt you. Reply "
        'with SendMessage to "{sender}".'
    ),
    "fyi": (
        "FYI {mid} from {sender}: {summary}\n"
        "Full text: {path}\n"
        "No reply needed. Read it whenever you have a gap, or skip it."
    ),
}


def pair_this_pane(claude_session):
    """Tie this Claude session to the agterm row it is running in.

    The hook runs as a child of the Claude process, which was started by the row's own shell,
    so the AGTERM_* variables agterm exported into that shell are right here in the
    environment. That is the whole join: the reader knows AGTERM_SESSION_ID and nothing else,
    and this is the one place where both halves are known at once.
    """
    store.pair(os.environ.get("AGTERM_SESSION_ID", ""), claude_session,
               os.environ.get("AGTERM_PANE", ""))


def spool(mid, sender, recipient, priority, summary, body):
    """Write the message out in full. Returns its path, or None if it could not be written."""
    path = os.path.join(store.msgs_dir(), mid + ".md")
    try:
        os.makedirs(store.msgs_dir(), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(
                f"# {mid}\n\n"
                f"- from: {sender}\n"
                f"- to: {recipient}\n"
                f"- priority: {priority}\n"
                f"- sent: {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"- summary: {summary}\n\n"
                f"---\n\n{body}\n"
            )
    except OSError as exc:
        store.log(f"spool write failed, passing message through: {exc}")
        return None
    return path


def on_send(payload):
    args = payload.get("tool_input") or {}
    body = args.get("message")

    # The protocol forms of `message` are JSON objects (shutdown_request and friends).
    # Those are machine-read on arrival and must travel untouched.
    if not isinstance(body, str):
        return 0

    recipient = (args.get("to") or "").strip()
    if not recipient:
        return 0

    me = payload.get("session_id") or ""
    # Re-pair on every send, not only at SessionStart, so a session that was already running
    # when the hook was installed still becomes readable.
    pair_this_pane(me)

    priority = "normal"
    marker = MARKER_RE.match(body)
    if marker:
        priority = marker.group(1).lower()

    try:
        threshold = int(os.environ.get("XCHAT_THRESHOLD", DEFAULT_THRESHOLD))
    except ValueError:
        threshold = DEFAULT_THRESHOLD

    sender = store.name_for_id(me, "a peer session")
    recipient_name = store.REF_SUFFIX.sub("", recipient)
    peer_id = store.id_for_name(recipient_name)
    if not peer_id:
        store.log(f"no session id for {recipient_name!r}; its own copy is keyed on the name")

    summary = (args.get("summary") or "").strip()
    if not summary:
        first = MARKER_RE.sub("", body).strip().splitlines()
        summary = (first[0] if first else "")[:200]

    mid = f"msg-{time.strftime('%H%M%S')}-{uuid.uuid4().hex[:4]}"
    path = spool(mid, sender, recipient_name, priority, summary, body)
    if not path:
        return 0                      # cannot park the body, so do not strip it from the wire

    # Everything is recorded, including short messages that travel whole. The record is meant
    # to be the conversation, and a conversation with the one-liners missing is not one.
    # Only the REWRITE is gated on size: a short message is already its own pointer.
    rewrite = len(body) >= threshold
    how = "pointer" if rewrite else "inline"

    def record(direction, peer):
        return {"id": mid, "at": time.strftime("%Y-%m-%d %H:%M:%S"), "direction": direction,
                "peer": peer, "from": sender, "to": recipient_name, "priority": priority,
                "delivery": how, "summary": summary, "body": body}

    # Two copies, one per side, so each session reads its own view of the exchange.
    #
    # Delivery stays silent: the hook writes the thread and nothing else. No split stolen, no
    # overlay forced, no panel drawn over whatever the receiving session was showing. The
    # chord is what pulls a conversation up, when its reader wants it.
    store.append(me, peer_id, record("sent", recipient_name), recipient_name)
    if peer_id:
        store.append(peer_id, me, record("received", sender), sender)

    if not rewrite:
        return 0                      # recorded and spooled, but it travels whole

    updated = dict(args)
    updated["message"] = POINTER[priority].format(
        mid=mid, sender=sender, summary=summary, path=path
    )
    updated["summary"] = summary[:200]

    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": updated,
    }}))
    return 0


def main():
    if os.environ.get("XCHAT", "").lower() == "off":
        return 0
    if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "xchat-hook.off")):
        return 0

    payload = json.load(sys.stdin)
    if payload.get("hook_event_name") == "SessionStart":
        pair_this_pane(payload.get("session_id") or "")
        return 0
    if payload.get("tool_name") == "SendMessage":
        return on_send(payload)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - never be the reason a message fails to arrive
        store.log(f"failing open: {exc!r}")
        sys.exit(0)
