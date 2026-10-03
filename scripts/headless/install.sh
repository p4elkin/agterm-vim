#!/usr/bin/env bash
# Build and install the Linux origin. --dry-run performs only read-only probes.
set -euo pipefail
export LC_ALL=C

dry_run=false
case "${1:-}" in
    '') ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[[ $# == 0 ]] || { echo "usage: $0 [--dry-run]" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo "install: Linux only" >&2; exit 1; }

root=$(cd "$(dirname "$0")/../.." && pwd)
prefix="$HOME/.local/opt/agterm-headless"
unit_dir="$HOME/.config/systemd/user"
unit=agterm-headless.service
swift=${SWIFT:-$(command -v swift || echo "$HOME/.local/share/swiftly/bin/swift")}
zig=${ZIG:-zig}
for tool in "$swift" "$zig" git sha256sum systemctl cmp install mktemp readlink; do
    command -v "$tool" >/dev/null || { echo "install: missing tool: $tool" >&2; exit 1; }
done

# Read pins without sourcing setup.sh, which builds macOS artifacts as a side effect.
zmx_repo=$(sed -n 's/^ZMX_REPO="\([^"]*\)".*/\1/p' "$root/scripts/setup.sh")
zmx_rev=$(sed -n 's/^ZMX_REV="\([^"]*\)".*/\1/p' "$root/scripts/setup.sh")
ghostty_repo=$(sed -n 's/^GHOSTTY_REPO="\([^"]*\)".*/\1/p' "$root/scripts/setup.sh")
target=$("$zig" env | sed -n 's/^ *\.target = "\([^"]*\)".*/\1/p')
[[ -n "$zmx_repo" && -n "$zmx_rev" && -n "$ghostty_repo" && "$target" == *-linux* ]] || {
    echo "install: cannot resolve zmx pins or Zig's Linux host target" >&2
    exit 1
}
shopt -s nullglob
patches=("$root"/scripts/zmx-patches/*.patch)
ghostty_patches=("$root"/scripts/zmx-patches/ghostty/*.patch)
all_patches=("${patches[@]}" "${ghostty_patches[@]}")
digest=$({ if ((${#all_patches[@]})); then cat "${all_patches[@]}"; fi; } | sha256sum | cut -c1-16)
stamp="$zmx_rev $target $digest"
cache="$root/agtermCore/.build/headless-zmx"
need_zmx=true
if [[ -x "$cache/zmx" && -f "$cache/LICENSE" && -f "$cache/stamp" ]] &&
    [[ $(cat "$cache/stamp") == "$stamp" ]]; then
    need_zmx=false
fi
build=$(git -C "$root" rev-parse --short HEAD)

unmanaged_pids() {
    local main_pid exe path pid
    main_pid=$(systemctl --user show "$unit" --property=MainPID --value 2>/dev/null || true)
    for exe in /proc/[0-9]*/exe; do
        [[ -O "${exe%/exe}" ]] || continue
        path=$(readlink "$exe" 2>/dev/null) || continue
        path=${path% (deleted)}
        [[ "$path" == "$prefix/agterm-headless" ]] || continue
        pid=${exe%/exe}
        pid=${pid##*/}
        [[ "$pid" == "$main_pid" ]] || printf '%s\n' "$pid"
    done
}

handoff_hint() {
    echo "install: server outside systemd (PID(s): $1); service restart skipped."
    echo "install: stop that server yourself, then run: systemctl --user start $unit"
}

print_command() {
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
}

if $dry_run; then
    print_command "$swift" build --package-path "$root/agtermCore" -c release --product agterm-headless
    print_command "$swift" build --package-path "$root/agtermCore" -c release --product agtermctl
    if $need_zmx; then
        echo "dry-run: fetch $zmx_repo at $zmx_rev into a temporary checkout"
        echo "dry-run: fetch $ghostty_repo at the revision zmx pins into a sibling zmx-ghostty checkout"
        for patch in "${ghostty_patches[@]}"; do
            print_command git apply --whitespace=nowarn "$patch"
        done
        for patch in "${patches[@]}"; do
            print_command git apply --whitespace=nowarn "$patch"
        done
        print_command "$zig" build -Doptimize=ReleaseSafe "-Dtarget=$target"
        echo "dry-run: cache zmx and LICENSE at $cache; stamp: $stamp"
    else
        echo "dry-run: zmx cache unchanged ($stamp); skip its build"
    fi
    echo "dry-run: compare built agterm-headless, agtermctl, zmx and LICENSE with $prefix"
    echo "dry-run: install changed files via temporary sibling files and atomic rename"
    echo "dry-run: write $prefix/BUILD: $build"
    echo "dry-run: atomically install scripts/headless/$unit into $unit_dir"
    print_command systemctl --user daemon-reload
    print_command systemctl --user enable "$unit"
    external=$(unmanaged_pids)
    if [[ -n "$external" ]]; then
        handoff_hint "$external"
    else
        echo "dry-run: systemctl --user start $unit if it is not running, else restart it only if agterm-headless changed"
    fi
    exit 0
fi

scratch=$(mktemp -d /tmp/agterm-install.XXXXXX)
pending=
cleanup() {
    [[ -z "$pending" ]] || rm -f -- "$pending"
    rm -rf -- "$scratch"
}
trap cleanup EXIT

install_file() {
    local source=$1 destination=$2 mode=$3
    if cmp -s "$source" "$destination" && [[ $(stat -c %a "$destination") == "$mode" ]]; then
        echo "install: unchanged $destination"
        return
    fi
    pending=$(mktemp "$destination.XXXXXX")
    install -m "$mode" "$source" "$pending"
    mv -fT -- "$pending" "$destination"
    pending=
    echo "install: updated $destination"
}

"$swift" build --package-path "$root/agtermCore" -c release --product agterm-headless
"$swift" build --package-path "$root/agtermCore" -c release --product agtermctl
bin=$("$swift" build --package-path "$root/agtermCore" -c release --show-bin-path)
if $need_zmx; then
    echo "install: building zmx $stamp"
    checkout="$scratch/zmx"
    git init -q "$checkout"
    git -C "$checkout" remote add origin "$zmx_repo"
    git -C "$checkout" fetch -q --depth 1 origin "$zmx_rev"
    git -C "$checkout" -c advice.detachedHead=false checkout -q FETCH_HEAD
    # setup.sh's rule: zmx's ghostty patches go on a private checkout that a zmx patch repoints the dependency to.
    ghostty_rev=$(sed -n 's|.*ghostty-org/ghostty#\([0-9a-f]\{40\}\)".*|\1|p' "$checkout/build.zig.zon")
    [[ -n "$ghostty_rev" ]] || { echo "install: no ghostty revision in zmx build.zig.zon" >&2; exit 1; }
    ghostty="$scratch/zmx-ghostty"
    git init -q "$ghostty"
    git -C "$ghostty" remote add origin "$ghostty_repo"
    git -C "$ghostty" fetch -q --depth 1 origin "$ghostty_rev"
    git -C "$ghostty" -c advice.detachedHead=false checkout -q FETCH_HEAD
    for patch in "${ghostty_patches[@]}"; do
        git -C "$ghostty" apply --whitespace=nowarn "$patch"
    done
    for patch in "${patches[@]}"; do
        git -C "$checkout" apply --whitespace=nowarn "$patch"
    done
    (cd "$checkout" && "$zig" build -Doptimize=ReleaseSafe "-Dtarget=$target")
    mkdir -p "$cache"
    # Invalidate before publishing artifacts, so interruption cannot leave a valid stale stamp.
    rm -f "$cache/stamp"
    install_file "$checkout/zig-out/bin/zmx" "$cache/zmx" 755
    install_file "$checkout/LICENSE" "$cache/LICENSE" 644
    printf '%s\n' "$stamp" > "$scratch/stamp"
    install_file "$scratch/stamp" "$cache/stamp" 644
else
    echo "install: zmx cache unchanged; skipped its build"
fi

mkdir -p "$prefix" "$unit_dir"
server_changed=false
cmp -s "$bin/agterm-headless" "$prefix/agterm-headless" || server_changed=true
install_file "$bin/agterm-headless" "$prefix/agterm-headless" 755
install_file "$bin/agtermctl" "$prefix/agtermctl" 755
install_file "$cache/zmx" "$prefix/zmx" 755
install_file "$cache/LICENSE" "$prefix/LICENSE" 644
printf '%s\n' "$build" > "$scratch/BUILD"
install_file "$scratch/BUILD" "$prefix/BUILD" 644
install_file "$root/scripts/headless/$unit" "$unit_dir/$unit" 644
systemctl --user daemon-reload
systemctl --user enable "$unit"
external=$(unmanaged_pids)
if [[ -n "$external" ]]; then
    handoff_hint "$external"
elif ! systemctl --user is-active --quiet "$unit"; then
    systemctl --user start "$unit"
    echo "install: started $unit"
elif $server_changed; then
    systemctl --user restart "$unit"
    echo "install: restarted $unit (server binary changed)"
else
    echo "install: server binary unchanged; service restart skipped"
fi
