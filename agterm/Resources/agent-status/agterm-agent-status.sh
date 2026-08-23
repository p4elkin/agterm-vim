#!/usr/bin/env bash
# agterm-agent-status — set the current agterm session's agent-status indicator.
#
#   agterm-agent-status.sh active            # agent is busy
#   agterm-agent-status.sh completed         # agent finished a turn
#   agterm-agent-status.sh blocked  --blink  # agent is waiting on you (pulse for attention)
#   agterm-agent-status.sh idle              # clear the indicator
#
# States: idle | active | completed | blocked. An optional --blink / --auto-reset
# (and any further args) is forwarded verbatim to `agtermctl session status`.
#
#   agterm-agent-status.sh mark              # (fork only) mark a conversation turn start
#
# `mark` is not a status: it routes to `agtermctl session mark`, which advances the
# session's turn counter, then prints the new number back as an instruction for the
# agent to echo. The AGENT has to write the mark, because nothing outside it can: a
# pane running a full-screen TUI repaints its own screen, so bytes injected into the
# pty from another process are wiped before they ever reach scrollback, and
# `session.search` only ever finds scrollback. The agent's own reply IS scrollback.
#
# Outside agterm this is a silent no-op, so it is safe to call from any hook.
#
# As a hook it must never interfere with the agent: it always exits 0 (a non-zero exit
# can block the turn), and every branch except `mark` suppresses stdout/stderr. `mark`
# deliberately prints one line, which Claude Code injects into the prompt context.
#
# agtermctl resolution order (the binary that talks to the control socket):
#   1. $AGTERMCTL — an explicit override the caller set.
#   2. the absolute bundled-binary path the installer bakes in: the installer
#      rewrites the AGTERMCTL default below to agterm.app's Contents/MacOS/agtermctl,
#      so the hook fires even when the CLI was never symlinked into PATH.
#   3. `agtermctl` on PATH — the fallback when no override was set and the baked
#      path no longer exists, which is what a bundle moved since the install leaves
#      behind (installing from the mounted DMG bakes a /Volumes path, dead on eject).
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0   # not inside agterm: nothing to do

# --socket is a SUBCOMMAND option, so it must come AFTER `session status`, not before
# it. Pass it only when AGTERM_SOCKET is set (the app injects it alongside the id).
state=$1
shift

# --pane-id still goes along because the app also writes the mark into that pane's pty. That
# write only survives in a pane with no full-screen TUI in it, so for an agent pane it does
# nothing and the echoed line above is the whole mechanism. Without the token the write would
# land in the OTHER pane of a split. Only the token, not --pane: the app resolves the token to
# the surface's CURRENT slot, and the baked role can be stale (#199).
mark_pane=()
[ -n "${AGTERM_PANE_ID:-}" ] && mark_pane+=(--pane-id "$AGTERM_PANE_ID")
if [ "$state" = "mark" ]; then
  if [ -n "${AGTERM_SOCKET:-}" ]; then
    turn=$("${AGTERMCTL:-agtermctl}" session mark \
      --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET" \
      "${mark_pane[@]+"${mark_pane[@]}"}" "$@" 2>/dev/null) || true
  else
    turn=$("${AGTERMCTL:-agtermctl}" session mark --target "$AGTERM_SESSION_ID" \
      "${mark_pane[@]+"${mark_pane[@]}"}" "$@" 2>/dev/null) || true
  fi
  # digits only. `session mark` prints the bare turn number, but a failed mark or a caller
  # passing --json prints something else, and feeding that to the agent as an instruction is
  # worse than losing one mark.
  case "${turn:-}" in
    '' | *[!0-9]*) ;;
    *) printf 'Begin your reply with this line on its own, then continue normally:\n── ⟦%s⟧ ──\n' "$turn" ;;
  esac
  exit 0
fi

# forward the pane discriminators when the app injected them: each session surface
# (main/split/scratch) sets its own AGTERM_PANE (the role) plus AGTERM_PANE_ID (a stable
# per-surface token). the role can go stale — a split survivor promoted into the main pane
# keeps its baked `right` — so we also forward the token as --pane-id, which the app resolves
# to the surface's CURRENT slot and lets override the stale role (#199). both are validated
# agtermctl-side, so pass them through verbatim. the ${arr[@]+..} guard keeps the empty-array
# expansion safe under `set -u` on bash 3.2.
pane_args=()
[ -n "${AGTERM_PANE:-}" ] && pane_args+=(--pane "$AGTERM_PANE")
[ -n "${AGTERM_PANE_ID:-}" ] && pane_args+=(--pane-id "$AGTERM_PANE_ID")

if [ -n "${AGTERM_SOCKET:-}" ]; then
  "${AGTERMCTL:-agtermctl}" session status "$state" \
    --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET" \
    "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
else
  "${AGTERMCTL:-agtermctl}" session status "$state" \
    --target "$AGTERM_SESSION_ID" "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
fi
exit 0
