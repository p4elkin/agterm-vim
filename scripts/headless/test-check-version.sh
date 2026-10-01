#!/bin/sh
# Plain shell test for check-version.sh, fed from fixture files. Runs nothing remote.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

version() { printf '{"ok":true,"result":{"app":{"version":"%s","commit":%s}}}\n' "$2" "$3" > "$dir/$1-version.json"; }
tree() { printf '{"ok":true,"result":{"remote":{"presentation":%s,"sessions":[]}}}\n' "$2" > "$dir/$1-tree.json"; }

# run <expected exit> <mac>... ; output in $dir/out
run() {
    expected=$1; shift
    set +e
    "$here/check-version.sh" --fixture "$dir" "$@" > "$dir/out" 2>&1
    status=$?
    set -e
    [ "$status" -eq "$expected" ] || fail "exit $status, expected $expected for $*: $(cat "$dir/out")"
}

expect() { grep -q -- "$1" "$dir/out" || fail "missing '$1' in: $(cat "$dir/out")"; }
refute() { if grep -q -- "$1" "$dir/out"; then fail "unexpected '$1' in: $(cat "$dir/out")"; fi; }

version server headless '"abc1234"'; tree server 1
version mac-a 0.33.1 '"abc1234"'; tree mac-a 1
run 0 mac-a
expect 'mac-a: presentation 1, commit abc1234: ok'
refute warning

version mac-b 0.33.1 '"def5678"'; tree mac-b 1
run 0 mac-a mac-b
expect 'mac-b: presentation 1, commit def5678: warning: the server runs abc1234'

version mac-c 0.33.1 '"abc1234"'; tree mac-c 2
run 1 mac-a mac-c
expect 'mac-c: presentation 2, commit abc1234: MISMATCH: the server speaks presentation 1'
expect 'mac-a: presentation 1, commit abc1234: ok'

version mac-d 0.33.1 null; tree mac-d 1
run 0 mac-d
expect 'mac-d: presentation 1, commit none: warning: mac-d reports no commit'

version server headless null
run 0 mac-a
expect 'warning: the server reports no commit'
version server headless '"abc1234"'

run 0 mac-offline
expect 'mac-offline: unreachable'

tree mac-e null; version mac-e 0.33.1 '"abc1234"'
run 1 mac-e
expect 'mac-e: presentation none'

if [ "$failures" -gt 0 ]; then
    echo "test-check-version: $failures failure(s)"
    exit 1
fi
echo "test-check-version: ok"
