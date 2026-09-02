#!/bin/sh
# Carry what you typed in a room back into the agent's pane.
#
# The rooms are one-way on their own: the agent writes, the viewer reads. This is the way
# back. It is bound to a key in the viewer, and can also be run by hand:
#
#   rooms-send.sh --room-file ~/.claude/xchat/rooms/<session>/<slug>.jsonl
#   rooms-send.sh --room "the overlay PATH trap" --session <claude-session> --text "why?"
#
# Two things happen, in this order:
#
#   1. the full text goes into the room, as a message from you
#   2. one line goes into the agent's pane as real keystrokes, carrying the pointer only
#
# That order is the whole point. The wire stays one line whatever was typed, so a long reply
# never lands as a wall of text in the middle of the agent's work, and the parking the
# agent-to-agent path needs a hook for happens here for free: the room file IS the parking.
# The pointer names the body's path, which is the one read the agent owes a room — a
# follow-up asked in a room is answered in that room, and after a compact the argument it
# follows is no longer in context.
set -eu

# An overlay, and a pane opened by a hook, both start under the APP's PATH, which has no
# /opt/homebrew/bin and no ~/.local/bin. ~/.local/bin comes first for the same reason the
# viewer puts it there.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WRITE_PY=${XCHAT_WRITE:-$DIR/rooms-write.py}
PYTHON=${PYTHON:-python3}
AGTERMCTL=${AGTERMCTL:-agtermctl}
# What the agent's pane sees in front of every one of these lines. Fixed, so the agent can
# recognise a room reply without being told what to look for.
PREFIX=${XCHAT_ROOM_PREFIX:-[room]}
SENDER=${XCHAT_SENDER:-${USER:-you}}
SUMMARY_COLS=160

ROOM_FILE=""
ROOM=""
SESSION=""
TEXT=""
HAVE_TEXT=0
PANE=${XCHAT_SEND_PANE:-left}
ROW=${AGTERM_SESSION_ID:-}

die() {
	printf '\n  %s\n\n' "$1" >&2
	exit 1
}

# Refusing is a success for this script: nothing is typed, nothing is written, and you are
# told why. Exit 3 marks it apart from a usage error.
refuse() {
	printf '\n  not typing: %s\n  %s\n\n' "$1" \
		"Your text was not written to the room either. Try again once the pane is clear." >&2
	exit 3
}

while [ $# -gt 0 ]; do
	case $1 in
	--room-file) ROOM_FILE=${2:?--room-file needs a path}; shift 2 ;;
	--room) ROOM=${2:?--room needs a title}; shift 2 ;;
	--session) SESSION=${2:?--session needs a Claude session id}; shift 2 ;;
	--text) TEXT=${2?--text needs a string}; HAVE_TEXT=1; shift 2 ;;
	--pane) PANE=${2:?--pane needs left, right or scratch}; shift 2 ;;
	--target) ROW=${2:?--target needs an agterm session id}; shift 2 ;;
	-h | --help)
		sed -n '2,20p' "$0"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

# A room file names both halves: the directory is the Claude session, and the newest message
# in it holds the title. The filename cannot, because it is a slug and the title it came from
# is gone.
if [ -n "$ROOM_FILE" ]; then
	[ -f "$ROOM_FILE" ] || die "no such room file: $ROOM_FILE"
	[ -n "$SESSION" ] || SESSION=$(basename "$(dirname "$ROOM_FILE")")
	[ -n "$ROOM" ] || ROOM=$("$PYTHON" -c '
import json, sys
title = ""
for line in open(sys.argv[1]):
    try:
        title = json.loads(line).get("room") or title
    except ValueError:
        pass
print(title)
' "$ROOM_FILE")
fi

[ -n "$ROOM" ] || die "which room? pass --room-file FILE or --room TITLE"
[ -n "$SESSION" ] || SESSION=${XCHAT_SESSION:-}
[ -n "$SESSION" ] || die "which agent? pass --room-file FILE or --session ID"
[ -n "$ROW" ] || die "no AGTERM_SESSION_ID, so there is no pane to type into. Pass --target ID."

# Real keystrokes go into the pane the way a keyboard does, so anything covering that pane
# eats them. `tree` is read-only and safe on any socket; the write below is not, which is why
# this check comes first and refuses rather than guesses.
TREE=$(mktemp "${TMPDIR:-/tmp}/agterm-rooms-tree.XXXXXX")
trap 'rm -f "$TREE"' EXIT INT TERM
"$AGTERMCTL" tree --json >"$TREE" 2>/dev/null || refuse "agtermctl could not read the tree"

BLOCKED=$("$PYTHON" - "$ROW" "$PANE" "$TREE" <<'PY'
import json
import sys

row, pane, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as fh:
        payload = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"the tree did not parse ({exc})")
    raise SystemExit(0)

tree = payload.get("result", payload).get("tree", payload)

# A picker owns the keyboard of its whole window, so it blocks whatever the pane state is.
if tree.get("pickPending"):
    print("a picker is waiting for an answer")
    raise SystemExit(0)

node = next((s for ws in tree.get("workspaces") or []
             for s in ws.get("sessions") or [] if s.get("id") == row), None)
if node is None:
    print(f"no session {row} in the tree")
    raise SystemExit(0)
if node.get("realized") is False:
    print("that session has no live terminal yet")
elif node.get("overlay"):
    print("an overlay covers the whole session")
elif pane in (node.get("paneOverlays") or []):
    print(f"an overlay covers the {pane} pane")
elif node.get("scratch"):
    # The scratch is a cover that also takes the keyboard, so it is the same hazard as an
    # overlay even though it reports separately.
    print("the scratch terminal is up")
else:
    # Nothing is covering the pane, so what matters now is whether an agent is reading it.
    # `foreground` is nil at a bare shell prompt, and a reply typed at a prompt is a command:
    # the text is sent with a trailing newline, so backticks and $( ) in an ordinary sentence
    # like "why not use `rm -rf build` here?" run before the line even fails to parse.
    # The restore hook already refuses on this field for the other pane; this is the same rule.
    field = "splitForeground" if pane in ("right", "split") else "foreground"
    if not node.get(field):
        print(f"the {pane} pane is at a shell prompt, not running an agent")
PY
)
[ -z "$BLOCKED" ] || refuse "$BLOCKED"

if [ "$HAVE_TEXT" -eq 0 ]; then
	if [ -t 0 ]; then
		printf '\n  reply in "%s" — one line, empty cancels\n  > ' "$ROOM" >/dev/tty
		IFS= read -r TEXT </dev/tty || TEXT=""
	else
		TEXT=$(cat)
	fi
fi
case $TEXT in
'' | ' ') exit 0 ;;
esac

# The first line, which is the convention the whole recipe reads summaries by.
SUMMARY=$(printf '%s\n' "$TEXT" | awk 'NF { print substr($0, 1, '"$SUMMARY_COLS"'); exit }')

OUT=$(printf '%s' "$TEXT" | "$PYTHON" "$WRITE_PY" "$ROOM" \
	--session "$SESSION" --from "$SENDER" --summary "$SUMMARY" --mark --paths) ||
	die "the room could not be written, so nothing was typed"
BODY_PATH=$(printf '%s\n' "$OUT" | tail -n 1)

LINE="$PREFIX \"$ROOM\" — $SENDER: $SUMMARY — full text: $BODY_PATH"
if ! printf '%s\n' "$LINE" | "$AGTERMCTL" session type --stdin --target "$ROW" --pane "$PANE"; then
	printf '\n  %s\n  %s\n\n' \
		"typing failed, but your text is in the room and not lost:" "$BODY_PATH" >&2
	exit 4
fi
