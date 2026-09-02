#!/bin/sh
# The cross-agent conversations for THIS row, in an overlay.
#
# Runs as an agterm overlay program, bound to a chord:
#
#   agtermctl session overlay open ~/.local/bin/agterm-xchat/xchat-view.sh \
#       --size-percent 85 --target "{AGT_SESSION_ID}"
#
# `overlay open` takes a PROGRAM, not a program plus arguments, which is why this needs a
# file of its own rather than sitting on the keymap line.
#
# One agent can be talking to several agents at once, so this picks the conversation first
# and then shows it:
#
#   no peers    a short note saying so
#   one peer    straight into that conversation, no picker in the way
#   several     fzf over the peers, newest first, each previewed as it will look
#
# The record is written by the hook whether or not anything is on screen, so this opens a
# view onto something that already exists. Nothing is started, and closing it loses nothing.
set -eu

# An overlay starts under the APP's PATH, which is:
#   /usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin  plus the agterm bundle
# There is no /opt/homebrew/bin and no ~/.local/bin, so a bare fzf reads as not installed and
# the overlay flashes shut with nothing on screen to say why.
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
READ_PY=${XCHAT_READ:-$DIR/xchat-read.py}
PYTHON=${PYTHON:-python3}
FZF=${FZF:-fzf}

# The row to read for. An overlay inherits the AGTERM_* variables of the session it opens on;
# $1 is there for a chord that would rather pass {AGT_SESSION_ID} explicitly.
ROW=${1:-${AGTERM_SESSION_ID:-}}

pause() {
	printf '\n  press enter to close '
	read -r _ || true
}

note() {
	printf '\n'
	for line in "$@"; do printf '  %s\n' "$line"; done
	pause
}

if [ -z "$ROW" ]; then
	note "No AGTERM_SESSION_ID, so this overlay cannot tell which row it belongs to."
	exit 1
fi

# peer <TAB> count <TAB> last-seen, newest first
listing=$("$PYTHON" "$READ_PY" list --row "$ROW" 2>/dev/null) || listing=""
count=$(printf '%s' "$listing" | grep -c . || true)

if [ "$count" -eq 0 ]; then
	note "No cross-agent messages on record for this row yet." "" \
	     "If this row is running an agent and you expected messages here, the hook has" \
	     "not paired it yet: it pairs on SessionStart and on the first message sent."
	exit 0
fi

show() {
	# Width from the pane we actually got. `tput cols` reports 79 inside an agterm overlay
	# however wide the window is, which wraps every message into a narrow column and wastes
	# most of the screen. Ask the tty directly instead. The redirect itself fails when there
	# is no controlling terminal, and the shell reports that on its own stderr, so the whole
	# thing is wrapped in braces rather than just the stty.
	cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}' )
	[ -n "${cols:-}" ] || cols=$(tput cols 2>/dev/null || echo 100)
	"$PYTHON" "$READ_PY" show --row "$ROW" --peer "$1" --width "$cols" \
		| less -R --prompt="conversation with $1 — q to close"
}

if [ "$count" -eq 1 ]; then
	show "$(printf '%s\n' "$listing" | cut -f1)"
	exit 0
fi

# Several conversations: pick one. The preview renders the thread as it will look, so the
# choice is made on content and not on a name you half remember.
#
# Keep the TAB separation all the way through, and never re-split on spaces. Peer names
# contain them, so running the rows through `column -t` and then taking the second word
# returns the second WORD of the name. fzf hands back the whole tab-separated line whatever
# it displays, so the peer name comes off it with cut.
choice=$(
	printf '%s\n' "$listing" \
	  | awk -F'\t' '{ printf "%s\t%s msg, last %s\n", $1, $2, $3 }' \
	  | "$FZF" --ansi --no-sort \
	           --delimiter='\t' --with-nth='1,2' \
	           --prompt="conversation > " \
	           --header="enter opens, esc closes" \
	           --preview="'$PYTHON' '$READ_PY' show --row '$ROW' --peer {1} --width \${FZF_PREVIEW_COLUMNS:-80} 2>/dev/null | head -300" \
	           --preview-window=right,60%,wrap
) || exit 0

[ -n "$choice" ] || exit 0
show "$(printf '%s' "$choice" | cut -f1)"
