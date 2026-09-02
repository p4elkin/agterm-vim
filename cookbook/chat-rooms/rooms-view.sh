#!/bin/sh
# The chat rooms of the agent in this row, as a viewer that stays up.
#
# Runs in the pane next to the agent, normally opened by the SessionStart hook:
#
#   agtermctl session split --target "$AGTERM_SESSION_ID" ... && \
#   agtermctl session type --target ... "~/.local/bin/agterm-rooms/rooms-view.sh"
#
# It also works as an overlay program, in which case it takes the row as $1, because
# `overlay open` takes a PROGRAM and not a program plus arguments.
#
# The list on the left is one line per room with its unread count, the preview on the right
# is the room itself. Enter opens the room in a pager, marks it read and comes back; esc
# closes the viewer. Moving the selection only previews, and a preview never marks, so a room
# is read when it is opened and not when it is walked past. Ctrl-s replies in the selected
# room: the text goes into the room and one line goes into the agent's pane. Ctrl-o is the
# full read: the room becomes a markdown file and opens in revdiff, where tables and mermaid
# are drawn and a line can be annotated.
#
# revdiff is the full-read path because the annotate chord cannot reach a room at all:
# the annotate recipe's annotate-extract.py:179 skips every block whose type is not
# `text`, and a room answer is written through a tool call. A room file opened directly needs
# no extraction, so nothing has to change there.
# A background loop watches the room files and pushes both sides forward on its own, so a
# room the agent writes to appears with no keypress.
#
# This is a separate process reading files. It costs the agent nothing, and the agent never
# reads a room back.
set -eu

# An overlay, and a pane opened by a hook, both start under the APP's PATH:
#   /usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin  plus the agterm bundle
# There is no /opt/homebrew/bin and no ~/.local/bin, so a bare fzf reads as not installed.
#
# ~/.local/bin comes FIRST on purpose. The reverse order resolves the Homebrew revdiff
# 1.11.1, which has no markdown preview mode, and the full-read key needs the patched build
# in ~/.local/bin to draw tables and mermaid.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
READ_PY=${XCHAT_READ:-$DIR/rooms-read.py}
SEND_SH=${XCHAT_SEND:-$DIR/rooms-send.sh}
PYTHON=${PYTHON:-python3}
FZF=${FZF:-fzf}
CURL=${CURL:-curl}
REVDIFF=${REVDIFF:-revdiff}
SELF=$DIR/$(basename -- "$0")
# How often the watcher looks at the room files. Cheap: one find over one directory.
INTERVAL=${XCHAT_VIEW_INTERVAL:-1}

# Width from the pane we actually got. `tput cols` reports 79 inside an agterm overlay
# however wide the window is, which wraps every room into a narrow column and wastes most of
# the screen. Ask the tty directly instead. The redirect itself fails when there is no
# controlling terminal, and the shell reports that on its own stderr, so the whole thing is
# wrapped in braces rather than just the stty.
cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}' )
[ -n "${cols:-}" ] || cols=$(tput cols 2>/dev/null || echo 100)

# --full-read FILE is the ctrl-o key coming back into this script. It re-enters rather than
# inlining the whole thing in an fzf bind string, where a room file's own quoting is hazard
# enough without a pipeline around it.
if [ "${1:-}" = "--full-read" ]; then
	room=${2:-}
	[ -n "$room" ] || { printf '\n  --full-read needs a room file\n\n' >&2; exit 2; }
	md=$("$PYTHON" "$READ_PY" markdown --path "$room" --mark) || exit 0
	[ -n "$md" ] || exit 0
	if command -v "$REVDIFF" >/dev/null 2>&1; then
		set -- --only="$md"
		# Two revdiffs answer to that name. Only the patched build has markdown preview
		# mode, and only that one draws a table as a table and a mermaid block as box art.
		# Its --help is what tells them apart: Homebrew 1.11.1 has no --preview.
		if "$REVDIFF" --help 2>&1 | grep -q -- '--preview'; then
			set -- --preview --wrap "$@"
		else
			printf '\n  %s\n  %s\n\n' \
				"This revdiff has no markdown preview mode, so the room opens as source." \
				"The patched build in ~/.local/bin is the one that renders it." >&2
		fi
		"$REVDIFF" "$@" || true
	else
		# No revdiff at all: the pager is still a full read, just without the rendering.
		"$PYTHON" "$READ_PY" show --path "$room" --width "$cols" | less -R
	fi
	exit 0
fi

# The row to read for. A pane inherits the AGTERM_* variables of the session it opens in;
# $1 is there for a chord that would rather pass {AGT_SESSION_ID} explicitly. XCHAT_SESSION
# names a Claude session directly, for a shell outside agterm.
ROW=${1:-${AGTERM_SESSION_ID:-}}
if [ -n "${XCHAT_SESSION:-}" ]; then
	SEL_FLAG=--session
	SEL_VAL=$XCHAT_SESSION
elif [ -n "$ROW" ]; then
	SEL_FLAG=--row
	SEL_VAL=$ROW
else
	printf '\n  %s\n  %s\n\n' \
		"No AGTERM_SESSION_ID, so this viewer cannot tell which row it belongs to." \
		"Pass the row as the first argument, or set XCHAT_SESSION to a Claude session id."
	exit 1
fi

# The row to type back into. Empty outside agterm, where rooms-send.sh refuses on its own
# rather than typing into a pane it cannot name.
SEND_TARGET=""
[ -z "$ROW" ] || SEND_TARGET=" --target '$ROW'"

# One command string, used by fzf at start and by the watcher's reload. Two copies would
# drift, and the drift only shows up after the first append.
LIST="'$PYTHON' '$READ_PY' list $SEL_FLAG '$SEL_VAL'"

ROOMS_DIR=$("$PYTHON" "$READ_PY" where)
STATE=$(mktemp -d "${TMPDIR:-/tmp}/agterm-rooms.XXXXXX")
PORT_FILE=$STATE/port
WATCHER=""

cleanup() {
	[ -z "$WATCHER" ] || kill "$WATCHER" 2>/dev/null || true
	rm -rf "$STATE"
}
trap cleanup EXIT INT TERM

# Room files and their cursors, with size and modification time. The cursors are in here
# because reading a room changes only the cursor, and the unread count in the list has to
# follow that too.
signature() {
	find "$ROOMS_DIR" -type f \( -name '*.jsonl' -o -name '*.cursor' \) \
		-exec stat -f '%m %z %N' {} + 2>/dev/null | sort || true
}

# Push both sides of the viewer forward when a room file moves. fzf's --listen port is the
# only way in from outside the process; it is written out at start because fzf picks it.
watch_rooms() {
	last=$(signature)
	while :; do
		sleep "$INTERVAL"
		if [ ! -s "$PORT_FILE" ]; then
			continue
		fi
		now=$(signature)
		if [ "$now" = "$last" ]; then
			continue
		fi
		last=$now
		port=$(cat "$PORT_FILE")
		if ! "$CURL" -s -XPOST "localhost:$port" \
			-d "reload($LIST)+refresh-preview" >/dev/null 2>&1; then
			return 0                # fzf has gone; nothing left to push
		fi
	done
}

watch_rooms &
WATCHER=$!

# Keep the TAB separation all the way through, and never re-split on spaces. Room titles
# carry them, so taking the second word of a row returns the second WORD of a title. fzf
# hands back the whole tab-separated line whatever it displays, so the room file comes off
# field 3 and the title never has to be re-slugged to find its file.
"$FZF" --ansi --no-sort --listen \
	--delimiter='\t' --with-nth='1,2' \
	--prompt="room > " \
	--header="enter reads, ctrl-o opens in revdiff, ctrl-s replies, esc closes" \
	--preview="'$PYTHON' '$READ_PY' show --path {3} --width \${FZF_PREVIEW_COLUMNS:-80} 2>/dev/null" \
	--preview-window=right,60%,wrap \
	--bind "start:reload($LIST)+execute-silent(printf '%s' \$FZF_PORT > '$PORT_FILE')" \
	--bind "ctrl-o:execute('$SELF' --full-read {3})+reload($LIST)" \
	--bind "ctrl-s:execute('$SEND_SH' --room-file {3}$SEND_TARGET)+reload($LIST)" \
	--bind "enter:execute(t={1}; '$PYTHON' '$READ_PY' show --path {3} --mark --width '$cols' | less -R --prompt=\"\$t — q to close\")+reload($LIST)" \
	</dev/null || true
