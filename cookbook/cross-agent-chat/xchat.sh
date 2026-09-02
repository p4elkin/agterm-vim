#!/usr/bin/env bash
# xchat — read the cross-agent message record from a shell.
#
# The hook records every SendMessage: the full text per message under msgs/, and one thread
# per peer under threads/. A long body is replaced on the wire by a one-line pointer, so this
# record holds the whole conversation while the receiving session's own chat does not.
#
# Inside agterm the chord is the usual way in, and `xchat show` opens the same overlay. This
# command covers what the chord cannot reach: a plain shell, an ssh session, or one message
# by its id.
#
# Usage:
#   xchat show  [--session NAME]        open the overlay picker, same as the chord
#   xchat list  [--session NAME]        conversations this session has, newest first
#   xchat log   [PEER] [--session NAME] print one conversation (picks it if there is one)
#   xchat read  MSG-ID                  print one message in full
#   xchat who   [--session NAME]        how this row resolves, and where its threads live
#
# --session names a Claude session; without it, the row this shell is running in is used.
set -euo pipefail

DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
READ_PY=${XCHAT_READ:-$DIR/xchat-read.py}
PYTHON=${PYTHON:-python3}
AGTERMCTL=${AGTERMCTL:-agtermctl}
XCHAT_HOME=${XCHAT_HOME:-$HOME/.local/state/agterm-xchat}

die() { printf 'xchat: %s\n' "$*" >&2; exit 1; }

# `tput cols` reports 79 inside an agterm overlay however wide the window is, which wraps
# every message into a narrow column. Ask the tty directly. The redirect itself fails when
# there is no controlling terminal, and bash reports that on its own stderr, so the whole
# thing has to be wrapped in braces, not just the stty.
term_cols() {
  local cols=""
  cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}' ) || true
  [ -n "$cols" ] || cols=$(tput cols 2>/dev/null || echo 100)
  printf '%s' "$cols"
}

sub="${1:-}"; shift || true
session=()
arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=(--session "${2:-}"); shift 2 ;;
    *) [ -n "$arg" ] || arg="$1"; shift ;;
  esac
done

case "$sub" in
  show)
    [ -n "${AGTERM_SESSION_ID:-}" ] || die "not inside an agterm session; use 'xchat log' instead"
    "$AGTERMCTL" session overlay open "$DIR/xchat-view.sh" \
      --size-percent "${XCHAT_SIZE:-85}" --target "$AGTERM_SESSION_ID" >/dev/null
    ;;
  list)
    "$PYTHON" "$READ_PY" list "${session[@]+"${session[@]}"}" \
      | awk -F'\t' '{ printf "%-44s %4s msg   last %s\n", $1, $2, $3 }' \
      || die "no conversations on record for this session"
    ;;
  log)
    peer=()
    [ -z "$arg" ] || peer=(--peer "$arg")
    "$PYTHON" "$READ_PY" show "${session[@]+"${session[@]}"}" "${peer[@]+"${peer[@]}"}" \
      --width "$(term_cols)"
    ;;
  read)
    [ -n "$arg" ] || die "read: give a message id, e.g. msg-133434-cad8"
    f="$XCHAT_HOME/msgs/${arg%.md}.md"
    [ -f "$f" ] || die "no such message: $arg (looked in $XCHAT_HOME/msgs)"
    cat "$f"
    ;;
  who)
    "$PYTHON" "$READ_PY" who "${session[@]+"${session[@]}"}"
    ;;
  ""|-h|--help|help)
    sed -n '/^# Usage:/,/^# --session/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '$sub' (show|list|log|read|who)" ;;
esac
