#!/bin/sh
# Compares the headless server with each Mac that attaches to it. Read-only on both sides.
#   check-version.sh <mac>...                 run the Linux agtermctl here and the Mac's over ssh
#   check-version.sh --fixture <dir> <mac>... read <dir>/{server,<mac>}-{version,tree}.json instead
# Exit 1 when a Mac speaks another presentation version: its stream cannot follow the server.
# A different or missing commit only warns, and an unreachable Mac is reported without failing.
set -eu

fixture=
if [ "${1:-}" = "--fixture" ]; then
    fixture=${2:?--fixture needs a directory}
    shift 2
fi
[ $# -gt 0 ] || { echo "usage: check-version.sh [--fixture <dir>] <mac>..." >&2; exit 2; }

ctl="$HOME/.local/opt/agterm-headless/agtermctl"
state="$HOME/.local/state/agterm-headless"
mac_ctl=/Applications/agterm.app/Contents/MacOS/agtermctl

# read <who> <version|tree>: the JSON answer, or nothing when it cannot be had
read_json() {
    if [ -n "$fixture" ]; then
        cat "$fixture/$1-$2.json" 2>/dev/null || true
        return
    fi
    if [ "$1" = server ]; then
        case $2 in
        version) AGTERM_STATE_DIR="$state" "$ctl" version --json 2>/dev/null || true ;;
        tree) AGTERM_STATE_DIR="$state" "$ctl" zmx tree --json 2>/dev/null || true ;;
        esac
    else
        case $2 in
        version) ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "$mac_ctl version --json" 2>/dev/null || true ;;
        tree) ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "$mac_ctl zmx tree --json" 2>/dev/null || true ;;
        esac
    fi
}

commit_of() { jq -r '.result.app.commit // "none"' 2>/dev/null || echo none; }
presentation_of() { jq -r '.result.remote.presentation // "none"' 2>/dev/null || echo none; }

server_version=$(read_json server version)
[ -n "$server_version" ] || { echo "server: unreachable (is agterm-headless running?)"; exit 1; }
server_commit=$(printf '%s' "$server_version" | commit_of)
server_presentation=$(read_json server tree | presentation_of)
echo "server: presentation $server_presentation, commit $server_commit"
[ "$server_commit" != none ] || echo "warning: the server reports no commit (no BUILD file next to its binary)"

status=0
for mac in "$@"; do
    version=$(read_json "$mac" version)
    if [ -z "$version" ]; then
        echo "$mac: unreachable"
        continue
    fi
    commit=$(printf '%s' "$version" | commit_of)
    presentation=$(read_json "$mac" tree | presentation_of)
    line="$mac: presentation $presentation, commit $commit"
    if [ "$presentation" != "$server_presentation" ]; then
        echo "$line: MISMATCH: the server speaks presentation $server_presentation"
        status=1
    elif [ "$commit" = none ]; then
        echo "$line: warning: $mac reports no commit"
    elif [ "$server_commit" != none ] && [ "$commit" != "$server_commit" ]; then
        echo "$line: warning: the server runs $server_commit"
    else
        echo "$line: ok"
    fi
done
exit "$status"
