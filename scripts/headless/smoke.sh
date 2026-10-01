#!/bin/sh
# Smoke test for agterm-headless: a throwaway server and zmx directory, driven by the real agtermctl.
# Never touches the live server's state or any existing zmx session. Requires Swift and Python 3.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
bin="$root/agtermCore/.build/debug"
zmx=${AGTERM_HEADLESS_ZMX:-$HOME/.local/opt/agterm-headless/zmx}
if [ ! -x "$zmx" ]; then
    echo "smoke: no patched zmx at $zmx; set AGTERM_HEADLESS_ZMX to run it. Skipped."
    exit 0
fi

swift=${SWIFT:-$(command -v swift || echo "$HOME/.local/share/swiftly/bin/swift")}
"$swift" build --package-path "$root/agtermCore" --product agterm-headless
"$swift" build --package-path "$root/agtermCore" --product agtermctl

state=$(mktemp -d /tmp/agterm-smoke.XXXXXX)
sock="$state/agterm.sock"
server=

# a sleep this run alone starts, so a survivor of `zmx kill` is found by its argv
marker="sleep 600.$$"
text_marker="__AGTERM_TEXT_$$__"

kill_daemons() {
    if [ -d "$state/zmx" ]; then
        for daemon in "$state"/zmx/*; do
            [ -S "$daemon" ] && ZMX_DIR="$state/zmx" "$zmx" kill "$(basename "$daemon")" --force >/dev/null 2>&1 || true
        done
    fi
}

cleanup() {
    kill_daemons
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
    rm -rf "$state"
}
trap cleanup EXIT

fail() {
    echo "smoke: FAIL: $*" >&2
    sed 's/^/server: /' "$state/server.log" >&2 || true
    exit 1
}

ctl() {
    "$bin/agtermctl" "$@" --socket "$sock"
}

AGTERM_HEADLESS_STATE="$state" AGTERM_HEADLESS_ZMX="$zmx" "$bin/agterm-headless" serve >"$state/server.log" 2>&1 &
server=$!
tries=0
until [ -S "$sock" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || fail "the server never bound $sock"
    sleep 0.1
done

ctl tree --json >"$state/tree.json" || fail "tree"
ctl zmx tree --json >/dev/null || fail "zmx tree"
pane_command="printf '%s\0' \"\$AGTERM_SESSION_ID\" \"\$AGTERM_SOCKET\" \"\$AGTERM_STATE_DIR\" \
\"\$AGTERM_PANE\" \"\$AGTERM_PANE_ID\" \"\$AGTERM_WINDOW_ID\" \"\$AGTERM_WORKSPACE_ID\" \
\"\$AGTERM_ENABLED\" \"\$TERM_PROGRAM\" \"\$TERM_PROGRAM_VERSION\" \"\$SHELL\" > '$state/pane-env'"
session_command="$pane_command; printf '%s\n' \"\$AGTERM_SESSION_ID\" > '$state/session-id'; printf '%s\n' \"\$PWD\" > '$state/session-cwd'; printf '\033[31m%s\033[0m\n\n' '$text_marker'; exec $marker"
id=$(ctl session new --cwd "$state" --command "$session_command") || fail "session new"
[ -n "$id" ] || fail "session new printed no id"
ctl tree --json | grep -q "$id" || fail "tree does not list the new session $id"
ctl notify "smoke" --target "$id" >/dev/null || fail "notify"
if ctl window new >"$state/refusal.txt" 2>&1; then
    fail "window new was served"
fi
grep -q "headless origin" "$state/refusal.txt" || fail "window new refusal: $(cat "$state/refusal.txt")"

tries=0
until command=$(pgrep -x -f "$marker"); do
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || fail "the session's command never started"
    sleep 0.1
done
[ "$(cat "$state/session-id")" = "$id" ] || fail "the command inherited the wrong AGTERM_SESSION_ID"
[ "$(cat "$state/session-cwd")" = "$state" ] || fail "the command ran in the wrong directory"
python3 - "$state" "$id" "$bin/agtermctl" "$root/agterm/Resources/agent-status/agterm-agent-status.sh" <<'PY' || fail "status hook"
import json
import os
from pathlib import Path
import subprocess
import sys

state, session_id, cli, hook = sys.argv[1:]
keys = ("AGTERM_SESSION_ID", "AGTERM_SOCKET", "AGTERM_STATE_DIR", "AGTERM_PANE",
        "AGTERM_PANE_ID", "AGTERM_WINDOW_ID", "AGTERM_WORKSPACE_ID", "AGTERM_ENABLED",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "SHELL")
values = (Path(state) / "pane-env").read_bytes().split(b"\0")
assert len(values) == len(keys) + 1 and values[-1] == b"", "incomplete pane environment"
pane = dict(zip(keys, map(os.fsdecode, values[:-1])))
assert all(pane.values()), "missing pane variable"
assert pane["AGTERM_SESSION_ID"] == session_id, "wrong hook session"
assert pane["AGTERM_SOCKET"] == state + "/agterm.sock", "hook socket is not isolated"
assert pane["AGTERM_STATE_DIR"] == state, "hook state is not isolated"
assert pane["AGTERM_PANE"] == "left", "wrong hook pane"
env = {key: value for key, value in os.environ.items()
       if not key.startswith("AGTERM_") and key != "AGTERMCTL"}
env.update(pane, AGTERMCTL=cli)
subprocess.run(["bash", hook, "active"], env=env, check=True, timeout=10)
response = subprocess.check_output([cli, "tree", "--json", "--socket", pane["AGTERM_SOCKET"]],
                                   env=env, timeout=10)
tree = json.loads(response)["result"]["tree"]
sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]
            if session["id"] == session_id]
assert len(sessions) == 1 and sessions[0].get("status") == "active", "hook did not set this session active"
PY
ctl session text --target "$id" --lines 1 > "$state/session-text" || fail "session text"
[ "$(cat "$state/session-text")" = "$text_marker" ] || fail "session text did not return the last content line"

split_command="printf '%s\n' \"\$AGTERM_PANE\" > '$state/split-pane'; printf '%s\n' \"\$AGTERM_SESSION_ID\" > '$state/split-session'"
ctl session split on --target "$id" --command "$split_command" >/dev/null || fail "session split"
tries=0
until [ -s "$state/split-session" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || fail "the split command never ran"
    sleep 0.1
done
[ "$(cat "$state/split-pane")" = "right" ] || fail "the split inherited the wrong AGTERM_PANE"
[ "$(cat "$state/split-session")" = "$id" ] || fail "the split inherited the wrong session id"
ctl session split close --target "$id" >/dev/null || fail "session split close"
ctl session close --target "$id" >/dev/null || fail "session close"
ctl tree --json | grep -q "$id" && fail "tree still lists the closed session $id"
tries=0
while kill -0 "$command" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
        kill -KILL "$command"
        fail "the session's command outlived session close"
    fi
    sleep 0.1
done

# a daemon that dies outside the server: the watcher lists it once, then drops its session
second=$(ctl session new --command "$marker.2") || fail "second session new"
sleep 6
for daemon in "$state"/zmx/*; do
    case "$daemon" in
        */logs) ;;
        *) ZMX_DIR="$state/zmx" "$zmx" kill "$(basename "$daemon")" --force >/dev/null 2>&1 || true ;;
    esac
done
tries=0
while ctl tree --json | grep -q "$second"; do
    tries=$((tries + 1))
    [ "$tries" -le 120 ] || fail "the watcher never closed $second after its daemon died"
    sleep 0.1
done

echo "smoke: ok (tree, zmx tree, session new $id, notify, window new refused, session environment, cwd, status hook active, session text, split environment and close, session close killed the daemon, watcher closed a dead one)"
