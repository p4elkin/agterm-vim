#!/usr/bin/env bash
# Builds the spike host and its plugin, and prepares a state dir and a project.
# Usage: build.sh <stateDir> <projectDir> [ghostty]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state="$1"; project="$2"
jbr=/Applications/Rebased.app/Contents/jbr/Contents/Home

# JBR ships javac but no jar tool, so the plugin jar is a plain zip.
out_classes="$state/plugin-classes"
rm -rf "$out_classes" && mkdir -p "$out_classes"
"$jbr/bin/javac" --release 21 -cp '/Applications/Rebased.app/Contents/lib/*' -d "$out_classes" \
  "$here"/plugin/src/agterm/rebased/*.java
cp -R "$here/plugin/res/META-INF" "$out_classes/"
mkdir -p "$state/plugins/agterm-bridge/lib"
(cd "$out_classes" && rm -f "$state/plugins/agterm-bridge/lib/agterm-bridge.jar" \
  && /usr/bin/zip -q -r -X "$state/plugins/agterm-bridge/lib/agterm-bridge.jar" .)

out="$state/spike"
if [[ "${3:-}" == ghostty ]]; then
  gk="$here/../../../GhosttyKit.xcframework/macos-arm64"
  clang -fobjc-arc -DWITH_GHOSTTY -I"$jbr/include" -I"$jbr/include/darwin" -I"$gk/Headers" "$here/spike.m" \
    "$gk/libghostty-internal.a" -lc++ -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
    -framework IOSurface -framework CoreText -framework Carbon -framework UniformTypeIdentifiers -o "$out"
else
  clang -fobjc-arc -I"$jbr/include" -I"$jbr/include/darwin" "$here/spike.m" -framework Cocoa -o "$out"
fi

mkdir -p "$project"
if [[ ! -d "$project/.git" ]]; then
  printf 'hello\n' > "$project/a.txt"
  git -C "$project" init -q && git -C "$project" add a.txt && git -C "$project" commit -qm init
fi
echo "built $out"
